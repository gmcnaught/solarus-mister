//
//  MisterBlitterRenderer — see mister_blitter_renderer.h.
//
//  SUBCLASS of SDLRenderer (the draw-dispatch singleton). THE FABRIC IS THE SOLE
//  RENDERER: every clear/fill/draw onto the 320x240 quest render-target is
//  translated into a hardware blitter command, and present() always submits the
//  ring (the fabric composites the DDR framebuffer). There is NO SDL readback
//  fallback and NO parallel base-SDL software composite for backed ops — fabric
//  coverage is full (escape==0 across intro/title/menus/overworld/pause), so the
//  old double-render gate + readback fallback were removed as dead weight + a
//  source of incoherence. Base SDL still renders SDL-BACKED source surfaces
//  (sprite/tile atlases, menu intermediates) since the fabric uploads them.
//
//  PERSISTENCE (the title/intro flashing fix): the quest surface is a PERSISTENT
//  target — Solarus clears it only when it wants a fresh frame and otherwise draws
//  incrementally on top of the previous frame. We mirror that: hardware-clear the
//  DDR buffer only on an explicit clear(); otherwise CARRY FORWARD the previous
//  committed buffer into the next target buffer so every committed frame holds the
//  full, current image (vs. the old unconditional clear + double-buffer, which left
//  incremental frames as bare foreground on black -> the flashing).
//
#include "mister_blitter_renderer.h"

#ifdef MISTER_NATIVE_VIDEO

#include "mister_native_video.h"   // mister_poll_input() — the offload path bypasses
                                   // mister_present_frame(), so it must poll input itself
#include "blitter/blt_emitter.h"
#include "mister_pixconv.h"    // [#52] fast NEON/scalar RGB565/ARGB4444 source convert
#include "mister_lua_prof.h"   // [#26] Lua-VM time split (defines the extern globals below)

// [#26] Lua-VM time accumulator + diag gate, read/incremented across TUs
// (LuaTools::call_function brackets lua_pcall with mister_lua_prof_enter/exit).
extern "C" {
  volatile long long g_mister_lua_vm_ns = 0;
  volatile int       g_mister_lua_diag  = 0;
  // [#52 lever-1] engine-classified per-frame draw-category counts.
  volatile long long g_me_draw_anim_tiles = 0;
  volatile long long g_me_draw_entities   = 0;
  // [#52 lever-3] eng_cpp update sub-timers (ns).
  volatile long long g_me_upd_hero_ns     = 0;
  volatile long long g_me_upd_entities_ns = 0;
  volatile long long g_me_upd_nonanim_ns  = 0;
  volatile long long g_me_upd_tileset_ns  = 0;
  // [eng_cpp "other" attribution] System::update/Sound (audio mix+pump+music
  // decode) wall-ns, and the catch-up STEP multiplier (MainLoop num_updates).
  // The "update" phase the renderer measures (present-return -> first draw) runs
  // step() num_updates times per DISPLAYED frame to keep game-time at 60Hz when
  // the system is slow, so every eng_cpp sub-bucket is amplified by num_updates.
  // g_me_steps lets the banner normalise eng_cpp to a per-tick figure.
  volatile long long g_me_upd_sound_ns    = 0;
  volatile long long g_me_steps           = 0;
}

#include <solarus/graphics/sdlrenderer/SDLSurfaceImpl.h>
#include <solarus/graphics/SurfaceImpl.h>
#include <solarus/graphics/DrawProxies.h>
#include <solarus/graphics/Color.h>
#include <solarus/core/Rectangle.h>
#include <solarus/core/Point.h>

#include <SDL_render.h>
#include <SDL_surface.h>
#include <SDL_pixels.h>

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <functional>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <time.h>

namespace Solarus {

// Deterministic camera-surface tag (issue #15). Game::draw tells us EXACTLY which
// SurfaceImpl is the map camera surface, so the renderer aliases it on-fabric
// DETERMINISTICALLY instead of guessing via looks_like_promote() — which lost a
// "first-wins" lottery to early transient full-frame blits, making the gameplay
// offload non-deterministic (alias_blits flipping 0<->630). With the tag, the
// camera composite runs on the fabric every frame, by construction. The renderer
// reads g_tagged_camera; if unset (or SOLARUS_NO_CAMERA_TAG), it falls back to the
// old heuristic. Free function (external linkage) so a Game.cpp patch can call it.
static const SurfaceImpl* g_tagged_camera = nullptr;
void mister_tag_camera_surface(const SurfaceImpl* s) { g_tagged_camera = s; }

// Camera top-left in MAP coords (issue #21 scroll-aware cache). Game::draw publishes
// it each frame so the renderer knows the per-frame scroll delta exactly (vs inferring
// from cell dst shifts). Used only when SOLARUS_SCROLLCACHE is on.
static int g_cam_x = 0, g_cam_y = 0;
void mister_set_camera_pos(int x, int y) { g_cam_x = x; g_cam_y = y; }
// [#52] Published camera top-left. The resident path stores camera-INDEPENDENT map-coord
// dsts and reads this live each frame to compute the per-bucket screen bias (normal:
// -camera; parallax: camera/ratio - camera), so a camera move never rebuilds the list.
int mister_camera_x() { return g_cam_x; }
int mister_camera_y() { return g_cam_y; }

// [MiSTer #23] True while the game is paused or showing a dialog (set each frame from
// Game::draw). The pause/inventory and dialog screens are static full-screen composites:
// without this the bg-cache snapshots them as the "background", which then persists as
// the frame base after the menu closes (until a camera move relearns) — entities draw on
// top of the stale menu image. While paused we force the cache to LEARN (full composite,
// never snapshot); the map relearns + re-snapshots on resume.
static bool g_paused = false;
void mister_set_paused(bool p) { g_paused = p; }

// [MiSTer #24] True while a map-to-map transition is active (transition != nullptr,
// set each frame from Game::draw). The scrolling transition (TransitionScrolling)
// blits the OLD (previous_map_surface) and NEW (camera surface) maps onto the root at
// animating scroll offsets — but our alias optimization composites the new map's
// content straight into DDR at (0,0), leaving the camera SURFACE's own pixels empty,
// so the new map has nothing to scroll in (only the old map scrolls away), and the
// two maps' atlases co-resident overflow the heap (black flicker). g_in_transition is
// retained only for the bg-cache LEARN gate (any transition).
//
// [const-alpha fill / transition scope] The alias-disable + heap-reset above are needed
// ONLY for SCROLLING — the one transition with two maps co-resident and a non-(0,0)
// blit. FADE and IMMEDIATE draw a SINGLE map at its normal (0,0) position, so the alias
// is valid for them; disabling it forced the whole map to re-composite in SOFTWARE for
// the fade's duration AND the per-edge heap reset re-uploaded the working set (an fps
// blip / slow edge frames) for no benefit. So gate the alias/heap-reset special-casing
// on g_transition_scroll (= active && needs_previous_surface()), which is true only for
// TransitionScrolling. fade/immediate now composite on the fabric throughout (correct
// now that a translucent fill is a const-alpha FILL — see fill()); scrolling unchanged.
// NOTE: this changes gameplay-adjacent aliasing during fades — verify on HW (RBF) before
// merging out of the workstream; revert is just flipping these gates back to g_in_transition.
static bool g_in_transition    = false;   // any transition (bg-cache LEARN gate only)
static bool g_transition_scroll = false;  // scrolling transition (alias-disable + heap-reset)
void mister_set_transition(bool active, bool needs_prev) {
  g_in_transition     = active;
  g_transition_scroll = active && needs_prev;   // only TransitionScrolling needs_previous_surface()
}

// ---- DDR layout for the blitter region.
// MUST MATCH the fabric's fpga/rtl/blitter_defs.vh. Framebuffers + video control
// word stay in the proven 1 MiB f2h region at 0x3A000000 (drop-in producer). The
// blitter COMMAND region (ctrl/ring + source heap) lives in a dedicated 4 MiB
// region at 0x3B000000 so a full SCENE TRANSITION (two scenes co-resident, ~1 MiB)
// fits — the 1 MiB region's pre-audio gap only afforded 352 KiB (heavy scenes
// escaped on size). 0x3B000000..0x3B400000 HW-verified reserved-safe (64/64 pattern
// words survive Linux + engine + video/audio).
//   BLTCTRL 0x3B000000 | RING 0x3B000040..0x3B080000 | SRC heap 0x3B080000 | end 0x3C000000
namespace {
constexpr uint32_t BLT_DDR_PHYS = 0x3B000000u;
// 16 MiB: ctrl + ring + ~16 MiB heap. Grown from 4 MiB (issue #14): with the
// DETERMINISTIC camera offload (issue #15) the whole map composite's sources upload
// to the heap, and heavy/transition scenes (2 maps co-resident) overflowed 4 MiB ->
// escape -> black. The kernel cmdline reserves DDR 0x1FF00000..0x40000000 (511..1024
// MiB) for the core (`mem=511M memmap=513M$511M`), so 0x3B000000..0x3C000000 (944..960
// MiB) is reserved-safe. NO RBF change: cmd.src_off is uint32 and the fabric forms the
// address from it (the .vh MEM_QW is a sim guard, not a HW limit); f2h addresses all DDR.
constexpr size_t   BLT_DDR_SIZE = 0x01000000u;   // 16 MiB
constexpr uint32_t OFF_RING      = 0x00000040u;
// [#52] Command ring grown 32 KiB -> 512 KiB (1022 -> ~16382 commands). Heavy areas
// render with 8x8 tiles: a single full 320x240 layer = 40*30 = 1200 individual tile
// blits, already over the old 1022-command ring -> blt_blit overflow -> the present()
// handler latches scene_too_big -> blitter_off() -> every draw falls to the software
// offtarget path -> BLACK SCREEN (#52). The fabric composites the tiles trivially
// (~0.24 Mpx/frame); the ring was the sole limit. The heap base moves up to 0x80000 to
// make room (heap still ~15.2 MiB vs ~9.7 MiB peak use). RBF coupling: OFF_HEAP MUST
// match the fabric `SRC_QW` = (BLT_DDR_PHYS + OFF_HEAP) >> 3 = 0x07610000 in
// blitter_defs.vh — the fabric reads STAGE sources from SRC_QW + src_off.
constexpr uint32_t RING_CAP      = 0x0007FFC0u;  // ring spans 0x40..0x80000 (~512 KiB)
constexpr uint32_t OFF_HEAP      = 0x00080000u;  // heap @ 0x3B080000 (~15.2 MiB to bg-cache)
static_assert(OFF_RING + RING_CAP == OFF_HEAP,
              "[#52] command ring must be contiguous from OFF_RING up to the heap base");
// BACKGROUND CACHE (SOLARUS_BGCACHE): the composited static map background lives at a
// FIXED DDR location 0x3BF00000 (= BLT_DDR_PHYS + 0xF00000) — MUST MATCH the fabric's
// `CACHE_QW` in blitter_defs.vh. The fabric composes the static layers INTO it via the
// off-screen pass (C_TARGET=2, no display flip), and reads it as a heap SOURCE for the
// per-frame cache->fb blit. The bump heap is capped below it (never overwrites it).
constexpr uint32_t OFF_BGCACHE   = 0x00F00000u;                    // ddr-relative: 0x3BF00000
constexpr uint32_t BGCACHE_HEAP_OFF = OFF_BGCACHE - OFF_HEAP;      // heap-relative src_off
constexpr uint32_t HEAP_CAP_BG   = OFF_BGCACHE - OFF_HEAP;         // bump heap cap (reserves bg)
// [#52] TILE-LIST entry buffer (BLT_OP_TILELIST). The fabric reads 12-byte tile
// entries from a fixed DDR base. MUST match fabric TL_BUF byte base 0x3BF40000
// (blitter_top.sv TL_BUF_QW). It sits ABOVE the bg-cache (0x3BF00000, CACHE_SIZE
// 153600 = 0x25800 -> ends 0x3BF25800) so the two never overlap. 512 KiB matches the
// fabric (Task 4: enlarged from 64 KiB so the resident list can hold a whole map's
// animated tiles). SINGLE buffer: the submit/done handshake serializes frames (the
// fabric finishes reading the list before the next frame begins), so no double-buffer.
constexpr uint32_t OFF_TLBUF     = 0x00F40000u;                    // ddr-relative: 0x3BF40000
constexpr uint32_t TL_BUF_BYTES  = 0x00080000u;                    // 512 KiB (matches fabric)
static_assert(OFF_TLBUF + TL_BUF_BYTES <= BLT_DDR_SIZE,
              "[#52] tile-list buffer must fit inside the mapped DDR region");
static_assert(OFF_TLBUF >= OFF_BGCACHE + 320u * 240u * 2u,   // bg-cache = 153600 B RGB565
              "[#52] tile-list buffer must sit above the bg-cache (no overlap)");
// [#52 resident / Tier B] frame-rect table (FRT) + current-frame table (CFT). Placed
// ABOVE TL_BUF (ends 0x3BFC0000) and below the region end. MUST match the fabric
// FRT_BUF_QW=0x3BFC0000 / CFT_BUF_QW=0x3BFC2000 (blitter_defs.vh) and BLT_MAXP/BLT_MAXF.
constexpr uint32_t OFF_FRTBUF    = 0x00FC0000u;                    // ddr-relative: 0x3BFC0000
constexpr uint32_t FRT_BUF_BYTES = (uint32_t)BLT_MAXP * BLT_MAXF * 8u;  // 8 B per (pid,frame)
constexpr uint32_t OFF_CFTBUF    = 0x00FC2000u;                    // ddr-relative: 0x3BFC2000
constexpr uint32_t CFT_BUF_BYTES = (uint32_t)BLT_MAXP * 2u;        // u16 per pattern
static_assert(OFF_FRTBUF == OFF_TLBUF + TL_BUF_BYTES,
              "[#52] FRT must sit immediately above TL_BUF (matches fabric FRT_BUF_QW)");
static_assert(OFF_FRTBUF + FRT_BUF_BYTES <= OFF_CFTBUF,
              "[#52] FRT must not overlap CFT");
static_assert(OFF_CFTBUF + CFT_BUF_BYTES <= BLT_DDR_SIZE,
              "[#52] CFT must fit inside the mapped DDR region");
// [MiSTer #33] SDRAM-VRAM (decoupled source addressing). The fitted AS4C32M16 chip is
// 64 MiB. The dynamic atlas allocator is based ABOVE the fixed bg-cache SDRAM offset
// (BGCACHE_HEAP_OFF ~15.7 MiB, staged at the same offset #19-style) so atlas offsets
// never collide with it. 16 MiB base -> ~48 MiB atlas region.
constexpr uint32_t SDRAM_CAP        = 0x04000000u;                 // 64 MiB (single AS4C32M16)
constexpr uint32_t SDRAM_ATLAS_BASE = 0x01000000u;                 // 16 MiB; > BGCACHE_HEAP_OFF
// control-block byte offsets — QWORD-spaced (fabric reads qword fields), low 32 used
constexpr uint32_t C_SUBMIT = 0x00, C_CMDCOUNT = 0x08, C_TARGET = 0x10,
                   C_CLEAR  = 0x18, C_FLAGS    = 0x20, C_DONE = 0x28,
                   C_STATUS = 0x30,  // low32=status; high32=perf_pipe_cyc (HW perf)
                   C_SRCSEL = 0x38;   // bit0 (source mux) now dead — source always
                                      // SDRAM; bits[15:8] carry the f2h write-throttle

constexpr int FB_W = 320, FB_H = 240;

// Video control word @ 0x3A000000 (shared with native_video_writer):
//   frame_counter[31:2] | active_buf[1:0]. The fabric bumps this itself on a
//   blitter submit, but native_video_writer keeps a *separate* internal toggle.
//   We read/seed it so blitter-frames and escape-frames advance one buffer at a
//   time without colliding.
constexpr uint32_t VIDEO_CTRL_PHYS = 0x3A000000u;
// Scanout VSYNC counter (anti-tearing): the fabric's video reader increments this at
// 0x3A070000 each displayed frame (vblank). The engine waits for it to advance before
// producing the next frame -> one frame per scan into the non-displayed buffer, instead
// of free-running and racing the buffer swap (which tore the analog output at ~60fps).
// MUST MATCH fpga/rtl/openbor_video_reader.sv VSYNC_ADDR. Offset within the vid mmap.
constexpr uint32_t VSYNC_OFF = 0x00070000u;

// [MiSTer #34] SDRAM framebuffer byte bases — MUST MATCH fpga/rtl/vram_defs.vh
// SDRAM_FB0_BASE / SDRAM_FB1_BASE. The vram_demux decodes the blitter's DDR
// FB qword addresses (FB0_QW/FB1_QW) and remaps writes to these SDRAM bases;
// the scanout reads FB from these same SDRAM addresses.
// src_off in an F_SRC_SDRAM BLIT is the direct SDRAM byte base (not heap-relative),
// matching the proven Task-5 PHASE4 command (src_off=0x440000, F_SRC_SDRAM, PASS).
constexpr uint32_t SDRAM_FB0_BASE = 0x00400000u;   // vram_defs.vh SDRAM_FB0_BASE
constexpr uint32_t SDRAM_FB1_BASE = 0x00440000u;   // vram_defs.vh SDRAM_FB1_BASE

inline uint16_t to_rgb565(uint8_t r, uint8_t g, uint8_t b) {
  return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}
}  // namespace

// [MiSTer #34] Full-screen SDRAM FB->FB carry-forward copy. Emits a BLT_OP_BLIT
// COPY whose SOURCE is src_buf's FB in SDRAM (direct byte base, per vram_defs.vh)
// with BLT_F_SRC_SDRAM set so the blitter's src_sdram_addr path is selected.
// The DST is the frame's current target buffer; vram_demux redirects the write
// to SDRAM. Mirrors Task-5 PHASE4 exactly: src_off=SDRAM_FB{src_buf}_BASE,
// flags=BLT_F_SRC_SDRAM, w=320, h=240, stride=640, dst=(0,0).
// Called AFTER blt_begin_frame (clear=0) so incremental draws composite on top.
static int blt_blit_fb_copy(blt_emitter_t *em, int src_buf) {
    blt_cmd_t c; memset(&c, 0, sizeof(c));
    c.opcode     = BLT_OP_BLIT;
    c.blend_mode = BLT_BLEND_COPY;
    c.format     = BLT_FMT_RGB565;
    c.flags      = BLT_F_SRC_SDRAM;     // blitter reads src from SDRAM, not heap
    c.src_off    = src_buf ? SDRAM_FB1_BASE : SDRAM_FB0_BASE;  // direct SDRAM byte base
    c.src_stride = (uint16_t)(FB_W * 2); // 320 px * 2 B = 640 B/row
    c.src_x      = 0; c.src_y = 0;
    c.w          = (uint16_t)FB_W;       // 320 px
    c.h          = (uint16_t)FB_H;       // 240 px
    c.dst_x      = 0; c.dst_y = 0;
    // emit() is static in blt_emitter.c; replicate its logic inline using the
    // public blt_cmd_t → blt_pack_cmd API via a stack buffer routed through the ring.
    // Actually, use blt_blit() public API with a synthetic handle instead:
    // blt_blit() only checks s.valid and s.sdram_off, then overrides src_off / flags.
    // Build a synthetic ref that forces the SDRAM path (sdram_off set to the FB base,
    // em->sdram_src==1 guaranteed now that stage_enabled is always true).
    blt_surface_ref_t s{};
    s.valid      = 1;
    s.off        = 0;                    // DDR heap offset unused (sdram takes over)
    s.sdram_off  = c.src_off;           // SDRAM byte base — blt_blit picks this up
    s.stride     = c.src_stride;
    s.w          = c.w;
    s.h          = c.h;
    s.format     = BLT_FMT_RGB565;
    s.size       = 0;                    // not heap-allocated; no free needed
    // BLT_F_SRC_FB: this source FB was written by the compositor via ch0 (P_DST); the
    // fabric must commit ch0 + invalidate ch5 (the dst-barrier) before reading it back
    // through P_SRC, or the carry-forward reads stale pixels and the two display buffers
    // diverge (hero/NPCs flip between two frames — the single-pipeline overworld bug).
    return blt_blit(em, s, 0, 0, (int)c.w, (int)c.h, 0, 0,
                    BLT_BLEND_COPY, 0, 0, BLT_F_SRC_FB);
}

// =====================================================================
struct MisterBlitterRenderer::Impl {
  volatile uint8_t* ddr = nullptr;
  int mem_fd = -1;
  blt_emitter_t em{};

  // Optional second mapping of the VIDEO framebuffer region (0x3A000000) so we
  // can read back what the fabric composited and compare it, IN-PROCESS, to the
  // software frame. In-process is the only reliable readback: a separate
  // devmem/dd process gets a fresh cached mapping of normal DDR and reads stale
  // zeros (confirmed: even the proven pure-SDL baseline reads 0 via devmem).
  bool verify = false;
  volatile uint8_t* vid = nullptr;
  int vid_fd = -1;
  SDL_Renderer* sdl = nullptr;          // base SDL renderer, for software readback
  long g_verify_n = 0; double g_verify_match = 0.0; long g_verify_nz = 0;

  // The 320x240 render-target surface we accelerate (the quest root surface).
  // Locked on the first 320x240 non-screen target we see drawn to, so we don't
  // mistake a transient same-size buffer for the root.
  const SurfaceImpl* fpga_target = nullptr;

  // --- render-target aliasing (the offtarget=454 fix) -----------------------
  // Solarus does NOT composite sprites/tiles straight onto the root (fpga_target)
  // surface. Map::draw() composites the whole visible frame onto the CAMERA
  // surface (a separate full-quest-size texture), then Game::draw() blits that
  // camera surface 1:1 onto the root. So the ~454 per-frame sprite/tile draws
  // land on the camera surface and are "offtarget" w.r.t. the root.
  //
  // We detect the camera surface as the source of the camera->root promote-blit
  // (a full-frame, unrotated, unscaled, opaque 1:1 copy onto fpga_target) and
  // remember it as an ALIAS of the DDR framebuffer at the camera's screen
  // offset. From the next frame on, draws onto the camera surface emit blitter
  // commands into the SAME DDR framebuffer (dst += alias offset), and the
  // promote-blit itself is skipped (its content is already composited in DDR).
  // Root-level HUD/menu draws then composite on top. Net effect: the bulk of the
  // frame composites on the fabric instead of escaping. (Detection persists
  // across frames — "first wins" like fpga_target — so the within-frame ordering
  // problem, camera draws BEFORE the promote-blit, resolves on the next frame.)
  const SurfaceImpl* alias_target = nullptr;
  int alias_off_x = 0, alias_off_y = 0;
  // Was the aliased surface actually DRAWN ONTO this frame? The alias optimization
  // (skip the promote-blit + hardware-clear the buffer, trusting the per-frame
  // camera draws to repaint it in DDR) is ONLY valid when the surface is genuinely
  // re-composited every frame — true for the game CAMERA (Map::draw repaints it),
  // but NOT for a static menu surface that is drawn once then merely re-blitted.
  // looks_like_promote() can't tell them apart (both are full-frame 1:1 copies), so
  // it would alias a menu's self.surface, then every frame clear the buffer and
  // skip the promote -> a BLACK frame (the overworld/menu freeze: first frame shown,
  // never updated). We instead decide PER FRAME: if the aliased surface received
  // draws this frame, skip the promote (its content is freshly in DDR); if it got
  // ZERO draws, fall back to emitting the promote as a normal full-frame blit of
  // the surface's (dirty-refreshed) current pixels — always correct.
  bool alias_drawn_this_frame = false;

  // ── [#52 resident] Tier A resident animated-tile list (SOLARUS_TILERESIDENT) ──
  // The animated tiles are STATIC content: while the camera is still and the
  // map/tileset are unchanged, the set of visible tiles + their dst are identical
  // frame-to-frame; only each pattern's src rect changes, and only when it ticks.
  // So we build the tile list ONCE (a "build" frame), record where draw_tile_batch
  // wrote each bucket's entries in TL_BUF, and on later "fast" frames re-emit those
  // headers (patching only ticked patterns' src in place). On FAST frames
  // draw_tile_batch is NOT called, so TL_BUF is untouched and the entries persist.
  bool res_enabled = false;                    // SOLARUS_TILERESIDENT[_HW]
  bool res_hw      = false;                     // SOLARUS_TILERESIDENT_HW (Tier B fabric)
  // cached scene signature [#52 camera-independent] — camera (vpx/vpy) is NO LONGER part
  // of the signature: the resident list stores whole-map MAP-coord dsts and the fabric
  // applies a per-bucket camera bias each frame, so a camera move never forces a rebuild.
  uintptr_t res_map = 0, res_tileset = 0;
  bool res_valid    = false;                   // a completed build is cached
  bool res_eligible = true;                    // build had no escapes -> fast usable
  bool res_building = false;                   // recording a build this frame
  bool res_build_escape = false;               // escape seen during the in-progress build
  bool res_hw_overflow = false;                // >BLT_MAXP patterns -> Tier B disabled (use Tier A)
  bool res_hw_armed = false;                   // 8-byte entries + FRT written for this scene
  bool res_frt_uploaded = false;               // FRT_UPLOAD emitted this scene
  // one resident entry's (pattern_id, dst) for the Tier B 8-byte TL_BUF layout.
  struct ResEnt { uint16_t pid; int16_t dx, dy; };
  struct ResBucket {
    const SurfaceImpl* tsimg; uint8_t blend, flags, fmt; uint16_t key;
    uint32_t entry_off; int count; int layer;  // Tier A: 12-byte entries written at build
    int scroll_ratio;                          // [#52 camera-indep] 1=normal, r=parallax
    uint32_t hw_off; int hw_count;             // Tier B: 8-byte entries written at arm
    std::vector<ResEnt> hw;                    // (pid,dst) sequence for the 8-byte entries
  };
  struct ResPattern {
    uintptr_t token; Rectangle src; std::vector<uint32_t> offs;   // Tier A patch targets
    int frame_count = 1; Rectangle frames[BLT_MAXF]; uint16_t cur_frame = 0;  // Tier B FRT/CFT
  };
  std::vector<ResBucket>  res_buckets;
  // [#52 resident] Per-layer ORDERED op list so escapes (repeated/parallax tiles that
  // don't batch) interleave with buckets in strict encounter (paint) order on replay.
  // A scene with a few escapes stays eligible: the fast path replays buckets via the
  // renderer and re-issues the escaped tiles' tile.draw() (engine-side) in order — only
  // the minority escaped tiles pay per-tile cost. (Was: any escape disqualified the
  // whole scene to legacy -> eligible=0 on every real overworld.)
  struct ResOp { bool esc; uint32_t bk; uintptr_t tile; int layer; };
  std::vector<ResOp>      res_ops;
  std::vector<ResPattern> res_patterns;        // distinct pattern tokens (animated + static)
  std::unordered_map<uintptr_t, size_t> res_pat_index;  // token -> res_patterns idx
  // per-frame memoization (keyed by res_epoch, bumped each present())
  unsigned res_epoch = 0;
  unsigned res_decided_epoch = ~0u; int res_mode = 0;
  unsigned res_patch_epoch = ~0u;
  // diag tallies (/60fr)
  long res_rebuilds = 0, res_patch_passes = 0, res_noops = 0, res_patched_entries = 0;
  long res_escapes = 0;                         // escaped tiles replayed per fast frame (/60fr)
  bool res_hw_active() const { return res_hw && !res_hw_overflow; }

  // per-frame state
  bool frame_active  = false;
  bool frame_escaped = false;
  bool clear_requested = false;   // Solarus issued clear(fpga_target) this frame ->
                                  // hardware-clear the DDR buffer; else persist it
  int  target_buf    = 0;
  // Debug toggle (SOLARUS_BLITTER_SINGLEBUF): never alternate the display buffer
  // (composite into buffer 0 forever). Normally OFF: we double-buffer with a
  // carry-forward copy (see ensure_frame) for tear-free persistence.
  bool single_buf    = false;
  bool heap_reset_pending = false;   // a frame overflowed -> reclaim heap next frame
  bool did_reset_last     = false;   // we reclaimed the heap at the start of this frame
  bool was_in_transition  = false;   // [MiSTer #24] track g_transition_scroll for edge-reset
  bool scene_too_big      = false;   // a reset did NOT clear overflow -> one frame's
                                     // working set genuinely exceeds the heap; stop
                                     // resetting (avoid per-frame re-upload thrash)
                                     // until the scene changes (see invalidate()).

  // env-gated diagnostics (SOLARUS_BLITTER_DIAG=1): per-window tallies.
  bool diag = false;
  long g_fills = 0, g_blits = 0, g_alias_blits = 0, g_escapes = 0, g_offtarget_draw = 0;
  long g_frames_emit = 0, g_frames_escape = 0, g_uploads = 0, g_reuploads = 0;
  // [#52] convert-cost split: pixels converted per bucket (cold cache-miss upload
  // vs dirty-surface reupload) + how many were "large" (>= 256x256). Decides how
  // much of the convert storm a permanent/pre-loaded static atlas pool can remove
  // (cold uploads — yes) vs the dynamic reup tail (no, runtime-generated pixels).
  long g_upload_px = 0, g_reup_px = 0, g_upload_big = 0, g_reup_big = 0;
  long g_cvt_fallback = 0;   // [#52] times mpix returned false -> slow SDL convert path used
  long g_hwclear = 0, g_carryfwd = 0;   // per-window: DDR hardware-clears vs carry-forwards
  long g_esc_rot = 0, g_esc_scale = 0, g_esc_tint = 0, g_esc_alpha = 0,
       g_esc_mode = 0, g_esc_upload = 0, g_esc_overflow = 0, g_esc_toobig = 0;
  int  diag_n = 0;
  // distinct OFFTARGET (branch-3 software-composite) dst surfaces seen this window,
  // to compare against alias_target (why the camera composite doesn't offload).
  const void* off_dst[8] = {0}; int off_dst_w[8] = {0}, off_dst_h[8] = {0};
  long off_dst_cnt[8] = {0}; int off_dst_n = 0;
  void rec_offtarget_dst(const void* p, int w, int h) {
    for (int i = 0; i < off_dst_n; i++) if (off_dst[i] == p) { off_dst_cnt[i]++; return; }
    if (off_dst_n < 8) { off_dst[off_dst_n] = p; off_dst_w[off_dst_n] = w;
      off_dst_h[off_dst_n] = h; off_dst_cnt[off_dst_n] = 1; off_dst_n++; }
  }
  // src-SIZE histogram for offtarget draws onto an FB_W-wide (camera) surface —
  // reveals what the heavy composite is made of (cells/tiles/sprites).
  int  osrc_w[16] = {0}, osrc_h[16] = {0}; long osrc_cnt[16] = {0}; int osrc_n = 0;
  void rec_offtarget_src(int w, int h) {
    for (int i = 0; i < osrc_n; i++) if (osrc_w[i] == w && osrc_h[i] == h) { osrc_cnt[i]++; return; }
    if (osrc_n < 16) { osrc_w[osrc_n] = w; osrc_h[osrc_n] = h; osrc_cnt[osrc_n] = 1; osrc_n++; }
  }
  // --- P0 op-profile (issue #13): the op mix the FPGA Renderer backend must serve.
  // Tallied for EVERY draw() (all paths) per 60-frame window. Sizes the fast-path
  // (1:1 region blit + blend + opacity) vs the fallback (rotation/scale/color-mod).
  long p0_blend[4] = {0};        // by BlendMode: 0 NONE,1 BLEND,2 ADD,3 MULTIPLY
  long p0_op_full = 0, p0_op_part = 0;   // opacity==255 vs <255
  long p0_rot = 0, p0_scale = 0, p0_colormod = 0;   // transform usage (fallback drivers)
  long p0_draws = 0, p0_fills = 0;
  const void* p0_tex[24] = {0}; int p0_tex_n = 0;   // distinct surfaces touched (dst|src)
  void p0_rec_tex(const void* p) {
    for (int i = 0; i < p0_tex_n; i++) if (p0_tex[i] == p) return;
    if (p0_tex_n < 24) p0_tex[p0_tex_n++] = p;
  }
  void p0_record(const SurfaceImpl& dst, const SurfaceImpl& src, const DrawInfos& infos) {
    p0_draws++;
    int bm = (int)infos.blend_mode; if (bm >= 0 && bm < 4) p0_blend[bm]++;
    if (infos.opacity == 255) p0_op_full++; else p0_op_part++;
    if (std::fabs(infos.rotation) > 1e-3) p0_rot++;
    if (std::fabs(infos.scale.x - 1.f) > 1e-3 || std::fabs(infos.scale.y - 1.f) > 1e-3) p0_scale++;
    if (!(infos.color == Color::white)) p0_colormod++;
    p0_rec_tex(&dst); p0_rec_tex(&src);
  }
  int  diag_frame_log = 0;   // per-frame trace counter (first N frames)
  int  diag_frame_log_max = 60;   // N: SOLARUS_BLITTER_TRACE_N overrides (overworld)

  // --- frame-timing instrumentation (A9 vs fabric split + pacing) -----------
  // The ensure_frame handshake SERIALIZES A9 and fabric (single command ring), so
  // frame_period = fabric_compute (the ensure spin) + A9_emit + pacing_sleep. We
  // measure each to see which dominates (the 60fps bottleneck) and the pipeline
  // ceiling (max(A9,fabric) if we double-buffered the ring vs the current sum).
  // 64-bit: armhf `long` is 32-bit (~2.1e9 max) and 60 frames of ns overflow it.
  long long t_period_ns = 0, t_fab_ns = 0, t_sleep_ns = 0;   // per-window sums
  long t_fab_iters = 0;                                  // ensure-spin poll count
  // [HW perf] per-window sums of the fabric-side cycle counters the blitter publishes
  // in C_DONE[63:32] / C_STATUS[63:32] (clk_sys cycles a frame spent fabric-busy, and
  // the compositor-busy subset). Converted to ms with FABRIC_HZ for the timing line —
  // the precise on-fabric busy time vs the host's nanosleep-polled t_fab_ns.
  long long t_hw_fab_cyc = 0, t_hw_pipe_cyc = 0;
  long long t_period_min = 0, t_period_max = 0;          // jitter (per-window)
  struct timespec t_prev_present{0, 0};
  static long long ns_diff(const struct timespec& a, const struct timespec& b) {
    return (long long)(a.tv_sec - b.tv_sec) * 1000000000LL
         + (long long)(a.tv_nsec - b.tv_nsec);
  }

  // --- A9 breakdown (issue #26): split the A9 residual (period-fabric-sleep) into
  //   lua/update = present-return -> first render op of the frame
  //   emit       = (first render op -> next present-entry) - fabric - sleep
  //              (the fabric handshake + vblank barrier both run inside ensure_frame,
  //               which fires on the first backed op, so they land in this window;
  //               subtract the per-window fabric/sleep sums to isolate pure emit)
  //   present-ov = A9 - lua - emit  (submit/doorbell/input-poll/bgcache SM in present())
  // Tells us whether the A9 cost (the 60fps bottleneck) is Lua game logic or blit
  // emission. NOTE: the emit subtraction assumes vsync_pace (sleep in ensure_frame);
  // with SOLARUS_NO_VSYNC the free-run sleep is in present() so emit is over-stated.
  struct timespec t_present_ret{0, 0};   // when present() last returned (frame boundary)
  struct timespec t_first_draw{0, 0};    // first render op of the current frame
  bool      frame_drawn = false;         // seen first render op since last present
  long long t_lua_ns = 0, t_draw_ns = 0; // per-window sums
  long long t_lua_vm_prev = 0;           // [#26] last snapshot of g_mister_lua_vm_ns (for per-window delta)
  // [#52] last snapshots of the engine-side draw-category counts + eng_cpp sub-timers.
  long long t_da_anim_prev = 0, t_da_ent_prev = 0;
  long long t_uh_prev = 0, t_ue_prev = 0, t_un_prev = 0, t_ut_prev = 0;
  long long t_usnd_prev = 0, t_steps_prev = 0;   // [eng_cpp "other"] sound + step-count
  void mark_render() {                    // call at top of clear/fill/draw
    if (!diag || frame_drawn) return;
    struct timespec n; clock_gettime(CLOCK_MONOTONIC, &n);
    if (t_present_ret.tv_sec || t_present_ret.tv_nsec)
      t_lua_ns += ns_diff(n, t_present_ret);
    t_first_draw = n;
    frame_drawn = true;
  }

  // --- per-layer BLIT-PARAM stability (resolves "does the background scroll?") --
  // For each distinct source surface, hash ALL its blit params (src-region + dst)
  // within a frame; compare that hash to last frame's. stable% = how often a layer's
  // composite is IDENTICAL frame-to-frame -> the cacheable static background. A
  // scrolling/animated layer (hero) varies -> low stable%. Decides the cache design.
  // 128 (was 16): with only 16 slots the early DYNAMIC sources filled the table and
  // ps_add() dropped the static background cells (returns when full) -> they were
  // never classified static -> bg_hash stayed 0 -> the bg-cache never engaged in
  // gameplay (it worked only in simple menus). Sizing for the full per-scene source
  // set (tiles+sprites, P0 distinct_tex<=~12/window) lets the static set classify.
  static const int PST_N = 128;
  const void* ps_ptr[PST_N] = {0};
  unsigned long long ps_hash[PST_N] = {0}, ps_lasthash[PST_N] = {0};
  long ps_stable[PST_N] = {0}, ps_vary[PST_N] = {0};   // per-diag-window (reset each 60fr)
  long ps_seen[PST_N] = {0}, ps_stable_life[PST_N] = {0};  // lifetime (for classification)
  int  ps_w[PST_N] = {0}, ps_h[PST_N] = {0};
  bool ps_drawn[PST_N] = {false};            // appeared this frame
  int  ps_used = 0;
  // classify: a src seen for >=30 frames and >=90% param-stable over its lifetime is a
  // static-background layer (bg-cache candidate). The hero (varies every frame) fails this.
  bool ps_is_static(const void* p) {
    for (int i = 0; i < ps_used; i++) if (ps_ptr[i] == p)
      return ps_seen[i] >= 30 && ps_stable_life[i] * 10 >= ps_seen[i] * 9;
    return false;
  }
  void ps_add(const void* p, int sx, int sy, int w, int h, int dx, int dy,
              int sw, int sh) {
    int i; for (i = 0; i < ps_used; i++) if (ps_ptr[i] == p) break;
    if (i == ps_used) { if (ps_used >= PST_N) return;
      ps_ptr[i] = p; ps_w[i] = sw; ps_h[i] = sh; ps_used++; }
    // SCROLL-INVARIANT classification ONLY when the scroll cache is on: hash the dst
    // in MAP coords (screen dst + camera) so a fixed tile keeps a stable hash while
    // scrolling (the scroll cache shifts the bg). For the DEFAULT cache it MUST stay
    // SCREEN coords: scrolling then changes the hash -> the cache drops to LEARN (full
    // composite) while moving, which is correct. (Map coords in the default cache made
    // it stay ACTIVE and blit a FROZEN unshifted bg while the camera scrolled -> the
    // background desynced from the moving foreground, worst at the entering edge.)
    const int mdx = scroll_cache ? dx + g_cam_x : dx;
    const int mdy = scroll_cache ? dy + g_cam_y : dy;
    unsigned long long k =
        ((unsigned long long)(sx & 0xffff))        | ((unsigned long long)(sy & 0xffff) << 16) |
        ((unsigned long long)(w  & 0xffff) << 32)  | ((unsigned long long)(h  & 0xffff) << 48);
    k ^= ((unsigned long long)(mdx & 0xffff) * 2654435761ull) ^
         ((unsigned long long)(mdy & 0xffff) * 40503ull);
    ps_hash[i] = ps_hash[i] * 1000003ull ^ k;
    ps_drawn[i] = true;
  }
  void ps_frame_end() {                 // call once per present
    for (int i = 0; i < ps_used; i++) {
      if (!ps_drawn[i]) continue;       // only score srcs that appeared this frame
      bool stable = (ps_hash[i] == ps_lasthash[i]);
      if (stable) ps_stable[i]++; else ps_vary[i]++;     // per-diag-window
      ps_seen[i]++; if (stable) ps_stable_life[i]++;     // lifetime (classification)
      ps_lasthash[i] = ps_hash[i]; ps_hash[i] = 0; ps_drawn[i] = false;
    }
  }

  // ===== BACKGROUND-COMPOSITE CACHE (SOLARUS_BGCACHE) ======================
  // Static map-background layers (classified via ps_is_static) recompose to an
  // IDENTICAL image every frame (param-stab=100%); only the hero moves. Instead of
  // re-compositing the ~6 full-screen static layers each frame (the 44ms fabric cost),
  // snapshot the composited background ONCE into bg_cache (a heap source) and per frame
  // emit one opaque copy(bg_cache)->fb + only the dynamic blits. State machine:
  //   LEARN    : full composite; learn the static set + watch the static-param hash.
  //   SNAPSHOT : render STATIC-ONLY this frame; after the fabric finishes, memcpy
  //              fb -> bg_cache; -> ACTIVE.
  //   ACTIVE   : emit copy(bg_cache) + DYNAMIC-ONLY (skip static). If the static hash
  //              changes (scene change / SCROLL), -> LEARN (scroll never stabilizes, so
  //              it stays in LEARN = normal composite = correct fallback).
  bool alias_allow_sw = false;           // SOLARUS_ALIAS_SW: alias software camera surface
  bool camera_tag = true;                // deterministic camera tag (SOLARUS_NO_CAMERA_TAG=off)
  bool vsync_pace = true;                // wait on scanout VSYNC counter (SOLARUS_NO_VSYNC=off)
  uint32_t last_vsync = 0;               // last-seen scanout vsync counter
  // [lever-b] SOLARUS_FASTPACE: skip the redundant half-frame vblank-barrier wait
  // when the producer is slower than the 60Hz scanout (the A9-bound heavy-area
  // regime). In that case the fabric committed the previous frame's vctrl long ago
  // and the scanout has already ticked >=2x since we rang the submit doorbell, so
  // it has latched that vctrl and swapped off the buffer we are about to reuse ->
  // the anti-tearing wait is a no-op that still costs ~half a scan frame (~8ms).
  // Off by default (opt-in for A/B + because tearing is HW-only-verifiable).
  bool vsync_fastpace = false;
  uint32_t submit_vsync = 0;             // scanout vsync counter sampled at last submit doorbell
  long g_fastpace_skips = 0;             // diag: barriers skipped by the fastpace fast-path /60fr
  bool bgcache_enabled = false;          // SOLARUS_BGCACHE
  // [collapse-single-source] Source staging is now UNCONDITIONAL: the fabric reads
  // every atlas source from SDRAM (the DDR3 live-source path was removed), so we
  // ALWAYS stage atlases DDR3->SDRAM and ALWAYS write C_SRCSEL=1. No env opt-in.
  bool stage_enabled   = true;           // always: stage sources + read them from SDRAM
  uint32_t throttle_val = 32;            // [MiSTer #34] f2h write-throttle cycles (SOLARUS_BLT_THROTTLE)
  enum { BG_LEARN = 0, BG_SNAPSHOT = 1, BG_ACTIVE = 2 };
  int  bg_state = BG_LEARN;
  unsigned long long bg_hash = 0;        // this frame's static-set param hash (accum in draws)
  unsigned long long bg_last_hash = 0;   // previous frame's static hash (stability watch)
  unsigned long long bg_cache_hash = 0;  // hash the snapshot was taken at
  int  bg_stable_run = 0;                // consecutive frames bg_hash unchanged
  int  bg_snap_buf = 0;                  // buffer the SNAPSHOT pass rendered into
  // [MiSTer #19] CHUNKED bg-cache staging cursor. The bg-cache is composited by the
  // FABRIC straight into DDR3 (C_TARGET=2) and never passes through blt_upload, so it
  // must be STAGED (copied DDR3->SDRAM) before the cache read at C_SRCSEL=1 (else the
  // read returns 0 = BLACK background). Staging the WHOLE 153600-byte cache in ONE
  // STAGE on the first ACTIVE frame issued a single huge DDR3 read burst on the SAME
  // f2h bus the scanout uses to fetch the framebuffer -> that one frame STARVED the
  // scanout reads -> the game image dropped (HW-diagnosed: video disappears, OSD on
  // chip stays up). FIX: sweep the cache into SDRAM a SMALL slice per ACTIVE frame,
  // advancing bg_stage_off until the whole cache is staged, so each frame's DDR3 read
  // is tiny and the f2h bus stays free for scanout. Staging is "active" while
  // bg_stage_off < CACHE_SIZE. Reset to 0 at each SNAPSHOT->ACTIVE transition so SDRAM
  // re-tracks a freshly-composited (possibly changed) cache.
  // CACHE_SIZE bytes = FB_W*FB_H*2 = 153600 (RGB565 320x240).
  static constexpr uint32_t CACHE_SIZE = (uint32_t)(FB_W * FB_H * 2);   // 153600
  // Per-frame slice size. ~8 KiB keeps the per-frame DDR3 read small enough to avoid
  // scanout starvation; 8-byte aligned because the STAGE copy is beat=8-byte granular.
  // 8192 B / 8192 = 153600/8192 -> ceil = 19 frames (~0.32 s @ 60 fps) to fully stage.
  static constexpr uint32_t BG_STAGE_CHUNK = 8192;                      // 19 frames
  uint32_t bg_stage_off = CACHE_SIZE;    // next byte to stage; ==CACHE_SIZE => done/idle
  blt_surface_ref_t bg_handle{};         // bg_cache as a heap source (manually constructed)
  long bg_skips = 0, bg_copies = 0, bg_snaps = 0;   // diag tallies
  // is this src a dynamic (non-static-bg) layer? (the hero/HUD that must redraw)
  bool bg_is_dynamic(const void* p) { return !ps_is_static(p); }

  // ---- SCROLL-AWARE cache (SOLARUS_SCROLLCACHE, issue #21) -------------------
  // The plain bg-cache invalidates on any scroll (the bg shifts). Scroll-aware:
  // blit the cached bg SHIFTED by the camera delta (snap_cam - cur_cam) so the
  // overlap stays valid, and re-composite ONLY the newly-revealed edge cells; when
  // the shift grows past MAXSHIFT (snapshot no longer covers enough), re-snapshot.
  bool scroll_cache = false;             // SOLARUS_SCROLLCACHE
  int  snap_cam_x = 0, snap_cam_y = 0;   // camera top-left (map coords) at snapshot
  int  cur_dx = 0, cur_dy = 0;           // this frame's shift = cur_cam - snap_cam
  static const int MAXSHIFT = 96;        // re-snapshot when |shift| exceeds this
  // Is a destination rect (screen coords) inside the strip the shifted snapshot does
  // NOT cover (so the live cell there must be composited)? dx>0 => right strip
  // uncovered, dx<0 => left; dy similarly bottom/top.
  bool in_uncovered_margin(int x, int y, int w, int h) const {
    const int x2 = x + w, y2 = y + h;
    if (cur_dx > 0 && x2 > FB_W - cur_dx) return true;   // right strip
    if (cur_dx < 0 && x  < -cur_dx)       return true;   // left strip
    if (cur_dy > 0 && y2 > FB_H - cur_dy) return true;   // bottom strip
    if (cur_dy < 0 && y  < -cur_dy)       return true;   // top strip
    return false;
  }

  // cache key: a surface may be uploaded in two formats (RGB565 for opaque /
  // colorkey / const-alpha, ARGB4444 for per-pixel alpha) — cache per (ptr,fmt).
  struct SurfKey {
    const SurfaceImpl* p; uint8_t fmt;
    bool operator==(const SurfKey& o) const { return p == o.p && fmt == o.fmt; }
  };
  struct SurfKeyHash {
    size_t operator()(const SurfKey& k) const {
      return std::hash<const void*>()(k.p) ^ (size_t)k.fmt * 0x9E3779B97F4A7C15ull;
    }
  };
  // cache: (SurfaceImpl,fmt) -> uploaded source handle (static atlases upload once)
  std::unordered_map<SurfKey, blt_surface_ref_t, SurfKeyHash> handles;
  // surfaces too large to ever fit the heap: remember so we escape them
  // cheaply (one verdict) instead of re-trying SDL convert + a poisoning
  // blt_upload overflow every single frame.
  std::unordered_set<const SurfaceImpl*> too_big;

  // Source surfaces whose pixels were MUTATED (drawn/filled/cleared onto) since
  // their last upload — their cached heap copy is now STALE and must be refreshed
  // before it's blitted again. Solarus menus (title/logo/dialog) draw their
  // animated content onto an OWN intermediate 320x240-or-smaller surface every
  // frame, then blit that surface onto the root. That intermediate is an SDL-
  // backed source from our POV (case 3): the base SDLRenderer renders into it and
  // marks it dirty, but our heap cache keyed by ptr never noticed the change and
  // served the FIRST-frame snapshot forever — a frozen logo / clouds, which on
  // the rare readback-fallback frame snapped to the live software frame and back
  // (the title/intro flashing). We track mutation here and re-upload IN PLACE
  // (same dims -> same heap slot, no leak) the next time the surface is used as a
  // blit source, so every committed frame composites the surface's CURRENT pixels.
  std::unordered_set<const SurfaceImpl*> dirty_src;
  void mark_src_dirty(const SurfaceImpl* p) { if (p) dirty_src.insert(p); }

  bool map_ddr() {
    mem_fd = ::open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) return false;
    void* p = ::mmap(nullptr, BLT_DDR_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
                     mem_fd, BLT_DDR_PHYS);
    if (p == MAP_FAILED) { ::close(mem_fd); mem_fd = -1; return false; }
    ddr = static_cast<volatile uint8_t*>(p);
    // Cap the bump heap BELOW the fixed off-screen bg-cache region (OFF_BGCACHE) so it
    // can never overwrite it. With the 16 MiB region the heap still gets ~15.7 MiB —
    // far above any scene/transition working set (~few MiB) — so this costs nothing.
    blt_emitter_init(&em, (void*)(ddr + OFF_RING), RING_CAP,
                     (void*)(ddr + OFF_HEAP), BGCACHE_HEAP_OFF);
    // [#52] Bind the BLT_OP_TILELIST entry buffer to the fixed DDR base the fabric
    // reads from (ddr + OFF_TLBUF == 0x3BF40000 == fabric TL_BUF). Single buffer:
    // the submit/done handshake serializes frames, matching the fabric (no double).
    blt_tile_list_init(&em, (void*)(ddr + OFF_TLBUF), TL_BUF_BYTES);
    return true;
  }

  void ddr_w32(uint32_t off, uint32_t v) {
    *reinterpret_cast<volatile uint32_t*>(ddr + off) = v;
  }
  uint32_t ddr_r32(uint32_t off) {
    return *reinterpret_cast<volatile uint32_t*>(ddr + off);
  }

  bool map_video() {
    vid_fd = ::open("/dev/mem", O_RDWR | O_SYNC);
    if (vid_fd < 0) return false;
    void* p = ::mmap(nullptr, 0x00100000u, PROT_READ | PROT_WRITE, MAP_SHARED,
                     vid_fd, VIDEO_CTRL_PHYS);
    if (p == MAP_FAILED) { ::close(vid_fd); vid_fd = -1; return false; }
    vid = static_cast<volatile uint8_t*>(p);
    return true;
  }

  // In-process verification: wait (bounded) for the fabric DONE==submit, then
  // read back the framebuffer the fabric composited and compare it pixel-wise to
  // the software-rendered frame. Logs running match% + nonzero-pixel count.
  void verify_committed(struct SDL_Window* /*window*/, int submitted_buf) {
    if (!verify || !vid || !sdl) return;
    // Wait for the fabric to finish this submission (DONE mirrors submit_seq).
    for (int i = 0; i < 100000; ++i) {
      if (ddr_r32(C_DONE) == em.submit_seq) break;
    }
    const uint32_t buf_off = submitted_buf ? 0x00040040u : 0x00000040u;
    const volatile uint16_t* fb =
        reinterpret_cast<volatile uint16_t*>(vid + buf_off);

    static std::vector<uint16_t> sw;
    if (sw.size() < (size_t)FB_W * FB_H) sw.resize((size_t)FB_W * FB_H);
    if (SDL_RenderReadPixels(sdl, nullptr, SDL_PIXELFORMAT_RGB565,
                             sw.data(), FB_W * 2) != 0)
      return;

    long match = 0, nz = 0;
    for (int i = 0; i < FB_W * FB_H; ++i) {
      uint16_t f = fb[i];
      if (f != 0) nz++;
      if (f == sw[(size_t)i]) match++;
    }
    g_verify_n++;
    double mpct = 100.0 * match / (FB_W * FB_H);
    g_verify_match += mpct;
    g_verify_nz += nz;
    if ((g_verify_n % 10) == 0) {
      std::fprintf(stderr,
        "[blitter verify] committed=%ld  this-frame match=%.1f%% nonzero=%ld  "
        "| 10-frame mean match=%.1f%% mean nonzero=%ld/%d\n",
        g_verify_n, mpct, nz, g_verify_match / 10.0, g_verify_nz / 10,
        FB_W * FB_H);
      g_verify_match = 0.0; g_verify_nz = 0;
    }
  }

  // Is `dst` the FPGA target render surface? A render texture (texture() != null,
  // i.e. not the window/screen surface) sized exactly 320x240. Lock onto the
  // first such surface so later transient targets don't steal acceleration.
  bool is_fpga_target(const SurfaceImpl& dst) {
    if (!ddr) return false;
    if (dst.get_width() != FB_W || dst.get_height() != FB_H) return false;
    const SDLSurfaceImpl* s = dynamic_cast<const SDLSurfaceImpl*>(&dst);
    if (!s || !s->get_texture()) return false;  // window/screen surface -> not us
    if (!fpga_target) fpga_target = &dst;        // first wins
    return &dst == fpga_target;
  }

  void escape() { frame_escaped = true; }

  // STEP 2 (perf-offload): when a scene's source working set genuinely exceeds
  // the heap (scene_too_big — confirmed by a heap reset that did NOT clear the
  // overflow), the blitter can never composite this scene. Trying anyway costs a
  // futile SDL_ConvertSurfaceFormat + heap memcpy of every atlas EVERY frame (the
  // 535x298 hero sheet alone is 311 KiB on the 352 KiB deployed-RBF heap), which
  // collapsed overflow-gameplay to ~4 fps — WORSE than the ~30 fps pure-SDL
  // baseline. While scene_too_big we therefore disable the blitter entirely and
  // run as a plain SDLRenderer: backed-surface ops fall through to base SDL and
  // present() uses the readback fallback. invalidate() clears scene_too_big on a
  // scene change so the next (fitting) scene re-enables the offload. Net effect:
  // the blitter path is >= baseline everywhere, and far faster on screens that
  // fit (intro/title/menus/dialogs commit on the fabric at 46-100 fps).
  bool blitter_off() const { return !ddr || scene_too_big; }

  void ensure_frame() {
    if (!frame_active) {
      // Heap churn / scene-transition fix. Source uploads are bump-allocated and
      // LEAK across scene changes: invalidate() drops only the cache entry, not
      // the heap bytes, so a transition's fresh atlases overflow the heap while
      // the old scene's stale atlases still occupy it. When a frame overflowed we
      // RECLAIM the whole heap at the next frame boundary (reset + drop the cache)
      // so this frame re-uploads ONLY its own working set into an empty heap —
      // the stale scene is gone, so the new scene fits and escape resumes at 0.
      // Steady state keeps the upload-once cache (no per-frame re-upload cost);
      // only a transition pays a one-frame full re-upload.
      // [MiSTer #24] On entering OR leaving a SCROLLING map transition, reclaim the heap.
      // Across a scroll boundary the two scenes' atlases are co-resident (the old map's
      // linger while the new map uploads) and overflow the heap -> one black frame.
      // Resetting on each edge makes each scene upload into a clean heap. FADE/IMMEDIATE
      // have a single map (invalidate() frees the old map's atlases on map change), so
      // they need no reset — keyed on g_transition_scroll to skip the fade-edge fps blip.
      if (g_transition_scroll != was_in_transition) {
        heap_reset_pending = true;
        was_in_transition = g_transition_scroll;
      }
      if (heap_reset_pending) {
        blt_heap_reset(&em);
        handles.clear();
        heap_reset_pending = false;
        did_reset_last = true;  // so present() can tell if the reset cleared overflow
      }
      // HANDSHAKE: wait for the fabric to FINISH the previous frame before we
      // reset+overwrite the shared command ring/heap it is still reading. Without
      // this the A9 races ahead of the (compute-bound, ~10-15 fps) fabric, which
      // then composites a half-overwritten command list -> dropped draws, shifted
      // geometry, flashing. A too-short timeout is WORSE than none: it resets the
      // ring mid-composite and wedges the fabric (the overworld froze on frame 1).
      // Poll with a short sleep (CPU-friendly) and a generous cap that comfortably
      // exceeds even a heavy frame's composite time; only give up if the fabric is
      // truly stuck (then we proceed rather than hang forever).
      bool fab_was_ready = false;   // [lever-b] C_DONE already set on entry (fabric idle ahead)
      if (em.submit_seq != 0) {
        struct timespec ts{0, 200000};                 // 0.2 ms between polls
        struct timespec fa, fb; int spin = 0;
        if (diag) clock_gettime(CLOCK_MONOTONIC, &fa);
        for (; spin < 5000 && ddr_r32(C_DONE) != em.submit_seq; ++spin)
          nanosleep(&ts, nullptr);                      // up to ~1 s
        fab_was_ready = (spin == 0);   // fabric had already finished the prev frame
        if (diag) {
          clock_gettime(CLOCK_MONOTONIC, &fb);
          t_fab_ns += ns_diff(fb, fa);                  // ~= fabric compute time
          t_fab_iters += spin;
          // fabric-side cycle counters for THIS frame (published with C_DONE/C_STATUS).
          t_hw_fab_cyc  += ddr_r32(C_DONE   + 4);
          t_hw_pipe_cyc += ddr_r32(C_STATUS + 4);
        }
      }
      // ANTI-TEARING vblank barrier (the moving-tear fix). The fabric writes vctrl
      // AFTER all pixels and C_DONE AFTER vctrl (blitter_top S_FRAME_VCTRL->S_WR_DONE),
      // so once the handshake above sees C_DONE the just-committed frame's vctrl is in
      // DDR — but the SCANOUT has not yet latched it: it only swaps its display buffer
      // at its next vblank (openbor_video_reader ST_CHECK_CTRL). With only TWO display
      // buffers the buffer we are about to write next (target_buf == the buffer shown
      // two frames ago) is the SAME buffer the scanout may STILL be displaying until
      // that swap. Writing it now (the carry-forward memcpy below, or the fabric
      // composite this frame) races the beam -> the bottom-of-screen tear seen while
      // MOVING. So BLOCK until the scanout advances one frame (its vsync counter ticks):
      // by then it has read the committed vctrl and swapped off the buffer we reuse.
      // This is the correct place for the pace. The OLD end-of-present wait fired before
      // the composite even ran and, when the producer was slower than the 60 Hz scan
      // (moving), saw a stale-already-advanced counter and returned immediately -> no
      // protection. Skipped for the off-screen CACHE_BUILD pass (target 2 writes the
      // cache region, not a display buffer) — though running it there is merely a
      // harmless extra pace. Falls back fast if the counter isn't advancing (old RBF).
      if (vsync_pace && vid && em.submit_seq != 0) {
        volatile uint32_t* vs = (volatile uint32_t*)(vid + VSYNC_OFF);
        uint32_t base = *vs;
        // [lever-b] FASTPACE fast-path: when the producer is slower than the 60Hz
        // scanout, the barrier wait below is provably redundant. fab_was_ready means
        // the fabric finished the prev frame's composite (and thus wrote its vctrl)
        // before we even reached this frame's ensure_frame; (base - submit_vsync) >= 1
        // means the scanout has ticked at least once since we rang the submit doorbell.
        // The composite is well under one scan frame (~13ms < 16.7ms) and fab_was_ready
        // proves vctrl was already written, so that >=1 tick latched it and swapped the
        // scanout off the buffer we are about to reuse -> skip the ~half-frame wait.
        // (Was >=2, but at ~26-33fps a frame spans only ~2 scan ticks so the interval
        // submit->next-ensure_frame is often <2 ticks; >=1 + fab_was_ready is the real
        // tear-safe condition.) Falls through to the unchanged barrier when the producer
        // keeps up (fab_was_ready false / 0 ticks). uint32 subtraction is wrap-safe.
        if (vsync_fastpace && fab_was_ready &&
            (uint32_t)(base - submit_vsync) >= 1u) {
          last_vsync = base;
          if (diag) g_fastpace_skips++;
        } else {
          struct timespec st{0, 200000};                  // 0.2 ms poll
          struct timespec s0; if (diag) clock_gettime(CLOCK_MONOTONIC, &s0);
          for (int i = 0; i < 180 && *vs == base; ++i)    // up to ~36 ms (timeout)
            nanosleep(&st, nullptr);
          last_vsync = *vs;
          if (diag) {
            struct timespec s1; clock_gettime(CLOCK_MONOTONIC, &s1);
            t_sleep_ns += ns_diff(s1, s0);
          }
        }
      }
      em.overflow = 0;          // clear any stale poison from the previous frame
      // PERSISTENCE MODEL (the title/intro flashing fix). The quest render surface
      // (fpga_target) is a PERSISTENT target: Solarus clears it ONLY when it wants
      // a fresh frame (an explicit clear()), and otherwise draws incrementally on
      // top of the PREVIOUS frame's pixels — e.g. the title screen composites its
      // cloud background ONCE (during the transition) then each frame redraws only
      // the animated foreground (logo + "press space") on top. The old code
      // unconditionally hardware-cleared the DDR buffer AND alternated two buffers
      // each frame, so a committed buffer only ever held THIS frame's incremental
      // draws on black: background present on the rare full-repaint frame, gone (a
      // bare logo on black) on every incremental frame -> the flashing.
      //
      // To mirror the engine on the fabric WITHOUT either flashing OR single-buffer
      // tearing, we keep the double buffer but CARRY FORWARD: on a frame Solarus
      // did NOT clear, copy the previously-committed buffer's pixels into this
      // frame's target buffer, then let the fabric composite the incremental draws
      // (clear=0) on top. Every committed buffer therefore always holds the full,
      // current image. On a frame Solarus DID clear (clear_requested), we skip the
      // copy and hardware-clear instead (a genuine fresh frame).
      // [single pipeline] The background-composite cache (the static-layer persistence
      // optimization) was REMOVED: it persisted only the static layers and bypassed the
      // carry-forward, so the blended dynamic/overlay layers diverged between the two
      // display buffers (the slow ~3-5s overworld flip). Correctness over the DDR saving:
      // every frame now goes through the single carry-forward path, which preserves the
      // ENTIRE previous frame coherently (the dst-barrier commits ch0 + invalidates ch5
      // before the read), so both buffers always hold the full, current image.
      if (!single_buf && !clear_requested && em.submit_seq != 0) {
        // [MiSTer #34] Fabric carry-forward: copy the previously-committed FB into the
        // current target buffer in SDRAM. The ARM cannot write SDRAM directly, so this
        // MUST be a fabric OP_BLIT with F_SRC_SDRAM|F_SRC_FB. src = prev FB (!target_buf).
        // [FB-in-BRAM] DISABLED when single_buf: comp_fbram is one PERSISTENT on-chip
        // buffer, so the prior frame's pixels are already there — re-compositing the
        // incremental draws on top (the else branch, clear=0) preserves them. The old
        // F_SRC_FB copy reads the SDRAM FB, which the on-chip compositor no longer writes
        // (ch0/P_DST dead), so under FB-in-BRAM it would carry forward STALE pixels.
        blt_begin_frame(&em, target_buf, /*clear=*/0, /*clear_color=*/0x0000);
        blt_blit_fb_copy(&em, /*src_buf=*/!target_buf);   // full-screen FB->FB
        if (diag) g_carryfwd++;
      } else {
        if (diag && clear_requested) g_hwclear++;
        blt_begin_frame(&em, target_buf, /*clear=*/clear_requested ? 1 : 0,
                        /*clear_color=*/0x0000);
      }
      clear_requested = false;
      frame_active = true;
      frame_escaped = false;
      alias_drawn_this_frame = false;   // reset per-frame alias-coverage tracking
    }
  }

  // Convert an SDL surface (any format) to packed ARGB4444 {A4,R4,G4,B4} into
  // `out` (w*h uint16). Done by hand because SDL2 lacks an ARGB4444 pixel format
  // that matches our {A4,R4,G4,B4} bit order on all builds — we read each pixel's
  // RGBA8888 components and pack the high nibbles. Returns false on failure.
  bool to_argb4444(SDL_Surface* s, std::vector<uint16_t>& out) {
    out.resize((size_t)s->w * s->h);
    // [#52] fast path: NEON/scalar pack straight from the source's 32-bit pixels,
    // bypassing SDL_ConvertSurfaceFormat's per-pixel SDL_Blit_Slow.
    if (mpix::to_argb4444(s, out.data())) return true;
    // Fallback (non-32-bit / odd source formats): the original SDL conversion.
    if (diag) g_cvt_fallback++;
    SDL_Surface* c = SDL_ConvertSurfaceFormat(s, SDL_PIXELFORMAT_ARGB8888, 0);
    if (!c) return false;
    SDL_LockSurface(c);
    const uint8_t* base = static_cast<const uint8_t*>(c->pixels);
    for (int y = 0; y < c->h; ++y) {
      const uint32_t* row =
          reinterpret_cast<const uint32_t*>(base + (size_t)y * c->pitch);
      for (int x = 0; x < c->w; ++x) {
        uint32_t px = row[x];
        uint8_t a, r, g, b;
        SDL_GetRGBA(px, c->format, &r, &g, &b, &a);
        out[(size_t)y * c->w + x] = (uint16_t)(
            ((a >> 4) << 12) | ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4));
      }
    }
    SDL_UnlockSurface(c);
    SDL_FreeSurface(c);
    return true;
  }

  // Re-copy a (possibly changed) surface's CURRENT pixels into an already-
  // allocated heap slot — same dims as the cached upload, so the byte layout is
  // identical and we overwrite in place (no bump, no leak). Safe because the
  // re-upload happens after ensure_frame()'s handshake, i.e. once the fabric has
  // finished reading the previous frame's heap. Returns false if the surface's
  // dims somehow changed (shouldn't for a stable ptr) — caller then re-uploads.
  bool reupload_in_place(const SurfaceImpl& src, uint8_t fmt,
                         const blt_surface_ref_t& h) {
    SDL_Surface* s = src.get_surface();
    if (!s) return false;
    if ((uint16_t)s->w != h.w || (uint16_t)s->h != h.h) return false;
    if (fmt == BLT_FMT_ARGB4444) {
      std::vector<uint16_t> px;
      if (!to_argb4444(s, px)) return false;
      std::memcpy((void*)(em.heap + h.off), px.data(),
                  (size_t)h.w * h.h * 2u);
    } else {
      // [#52] fast path: convert directly into the heap slot at its row stride.
      uint16_t* dst = (uint16_t*)(em.heap + h.off);
      if (!mpix::to_rgb565(s, dst, h.stride / 2)) {
        if (diag) g_cvt_fallback++;
        SDL_Surface* c = SDL_ConvertSurfaceFormat(s, SDL_PIXELFORMAT_RGB565, 0);
        if (!c) return false;
        const uint8_t* base = static_cast<const uint8_t*>(c->pixels);
        for (int y = 0; y < c->h; ++y)
          std::memcpy((void*)(em.heap + h.off + (size_t)y * h.stride),
                      base + (size_t)y * c->pitch, (size_t)h.w * 2u);
        SDL_FreeSurface(c);
      }
    }
    return true;
  }

  // Upload (once) a SurfaceImpl's pixels into the heap; cache by ptr. `fmt` picks
  // the heap format: BLT_FMT_RGB565 (opaque/colorkey/const-alpha) or
  // BLT_FMT_ARGB4444 (per-pixel alpha). Surfaces are cached per (ptr,fmt) so a
  // surface drawn both opaquely and alpha-blended gets one upload of each form.
  // A cached surface that was drawn onto since (dirty_src) is refreshed in place.
  // Returns invalid handle on heap overflow (caller escapes the frame).
  blt_surface_ref_t upload(const SurfaceImpl& src, uint8_t fmt) {
    SurfKey kkey{&src, fmt};
    auto it = handles.find(kkey);
    if (it != handles.end()) {
      // Cached. If the surface's pixels changed since the upload, refresh the
      // heap slot in place (after the per-frame handshake) so the blit shows the
      // CURRENT content (animated menu surfaces). dirty_src is cleared for this
      // ptr once refreshed; a still-dirty ARGB variant (other fmt) refreshes on
      // its own next use.
      if (dirty_src.count(&src)) {
        ensure_frame();                 // handshake: fabric done with prev frame
        if (reupload_in_place(src, fmt, it->second)) {
          dirty_src.erase(&src);
          if (diag) {
            g_reuploads++;
            g_reup_px += (long)it->second.w * it->second.h;   // [#52] dynamic reconvert volume
            if ((long)it->second.w * it->second.h >= 256 * 256) g_reup_big++;
          }
          // [collapse-single-source] RE-STAGE dirty (animated) surfaces. The source
          // is now ALWAYS read from SDRAM (the DDR3 live-source path was removed), so
          // the old "demote to DDR3" trick (free the SDRAM offset, let the per-command
          // mux fall back to DDR3) no longer works — there is no DDR3 fallback. After
          // reupload_in_place refreshed the DDR3 heap copy, re-stage it DDR3->SDRAM (to
          // the SAME offset, idempotent) so the SDRAM source the fabric reads is current.
          blt_stage_surface(&em, &it->second);
        } else {
          // Dims changed (rare) — free the old block + drop the cache entry and fall
          // through to a fresh allocation below ([MiSTer #14]: was a leak).
          blt_sdram_free(&em, &it->second);   // [#33] free the SDRAM offset too (no leak)
          blt_emitter_free(&em, it->second.off, it->second.size);
          handles.erase(it);
          goto fresh_upload;
        }
      }
      return it->second;
    }
   fresh_upload:
    if (too_big.count(&src)) return blt_surface_ref_t{};   // known-unfittable

    blt_surface_ref_t r{};
    SDL_Surface* s = src.get_surface();
    if (!s) return r;
    // A surface bigger than the whole heap can NEVER fit: remember + escape
    // without invoking blt_upload (which would set the per-frame overflow flag
    // and poison the small blits already emitted this frame). Both formats are
    // 16bpp so the size test is format-independent.
    if ((size_t)s->w * (size_t)s->h * 2u > em.heap_cap) {
      too_big.insert(&src);
      return r;
    }
    if (diag) {
      g_uploads++;
      g_upload_px += (long)s->w * s->h;          // [#52] cold-convert pixel volume
      if ((long)s->w * s->h >= 256 * 256) g_upload_big++;
    }
    if (fmt == BLT_FMT_ARGB4444) {
      std::vector<uint16_t> px;
      if (!to_argb4444(s, px)) return r;
      r = blt_upload_argb4444(&em, px.data(), s->w, s->h, s->w * 2);
    } else {
      // [#52] fast path: convert into a packed temp, then bump-copy into the heap.
      std::vector<uint16_t> px((size_t)s->w * s->h);
      if (mpix::to_rgb565(s, px.data(), s->w)) {
        r = blt_upload(&em, px.data(), s->w, s->h, s->w * 2);
      } else {
        if (diag) g_cvt_fallback++;
        SDL_Surface* c = SDL_ConvertSurfaceFormat(s, SDL_PIXELFORMAT_RGB565, 0);
        if (!c) return r;
        r = blt_upload(&em, static_cast<const uint16_t*>(c->pixels),
                       c->w, c->h, c->pitch);
        SDL_FreeSurface(c);
      }
    }
    if (r.valid) {
      // [MiSTer #19] Queue a STAGE command so the fabric copies this source surface
      // from DDR3 into SDRAM before the blits that use it.  Ordered here (after the
      // heap write, before the blit that consumes the handle) so the fabric sees
      // STAGE before BLT_OP_BLIT in the same ring.  No-op when staging is disabled.
      // [MiSTer #34] STAGE *before* caching: blt_stage_surface sets r.sdram_off, so the
      // cached handle must be stored AFTER it — else the cache keeps sdram_off=FAIL and
      // every later frame reads the un-staged DDR3 offset (staging would be pointless).
      if (stage_enabled) blt_stage_surface(&em, &r);  // [#33] alloc + stage to a distinct SDRAM offset
      handles[kkey] = r;
    }
    return r;
  }

  // [#52 resident] Derive a bucket's shared params exactly as draw_tile_batch does.
  // Returns false (= this bucket can't be batched -> escape) on a non-batchable blend,
  // a color-mod (tile-list carries no tint) or an un-uploadable tileset.
  bool res_bucket_params(const SurfaceImpl& tsimg, BlendMode blend,
                         blt_surface_ref_t& tex, uint8_t& bl, uint16_t& key,
                         uint8_t& fl, uint8_t& fmt) {
    Rectangle ti_region; Point ti_dst, ti_origin(0, 0); Scale ti_scale(1.f);
    DrawInfos ti(ti_region, ti_dst, ti_origin, blend, /*opacity=*/255,
                 /*rotation=*/0.0, ti_scale, null_proxy);
    uint8_t cr, cg, cb; int why = 0;
    if (!map_blend(tsimg, ti, bl, key, fl, fmt, why, cr, cg, cb)) return false;
    if (fl & BLT_F_COLORMOD) return false;        // tiles are white; never hit
    tex = upload(tsimg, fmt);
    return tex.valid;
  }

  // [#52 resident] Patch the src rect (first 8 bytes: u16 src_x,src_y,w,h) of a
  // resident TL_BUF entry at byte offset `off`, in place (little-endian wire form).
  void res_patch_entry(uint32_t off, uint16_t sx, uint16_t sy, uint16_t w, uint16_t h) {
    volatile uint8_t* p = ddr + OFF_TLBUF + off;
    p[0]=(uint8_t)sx; p[1]=(uint8_t)(sx>>8);
    p[2]=(uint8_t)sy; p[3]=(uint8_t)(sy>>8);
    p[4]=(uint8_t)w;  p[5]=(uint8_t)(w>>8);
    p[6]=(uint8_t)h;  p[7]=(uint8_t)(h>>8);
  }

  // Map Solarus blend/opacity/colorkey -> blitter blend. Returns false (caller
  // escapes) if the op can't be expressed by the blitter. `why` (diag) names
  // the first unsupported feature (1=rotation, 2=scale).
  // `want_fmt` (out): the source heap format the chosen blend needs —
  // BLT_FMT_RGB565 for opaque/colorkey/const-alpha, BLT_FMT_ARGB4444 for the
  // per-pixel-alpha (BLEND_PALPHA) path.
  // `out_cr/cg/cb` (out): RGB888 color-mod triple; BLT_F_COLORMOD is set in
  // `flags` iff the source must be modulated (any channel != 255).
  bool map_blend(const SurfaceImpl& src, const DrawInfos& infos,
                 uint8_t& blend, uint16_t& key, uint8_t& flags, uint8_t& want_fmt,
                 int& why,
                 uint8_t& out_cr, uint8_t& out_cg, uint8_t& out_cb) {
    flags = 0; why = 0; want_fmt = BLT_FMT_RGB565;
    out_cr = out_cg = out_cb = 255;   // identity (no modulation) by default
    if (std::fabs(infos.rotation) > 1e-3) { why = 1; return false; }     // rotation
    if (std::fabs(std::fabs(infos.scale.x) - 1.f) > 1e-3 ||
        std::fabs(std::fabs(infos.scale.y) - 1.f) > 1e-3) { why = 2; return false; } // zoom
    uint8_t cr, cg, cb, ca; infos.color.get_components(cr, cg, cb, ca);
    // Tint (any RGB channel != 255): set BLT_F_COLORMOD, surface the triple to
    // the caller for blt_blit_mod.  No longer an escape path. (was why=3)
    if (cr != 255 || cg != 255 || cb != 255) {
      flags |= BLT_F_COLORMOD;
      out_cr = cr; out_cg = cg; out_cb = cb;
    }
    if (infos.scale.x < 0) flags |= BLT_F_HFLIP;
    if (infos.scale.y < 0) flags |= BLT_F_VFLIP;

    SDL_Surface* ss = src.get_surface();
    uint32_t k; key = 0;
    bool has_key = ss && SDL_GetColorKey(ss, &k) == 0;
    if (has_key) {
      uint8_t r, g, b; SDL_GetRGB(k, ss->format, &r, &g, &b);
      key = to_rgb565(r, g, b);
    }
    // Does the source carry a real per-pixel alpha channel? (Solarus sprite PNGs
    // do: BLEND + full opacity + an alpha channel.)
    bool has_alpha = ss && ss->format && SDL_ISPIXELFORMAT_ALPHA(ss->format->format);

    switch (infos.blend_mode) {
      case BlendMode::NONE:
        blend = has_key ? BLT_BLEND_COLORKEY : BLT_BLEND_COPY; break;
      case BlendMode::BLEND:
        if (infos.opacity < 255) { blend = BLT_BLEND_CONST_ALPHA;
                                   if (has_key) flags |= BLT_F_COLORKEY; }
        else if (has_alpha)      { blend = BLT_BLEND_PALPHA;   // v2 per-pixel alpha
                                   want_fmt = BLT_FMT_ARGB4444; }
        else if (has_key)        { blend = BLT_BLEND_COLORKEY; }
        else                     { blend = BLT_BLEND_COPY; }   // opaque, no alpha
        break;
      case BlendMode::ADD:
        blend = BLT_BLEND_ADD; break;     // v2 additive blend (was escape why=5)
      case BlendMode::MULTIPLY:
        blend = BLT_BLEND_MULTIPLY; break; // v2 multiply blend (was escape why=5)
      default: why = 5; return false;    // unknown/future blend mode
    }
    return true;
  }

  // Express one draw (src -> dst at dst+offset) as a blitter command. Returns
  // true if emitted, false if the op had to ESCAPE (caller has already set
  // frame_escaped via escape() and tallied the reason). `off_x/off_y` shift the
  // destination so an alias surface (the camera) composites at its screen offset
  // in the DDR framebuffer. Shared by the fpga_target and alias_target paths.
  // Colormod (cr,cg,cb) from map_blend is threaded through to blt_blit_mod when
  // BLT_F_COLORMOD is set in flags; otherwise the fast blt_blit path is taken.
  // Clamp a 1:1 blit's destination rect to the framebuffer bounds [0,FB_W)x[0,FB_H),
  // shifting the SOURCE origin (flip-aware) so the visible part is unchanged and the
  // off-screen part is dropped. Solarus relies on DESTINATION-SURFACE CLIPPING — e.g.
  // the title clouds are drawn at x=320 / x-535 / y-299 (deliberately past the edges).
  // The fabric blitter has no clip, so an unclamped off-screen dst writes OUT OF the
  // 320x240 framebuffer in SDRAM (clouds over the bars + adjacent-buffer corruption =
  // flashing). Scale is rejected upstream (map_blend why=2), so the blit is strictly
  // 1:1 and a 1px dst clip == a 1px src clip. Returns false if fully off-screen.
  static bool clip_to_fb(int& sx, int& sy, int& w, int& h, int& dx, int& dy,
                         uint8_t flags) {
    if (dx < 0) {                          // off the LEFT edge
      int c = -dx; if (c >= w) return false;
      if (!(flags & BLT_F_HFLIP)) sx += c; // non-flip advances src; HFLIP trims the far side
      w -= c; dx = 0;
    }
    if (dx + w > FB_W) {                    // off the RIGHT edge
      int c = dx + w - FB_W; if (c >= w) return false;
      if (flags & BLT_F_HFLIP) sx += c;
      w -= c;
    }
    if (dy < 0) {                           // off the TOP edge
      int c = -dy; if (c >= h) return false;
      if (!(flags & BLT_F_VFLIP)) sy += c;
      h -= c; dy = 0;
    }
    if (dy + h > FB_H) {                     // off the BOTTOM edge
      int c = dy + h - FB_H; if (c >= h) return false;
      if (flags & BLT_F_VFLIP) sy += c;
      h -= c;
    }
    return true;
  }

  bool emit_draw(const SurfaceImpl& src, const DrawInfos& infos,
                 int off_x, int off_y) {
    uint8_t blend, flags, want_fmt; uint16_t key; int why = 0;
    uint8_t cm_r, cm_g, cm_b;
    if (!map_blend(src, infos, blend, key, flags, want_fmt, why, cm_r, cm_g, cm_b)) {
      escape();
      if (diag) {
        g_escapes++;
        switch (why) { case 1: g_esc_rot++; break; case 2: g_esc_scale++; break;
          // why=3 (tint) and why=5 (ADD/MULTIPLY) no longer reach here: they are
          // handled by map_blend itself (g_esc_tint/g_esc_mode kept for other paths).
          case 4: g_esc_alpha++; break;
          default: g_esc_mode++; }
      }
      return false;
    }
    blt_surface_ref_t h = upload(src, want_fmt);
    if (!h.valid) {
      escape();
      if (diag) {
        g_escapes++;
        if (too_big.count(&src)) g_esc_toobig++;
        else { g_esc_upload++; if (em.overflow) g_esc_overflow++; }
      }
      return false;
    }
    ensure_frame();
    const Rectangle& r = infos.region;
    Rectangle dr = infos.dst_rectangle();
    // Clip the destination to the framebuffer bounds (the title clouds are drawn
    // off-surface and rely on it). Fully off-screen -> emit nothing, NOT an escape.
    int sx = r.get_x(), sy = r.get_y(), bw = r.get_width(), bh = r.get_height();
    int bdx = dr.get_x() + off_x, bdy = dr.get_y() + off_y;
    if (!clip_to_fb(sx, sy, bw, bh, bdx, bdy, flags)) return true;
    // colormod rides alongside the clip (post-clip): blt_blit_mod when the flag is
    // set, plain blt_blit otherwise (hot path stays unchanged).
    if (flags & BLT_F_COLORMOD) {
      blt_blit_mod(&em, h, sx, sy, bw, bh, bdx, bdy, blend, key,
                   infos.opacity, flags, cm_r, cm_g, cm_b);
    } else {
      blt_blit(&em, h, sx, sy, bw, bh, bdx, bdy, blend, key, infos.opacity, flags);
    }
    if (diag || bgcache_enabled)
      ps_add((const void*)&src, r.get_x(), r.get_y(), r.get_width(), r.get_height(),
             dr.get_x() + off_x, dr.get_y() + off_y, src.get_width(), src.get_height());
    return true;
  }

  // Like emit_draw but blits only the part of the 1:1 source landing inside the fb
  // rect [cx0,cx1) x [cy0,cy1). Used by the SCROLL cache to composite ONLY the thin
  // newly-revealed margin strip of a large tile cell (the rest is in the shifted
  // snapshot) — without this a 512px cell fully recomposites and there is no win.
  // Returns true if a non-empty clipped blit was emitted.
  bool emit_draw_clipped(const SurfaceImpl& src, const DrawInfos& infos,
                         int off_x, int off_y, int cx0, int cy0, int cx1, int cy1) {
    uint8_t blend, flags, want_fmt; uint16_t key; int why = 0;
    uint8_t cm_r, cm_g, cm_b;
    if (!map_blend(src, infos, blend, key, flags, want_fmt, why, cm_r, cm_g, cm_b))
      return false;
    blt_surface_ref_t h = upload(src, want_fmt);
    if (!h.valid) return false;
    const Rectangle& r = infos.region;
    Rectangle dr = infos.dst_rectangle();
    const int dx0 = dr.get_x() + off_x, dy0 = dr.get_y() + off_y;
    const int dx1 = dx0 + dr.get_width(), dy1 = dy0 + dr.get_height();
    int nx0 = dx0 > cx0 ? dx0 : cx0, ny0 = dy0 > cy0 ? dy0 : cy0;
    int nx1 = dx1 < cx1 ? dx1 : cx1, ny1 = dy1 < cy1 ? dy1 : cy1;
    if (nx0 >= nx1 || ny0 >= ny1) return false;     // no overlap with this strip
    ensure_frame();
    if (flags & BLT_F_COLORMOD) {
      blt_blit_mod(&em, h, r.get_x() + (nx0 - dx0), r.get_y() + (ny0 - dy0),
                   nx1 - nx0, ny1 - ny0, nx0, ny0, blend, key, infos.opacity, flags,
                   cm_r, cm_g, cm_b);
    } else {
      blt_blit(&em, h, r.get_x() + (nx0 - dx0), r.get_y() + (ny0 - dy0),
               nx1 - nx0, ny1 - ny0, nx0, ny0, blend, key, infos.opacity, flags);
    }
    return true;
  }

  // Detect the camera->root promote-blit: a full-quest-size, texture-backed
  // source drawn 1:1 (no rotation/scale/flip, fully opaque, plain copy) onto the
  // fpga_target. Its source is the camera surface, which we then alias. We DON'T
  // require src dims == FB exactly (a quest could use a slightly larger camera)
  // — full-cover at the dst rect is the real signal — but for the 320x240 quests
  // we care about it is exactly FB-sized. Conservative to avoid false positives.
  bool looks_like_promote(const SurfaceImpl& src, const DrawInfos& infos) {
    const SDLSurfaceImpl* s = dynamic_cast<const SDLSurfaceImpl*>(&src);
    if (!s) return false;
    // Under the SOFTWARE renderer (force-software-rendering) the CAMERA surface
    // (Map::draw's composite target) is NOT texture-backed, so the original
    // texture-only gate never matched it -> the gameplay composite never offloaded
    // (alias_blits=0, all draws software/offtarget). SOLARUS_ALIAS_SW relaxes the
    // gate to accept software surfaces so the (stable, first-wins) camera surface
    // gets aliased and the per-tile/entity draws composite on the fabric.
    if (!alias_allow_sw && !s->get_texture()) return false;  // must be a render texture
    if (src.get_width() != FB_W || src.get_height() != FB_H) return false;
    if (std::fabs(infos.rotation) > 1e-3) return false;
    if (std::fabs(infos.scale.x - 1.f) > 1e-3 ||
        std::fabs(infos.scale.y - 1.f) > 1e-3) return false;   // also rejects flips
    if (infos.opacity != 255) return false;
    // covers the whole source region (the full camera frame), not a sub-rect.
    if (infos.region.get_width() != FB_W || infos.region.get_height() != FB_H)
      return false;
    return true;
  }
};

// =====================================================================
MisterBlitterRenderer::MisterBlitterRenderer(SDL_Renderer* renderer, bool shaders)
    : SDLRenderer(renderer, shaders), d(new Impl()) {}

MisterBlitterRenderer::~MisterBlitterRenderer() {
  if (d->ddr) ::munmap((void*)d->ddr, BLT_DDR_SIZE);
  if (d->mem_fd >= 0) ::close(d->mem_fd);
  if (d->vid) ::munmap((void*)d->vid, 0x00100000u);
  if (d->vid_fd >= 0) ::close(d->vid_fd);
}

MisterBlitterRenderer* MisterBlitterRenderer::try_create(SDL_Renderer* renderer,
                                                         bool shaders) {
  if (std::getenv("SOLARUS_BLITTER") == nullptr) return nullptr;

  auto* self = new MisterBlitterRenderer(renderer, shaders);
  self->d->diag = (std::getenv("SOLARUS_BLITTER_DIAG") != nullptr);
  g_mister_lua_diag = self->d->diag ? 1 : 0;   // [#26] enable Lua-VM timing in LuaTools
  self->d->verify = (std::getenv("SOLARUS_BLITTER_VERIFY") != nullptr);
  self->d->alias_allow_sw = (std::getenv("SOLARUS_ALIAS_SW") != nullptr);
  self->d->camera_tag = (std::getenv("SOLARUS_NO_CAMERA_TAG") == nullptr);
  self->d->vsync_pace = (std::getenv("SOLARUS_NO_VSYNC") == nullptr);
  self->d->vsync_fastpace = (std::getenv("SOLARUS_FASTPACE") != nullptr);  // [lever-b]
  // [single pipeline] Background-composite cache REMOVED — it diverged the double
  // buffer's blended layers (the ~3-5s overworld flip). bgcache_enabled is hardwired
  // off; the carry-forward path is the sole compositing pipeline. (SOLARUS_BGCACHE /
  // SOLARUS_SCROLLCACHE are no longer read.) The remaining bg_* scaffolding is inert.
  self->d->bgcache_enabled = false;
  self->d->scroll_cache = false;
  // [collapse-single-source] Source staging is UNCONDITIONAL — there is a single
  // source pipeline now (the DDR3 live-source path was removed in the fabric). The
  // engine always stages atlases DDR3->SDRAM and always writes C_SRCSEL=1; the old
  // SOLARUS_SDRAM_SRC opt-in is gone. stage_enabled is hardwired true (see decl).
  if (const char* th = std::getenv("SOLARUS_BLT_THROTTLE")) {              // [MiSTer #34]
    int v = std::atoi(th); if (v < 0) v = 0; if (v > 255) v = 255;
    self->d->throttle_val = (uint32_t)v;                                  // f2h write-throttle (HW-tunable)
  }
  // NOTE: blt_sdram_init MUST run AFTER map_ddr() below — map_ddr() calls
  // blt_emitter_init() which memset()s the whole emitter to 0, wiping the SDRAM
  // allocator. Initializing it here (pre-map) left sdram_alloc empty (n=0), so every
  // blt_alloc() returned FAIL -> blt_stage_surface set em.overflow -> EVERY frame
  // escaped to software (the #34 SDRAM-path black screen). Moved below map_ddr().
  if (self->d->bgcache_enabled)
    std::fprintf(stderr, "[MiSTer blitter] background-composite cache ENABLED\n");
  self->d->single_buf = (std::getenv("SOLARUS_BLITTER_SINGLEBUF") != nullptr);
  // [#52 resident] Tier A resident animated-tile list (default OFF == #52 behavior).
  // SOLARUS_TILERESIDENT_HW (Tier B) implies the Tier A plumbing too.
  self->d->res_hw      = (std::getenv("SOLARUS_TILERESIDENT_HW") != nullptr);
  self->d->res_enabled = (std::getenv("SOLARUS_TILERESIDENT") != nullptr) ||
                         self->d->res_hw;
  if (self->d->res_enabled)
    std::fprintf(stderr, "[MiSTer blitter] resident tile-list ENABLED (Tier %s)\n",
                 self->d->res_hw ? "B fabric (TILELIST_RES)" : "A engine");
  if (const char* tn = std::getenv("SOLARUS_BLITTER_TRACE_N"))
    self->d->diag_frame_log_max = std::atoi(tn);   // extend per-frame trace window
  self->d->sdl = self->renderer;       // base SDL renderer (befriended access)
  // Map the VIDEO framebuffer region unconditionally: the persistence model
  // (flashing fix) carries the previous committed buffer forward into the next
  // target buffer (DDR-to-DDR memcpy) on frames Solarus does NOT clear, so an
  // incrementally-drawn frame stays complete while keeping the tear-free double
  // buffer. (Also used by the optional verify path.)
  if (!self->d->map_video()) {
    std::fprintf(stderr, "[MiSTer blitter] video-region map failed; "
                         "carry-forward + verify disabled\n");
    self->d->verify = false;
  }
  if (!self->d->map_ddr()) {
    std::fprintf(stderr, "[MiSTer blitter] /dev/mem map failed; reverting to SDL\n");
    // The base ctor already set the SDLRenderer singleton to `self`; we cannot
    // simply delete and re-create (the caller does that). Returning nullptr here
    // and deleting would leave a dangling singleton, so we instead keep `self`
    // but with ddr==null, which makes is_fpga_target() always false -> every
    // frame escapes to the base present path (functionally a plain SDLRenderer).
    std::fprintf(stderr, "[MiSTer blitter] running as pass-through SDLRenderer\n");
    return self;
  }
  // [MiSTer #33/#34] decoupled SDRAM-VRAM: source reads come from per-surface SDRAM
  // offsets (independent of the 16MB DDR3 heap). Atlas allocator based above the fixed
  // bg-cache SDRAM region so they never collide. MUST be here, AFTER map_ddr()'s
  // blt_emitter_init() (which memset()s the emitter) — else sdram_alloc is wiped.
  // [collapse-single-source] Source staging is UNCONDITIONAL — there is one source
  // pipeline now: every atlas is staged DDR3->SDRAM and read at C_SRCSEL=1 (ch5).
  blt_sdram_init(&self->d->em, SDRAM_ATLAS_BASE, SDRAM_CAP - SDRAM_ATLAS_BASE);
  std::fprintf(stderr, "[MiSTer blitter] SDRAM-VRAM source staging (always on): "
                       "C_SRCSEL=1, atlas base 0x%X cap 0x%X\n",
               SDRAM_ATLAS_BASE, SDRAM_CAP);
  std::fprintf(stderr, "[MiSTer blitter] renderer active (DDR @ 0x%08x)\n",
               BLT_DDR_PHYS);
  return self;
}

std::string MisterBlitterRenderer::get_name() const { return "mister_blitter"; }

void MisterBlitterRenderer::invalidate(const SurfaceImpl& surf) {
  // [MiSTer #14] FREE the surface's heap block(s) before dropping the cache entries,
  // so the DDR bytes are reclaimed for reuse. The old bump heap only erased the map
  // entry and LEAKED the bytes -> old-scene atlases piled up -> transition overflow.
  for (uint8_t fmt : { (uint8_t)BLT_FMT_RGB565, (uint8_t)BLT_FMT_ARGB4444 }) {
    auto it = d->handles.find(Impl::SurfKey{&surf, fmt});
    if (it != d->handles.end()) {
      if (it->second.valid) { blt_sdram_free(&d->em, &it->second); blt_emitter_free(&d->em, it->second.off, it->second.size); }  // [#33] free SDRAM offset too
      d->handles.erase(it);
    }
  }
  d->too_big.erase(&surf);
  d->scene_too_big = false;   // a surface was freed -> scene changing -> re-allow
                              // a churn reset (the working set may now fit again)
  if (&surf == d->fpga_target) d->fpga_target = nullptr;
  if (&surf == d->alias_target) d->alias_target = nullptr;  // camera surface freed
  if (&surf == g_tagged_camera) g_tagged_camera = nullptr;  // drop the stale tag
  SDLRenderer::invalidate(surf);
}

// ---- intercepted ops -------------------------------------------------------
// THE FABRIC IS THE SOLE RENDERER. An op that targets a blitter-BACKED surface
// (the root fpga_target or the aliased camera surface, whose content lives in the
// DDR framebuffer) is translated into ONE blitter command and emitted — there is
// NO parallel base-SDL software composite for these ops anymore (the old
// double-render gate + readback fallback were removed once fabric coverage was
// proven full: escape==0 across intro/title/menus/overworld). Ops on SDL-backed
// surfaces (sprite/tile atlases, off-screen HUD/menu intermediates) STILL run on
// base SDL — they hold real pixel content the blitter later reads as an uploaded
// source.
void MisterBlitterRenderer::clear(SurfaceImpl& dst) {
  d->mark_render();   // A9-breakdown: first render op marks end of lua/update phase
  // A clear() on EITHER the root quest surface (fpga_target) OR the aliased
  // camera/menu surface (whose pixels live in the SAME DDR framebuffer) means
  // Solarus wants a FRESH frame: hardware-clear the DDR buffer (vs. the persist
  // default in ensure_frame) so carried-forward content doesn't smear under the
  // new repaint. Handling the alias case too is essential for the overworld: the
  // map clears its camera surface every frame (not fpga_target), so without this
  // the camera buffer would persist+smear the moving scene.
  bool backed = !d->blitter_off() &&
                (d->is_fpga_target(dst) ||
                 (d->alias_target == &dst && dst.get_width() == FB_W && !g_transition_scroll));
  if (backed) {
    d->frame_active = false;           // a clear starts a fresh blitter frame
    d->clear_requested = true;
    d->ensure_frame();                 // begin frame WITH hardware clear
    SDLRenderer::clear(dst);           // keep the software quest surface coherent
    return;                            // blitter-backed
  }
  SDLRenderer::clear(dst);             // SDL-backed surface (or blitter off)
  d->mark_src_dirty(&dst);             // pixels changed -> stale any cached upload
}

void MisterBlitterRenderer::fill(SurfaceImpl& dst, const Color& color,
                                 const Rectangle& where, BlendMode mode) {
  d->mark_render();   // A9-breakdown: first render op marks end of lua/update phase
  if (d->diag) { d->p0_fills++; int bm = (int)mode; if (bm >= 0 && bm < 4) d->p0_blend[bm]++; }
  // Fills target the root (offset 0) OR the aliased camera surface (offset to
  // its screen position) — both composite into the same DDR framebuffer.
  bool root  = !d->blitter_off() && d->is_fpga_target(dst);
  bool alias = !d->blitter_off() && !root && d->alias_target == &dst &&
               dst.get_width() == FB_W && !g_transition_scroll;
  if (root || alias) {
    if (mode == BlendMode::ADD || mode == BlendMode::MULTIPLY) {
      // v2: emit a FILL with the matching blend_mode instead of escaping.
      d->ensure_frame();
      int ox = alias ? d->alias_off_x : 0, oy = alias ? d->alias_off_y : 0;
      uint8_t r, g, b, a; color.get_components(r, g, b, a);
      blt_fill_blend(&d->em, where.get_x() + ox, where.get_y() + oy,
                     where.get_width(), where.get_height(),
                     to_rgb565(r, g, b),
                     mode == BlendMode::ADD ? (uint8_t)BLT_BLEND_ADD
                                           : (uint8_t)BLT_BLEND_MULTIPLY);
      if (d->diag) d->g_fills++;
      return;
    }
    // [const-alpha fill] A translucent BLEND fill — the colored fade overlay
    // (TransitionFade, the default): Surface::fill_with_color(black, a<255) over
    // the root each frame. The opaque blt_fill below drops alpha, so the whole
    // fade composited as SOLID colour (black) for its entire duration = the
    // "extra black frames". Emit a CONST_ALPHA FILL so the fabric blends it onto
    // the current frame (gated to the fabric by tb_blitter_cafill_pipe). Placed
    // BEFORE the bg-cache full-screen skip: the overlay must land on top of the
    // (cached or live) frame, never be skipped. Opaque (a==255) BLEND fills — the
    // per-frame tileset background fill — keep the fast opaque path below.
    if (mode == BlendMode::BLEND) {
      uint8_t r, g, b, a; color.get_components(r, g, b, a);
      if (a < 255) {
        d->ensure_frame();
        int ox = alias ? d->alias_off_x : 0, oy = alias ? d->alias_off_y : 0;
        blt_fill_alpha(&d->em, where.get_x() + ox, where.get_y() + oy,
                       where.get_width(), where.get_height(),
                       to_rgb565(r, g, b), a);
        if (d->diag) d->g_fills++;
        return;
      }
    }
    d->ensure_frame();
    // BG-CACHE FIX (2026-06-14): when the cache is ACTIVE, ensure_frame() already
    // blitted the cached background as the frame base. A full-screen fill here (the
    // engine's per-frame fill_with_color(tileset bg)) would PAINT OVER that cached bg
    // -> then the cacheable floor/tile cells are skipped (not repainted) -> the static
    // background VANISHES, leaving only the fill color + live entities. (Masked in the
    // overworld because the fill≈grass-green; obvious indoors where the fill is white.)
    // So skip a full-screen root fill while ACTIVE — the cached bg is the base.
    const bool bg_active = d->bgcache_enabled && d->bg_state == Impl::BG_ACTIVE &&
                           d->bg_handle.w != 0;
    const bool fullscreen = where.get_width() >= FB_W && where.get_height() >= FB_H;
    if (root && bg_active && fullscreen) {
      if (d->diag) d->bg_skips++;
      return;                          // cached bg is the base; don't overpaint it
    }
    int ox = alias ? d->alias_off_x : 0, oy = alias ? d->alias_off_y : 0;
    uint8_t r, g, b, a; color.get_components(r, g, b, a);
    blt_fill(&d->em, where.get_x() + ox, where.get_y() + oy,
             where.get_width(), where.get_height(), to_rgb565(r, g, b));
    if (d->diag) d->g_fills++;
    return;                            // blitter-backed (no base SDL composite)
  }
  SDLRenderer::fill(dst, color, where, mode);   // SDL-backed surface (or off)
  d->mark_src_dirty(&dst);             // pixels changed -> stale any cached upload
}

void MisterBlitterRenderer::draw(SurfaceImpl& dst, const SurfaceImpl& src,
                                 const DrawInfos& infos) {
  d->mark_render();   // A9-breakdown: first render op marks end of lua/update phase
  if (d->diag) d->p0_record(dst, src, infos);   // P0 op-profile (issue #13): every draw
  // Deterministic camera alias (issue #15): adopt the surface Game::draw tagged as
  // the map camera. This locks alias_target onto the real composite target instead
  // of the looks_like_promote lottery -> the gameplay composite runs on-fabric every
  // frame. Re-adopts if the tag changes (map change recreates the camera surface).
  if (d->camera_tag && g_tagged_camera && !g_transition_scroll && d->alias_target != g_tagged_camera) {
    d->alias_target = g_tagged_camera;
    d->alias_off_x = 0; d->alias_off_y = 0;   // full-screen camera composites at (0,0)
    if (d->diag)
      std::fprintf(stderr, "[blitter alias] camera TAGGED=%p (deterministic)\n",
                   (const void*)g_tagged_camera);
  }
  if (d->blitter_off()) {               // pass-through SDLRenderer (or scene too big)
    SDLRenderer::draw(dst, src, infos);
    if (d->diag) {
      d->g_offtarget_draw++;
      // [#52] record the REAL blitted-region size dist in the blitter-off (scene_too_big)
      // path too — otherwise the offsrc size log is empty exactly when we're black, hiding
      // what the draw storm actually is (full-surface vs small sub-region blits).
      Rectangle dr = infos.dst_rectangle();
      d->rec_offtarget_src(dr.get_width(), dr.get_height());
      d->rec_offtarget_dst(&dst, dst.get_width(), dst.get_height());
    }
    return;
  }

  // (1) Draw onto the locked root target (fpga_target).
  if (d->is_fpga_target(dst)) {
    // Is this the camera->root promote-blit? If so, register the camera surface
    // (src) as an alias of the DDR framebuffer and SKIP its blit: the camera's
    // content is already composited in DDR by the aliased per-sprite draws (from
    // the next frame on). On the FIRST frame the alias isn't known yet, so we let
    // the promote-blit through as one full-frame blit — the frame is still
    // correct, just not yet decomposed onto the fabric.
    if (&src == d->alias_target && d->alias_drawn_this_frame && !g_transition_scroll) {
      // The aliased surface WAS repainted this frame (the game camera): its content
      // is already composited in DDR by the case-2 draws, so skip the promote.
      return;
    }
    // (If &src == alias_target but it got ZERO draws this frame — a static menu
    // surface drawn once then re-blitted — we must NOT skip: the buffer was
    // hardware-cleared so the content is not in DDR. Fall through and emit the
    // promote as a normal full-frame blit of the surface's CURRENT, dirty-refreshed
    // pixels so the frame is correct instead of black: the menu/overworld freeze.)
    // Lock the alias onto the FIRST full-frame promote source we see (first wins,
    // like fpga_target). We deliberately do NOT chase a changing promote source:
    // this quest cycles its camera/intermediate through a DIFFERENT surface pointer
    // most frames (double/triple buffering + transient surfaces), so re-locking
    // thrashed (a fresh 150 KiB upload every frame -> heap overflow -> whole-frame
    // escape). Correctness does NOT depend on aliasing the "right" surface: when
    // the promote source is NOT the aliased one (or the aliased one got no draws
    // this frame), we fall through below and emit the promote as a normal full-
    // frame blit of its CURRENT (dirty-refreshed) pixels — always the complete
    // frame. Aliasing is purely a perf decomposition for the steady case where the
    // SAME surface is repainted then promoted every frame.
    if (!d->alias_target && !g_transition_scroll && d->looks_like_promote(src, infos)) {
      d->alias_target = &src;
      Rectangle dr = infos.dst_rectangle();
      d->alias_off_x = dr.get_x();
      d->alias_off_y = dr.get_y();
      if (d->diag)
        std::fprintf(stderr,
          "[blitter alias] camera surface=%p aliased -> DDR fb at offset (%d,%d)\n",
          (const void*)&src, d->alias_off_x, d->alias_off_y);
    }
    bool emitted = d->emit_draw(src, infos, 0, 0);
    if (emitted && d->diag) d->g_blits++;
    if (d->diag && d->diag_frame_log < d->diag_frame_log_max) {
      Rectangle rb = infos.dst_rectangle();
      std::fprintf(stderr, "[blt rootblit f%d] src=%p dst=(%d,%d %dx%d) emit=%d\n",
        d->diag_frame_log, (const void*)&src, rb.get_x(), rb.get_y(),
        rb.get_width(), rb.get_height(), emitted);
    }
    // No SDL fallback: the fabric is the sole renderer. If the op could not be
    // expressed (!emitted) it is simply absent this frame (a logged coverage gap),
    // NOT a reason to run a parallel software composite.
    return;
  }

  // (2) Draw onto the aliased camera surface -> composite into the same DDR
  //     framebuffer at the camera's screen offset. This is where the bulk of the
  //     per-frame sprite/tile draws (formerly offtarget=454) now land on-fabric.
  if (dst.get_width() == FB_W && d->alias_target == &dst && !g_transition_scroll) {
    d->alias_drawn_this_frame = true;   // the aliased surface is live this frame
    // BACKGROUND CACHE routing. Classify this src; track the static-set hash (for
    // bg-change/scroll detection); skip the static layers in ACTIVE (the bg copy
    // covers them) and the dynamic layers in SNAPSHOT (render static-only to snapshot).
    bool skip = false;
    if (d->bgcache_enabled) {
      Rectangle dr2 = infos.dst_rectangle();
      const int dw = dr2.get_width(), dh = dr2.get_height();
      // CACHEABLE = a LARGE static source = a map tile-layer cell (>=128px). Small
      // sources (the hero + entity sprites, animated 16x16 tiles, HUD) are NEVER
      // cached/skipped -> they composite dynamically EVERY frame. Without the size
      // gate a STATIONARY hero param-classifies as "static" and gets skipped in
      // ACTIVE -> the hero vanishes (HW bug 2026-06-14). The drawn region (dst rect)
      // is small for sprites even when drawn from a large sheet, so it discriminates.
      // CACHEABLE = LARGE drawn region only. The map's NON-animated tile cells are the
      // large draws (>=128px) BY CONSTRUCTION; animated tiles + sprites + hero + HUD
      // are all small. Dropping the param-stability test (ps_is_static) is the FIX for
      // the building-flicker (2026-06-14): that classifier WARMS UP/CHURNS over time
      // (nstatic 7->13 after the snapshot), so cells promoted to "static" AFTER the
      // snapshot got skipped in ACTIVE but were never baked into the (stale) snapshot
      // -> they vanished. Size is fixed per cell -> the cacheable set is stable and
      // complete from frame 1 -> snapshot and skip sets always agree.
      const bool cacheable = (dw >= 128 || dh >= 128);
      if (cacheable) {
        unsigned long long k =
          ((unsigned long long)(infos.region.get_x() & 0xffff)) |
          ((unsigned long long)(infos.region.get_y() & 0xffff) << 16) |
          ((unsigned long long)(infos.region.get_width() & 0xffff) << 32) |
          ((unsigned long long)(infos.region.get_height() & 0xffff) << 48);
        // map coords ONLY for the scroll cache (scroll-invariant); SCREEN coords for
        // the default cache so scrolling changes the hash -> drop to LEARN (full
        // composite) while moving instead of freezing an unshifted bg.
        const int hcx = d->scroll_cache ? g_cam_x : 0, hcy = d->scroll_cache ? g_cam_y : 0;
        k ^= ((unsigned long long)((dr2.get_x() + d->alias_off_x + hcx) & 0xffff) * 2654435761ull) ^
             ((unsigned long long)((dr2.get_y() + d->alias_off_y + hcy) & 0xffff) * 40503ull) ^
             ((unsigned long long)(uintptr_t)&src);
        d->bg_hash = d->bg_hash * 1000003ull ^ k;
      }
      if (d->bg_state == Impl::BG_ACTIVE && cacheable) {
        if (d->scroll_cache) {
          // SCROLL: the cell is covered by the SHIFTED snapshot except in the thin
          // newly-revealed margin strip(s). Composite ONLY those strips (clipped) so
          // a 512px cell contributes just its ~|shift|px edge, not the whole cell.
          const int ox = d->alias_off_x, oy = d->alias_off_y;
          bool any = false;
          if (d->cur_dx > 0) any |= d->emit_draw_clipped(src, infos, ox, oy, FB_W - d->cur_dx, 0, FB_W, FB_H);
          if (d->cur_dx < 0) any |= d->emit_draw_clipped(src, infos, ox, oy, 0, 0, -d->cur_dx, FB_H);
          if (d->cur_dy > 0) any |= d->emit_draw_clipped(src, infos, ox, oy, 0, FB_H - d->cur_dy, FB_W, FB_H);
          if (d->cur_dy < 0) any |= d->emit_draw_clipped(src, infos, ox, oy, 0, 0, FB_W, -d->cur_dy);
          if (d->diag) { if (any) d->g_alias_blits++; else d->bg_skips++; }
          return;   // handled (clipped strips, or fully covered -> nothing emitted)
        }
        skip = true;   // plain bg-cache: fully covered by the (unshifted) snapshot
      }
      if (d->bg_state == Impl::BG_SNAPSHOT && !cacheable) skip = true;
    }
    if (skip) { if (d->diag) d->bg_skips++; return; }
    bool emitted = d->emit_draw(src, infos, d->alias_off_x, d->alias_off_y);
    if (emitted && d->diag) d->g_alias_blits++;
    // No SDL fallback (fabric is the sole renderer); an unexpressible op is logged
    // and simply absent this frame rather than triggering a software composite.
    return;
  }

  // (3) SDL-backed surface (sprite/tile intermediate, HUD off-screen, menu
  //     surface, etc.): render normally on the A9 — its pixels may be uploaded as
  //     a blitter source or read back later. Drawing onto it CHANGES its pixels,
  //     so any heap copy we cached of it is now stale: mark it for in-place
  //     refresh before its next blit (the animated-menu-surface flashing fix).
  if (d->diag && d->diag_frame_log < d->diag_frame_log_max) {
    Rectangle rb = infos.dst_rectangle();
    const SDLSurfaceImpl* sd = dynamic_cast<const SDLSurfaceImpl*>(&dst);
    std::fprintf(stderr,
      "[blt OFFTGT f%d] dst=%p(%dx%d tex=%d) src=%p dr=(%d,%d %dx%d) blend=%d op=%d\n",
      d->diag_frame_log, (const void*)&dst, dst.get_width(), dst.get_height(),
      (sd && sd->get_texture()) ? 1 : 0, (const void*)&src,
      rb.get_x(), rb.get_y(), rb.get_width(), rb.get_height(),
      (int)infos.blend_mode, (int)infos.opacity);
  }
  SDLRenderer::draw(dst, src, infos);
  d->mark_src_dirty(&dst);
  if (d->diag) { d->g_offtarget_draw++;
    d->rec_offtarget_dst(&dst, dst.get_width(), dst.get_height());
    if (dst.get_width() == FB_W) {
      Rectangle dr = infos.dst_rectangle();   // ACTUAL blitted area (not src surface size)
      d->rec_offtarget_src(dr.get_width(), dr.get_height()); } }
}

// [#52] Batched animated-tile draw. The engine (Entities::draw) gathers all of a
// frame's animated tiles that share one tileset image + blend into a single batch
// and calls this; we emit ONE BLT_OP_TILELIST instead of N individual draw()s,
// collapsing the per-tile host emit + ring traffic. The fabric composite is BYTE-
// IDENTICAL to N per-tile BLITs (Task 2/4 reference + TB proved it): same shared
// blend/format/key/flags (derived via the SAME map_blend the per-tile alias path
// uses), same per-entry src-rect + dst (shifted by the camera alias offset), and
// the fabric does the offscreen cull + partial per-pixel clip exactly as N BLITs.
//
// We batch ONLY when dst IS the aliased camera surface and the fabric is live —
// the same condition as draw()'s case-(2) alias path. Anything else (fabric off,
// scene_too_big, in a map transition, an escape-class blend) falls back to the base
// per-entry draw() loop, which is always correct (just unbatched).
void MisterBlitterRenderer::draw_tile_batch(SurfaceImpl& dst,
        const SurfaceImpl& tileset_image, BlendMode blend,
        const std::vector<TileBatchEntry>& entries) {
  d->mark_render();   // A9-breakdown: first render op marks end of lua/update phase
  // Adopt the deterministic camera alias exactly as draw() does (issue #15), so the
  // batch sees the same alias_target draw() would have locked this frame.
  if (d->camera_tag && g_tagged_camera && !g_transition_scroll &&
      d->alias_target != g_tagged_camera) {
    d->alias_target = g_tagged_camera;
    d->alias_off_x = 0; d->alias_off_y = 0;   // full-screen camera composites at (0,0)
  }
  // Only batch onto the live aliased camera surface; else safe per-entry fallback.
  if (d->blitter_off() || entries.empty() || d->alias_target != &dst ||
      g_transition_scroll) {
    Renderer::draw_tile_batch(dst, tileset_image, blend, entries);
    return;
  }
  // Derive the SHARED blend/format/key/flags via the SAME map_blend the per-tile
  // alias path uses, by synthesizing the DrawInfos a tile draw would carry:
  // rotation=0, scale=1, opacity=255, color=white (the 8-arg ctor defaults white).
  // NOTE: DrawInfos holds region/dst_position/scale/color as const REFERENCES, so
  // these locals MUST outlive `ti` (binding to temporaries would dangle).
  Rectangle ti_region; Point ti_dst, ti_origin(0, 0); Scale ti_scale(1.f);
  DrawInfos ti(ti_region, ti_dst, ti_origin, blend, /*opacity=*/255,
               /*rotation=*/0.0, ti_scale, null_proxy);
  uint8_t bl, fl, want_fmt, cr, cg, cb; uint16_t key; int why = 0;
  if (!d->map_blend(tileset_image, ti, bl, key, fl, want_fmt, why, cr, cg, cb)) {
    Renderer::draw_tile_batch(dst, tileset_image, blend, entries);   // escape (rare for tiles)
    return;
  }
  // The tile-list ABI carries no per-batch color-mod triple, so a tinted batch
  // can't be expressed here — fall back (tiles are white, so this is never hit).
  if (fl & BLT_F_COLORMOD) {
    Renderer::draw_tile_batch(dst, tileset_image, blend, entries);
    return;
  }
  blt_surface_ref_t tex = d->upload(tileset_image, want_fmt);
  if (!tex.valid) {
    Renderer::draw_tile_batch(dst, tileset_image, blend, entries);
    return;
  }
  d->ensure_frame();
  std::vector<blt_tile_entry_t> es; es.reserve(entries.size());
  for (const auto& e : entries) {
    const int bdx = e.dst.x + d->alias_off_x, bdy = e.dst.y + d->alias_off_y;
    // NO host clip: the fabric culls fully-offscreen entries and per-pixel clips
    // partial ones (Task 4 TB), matching N individual alias-offset BLITs exactly.
    es.push_back({ (uint16_t)e.src.get_x(),     (uint16_t)e.src.get_y(),
                   (uint16_t)e.src.get_width(), (uint16_t)e.src.get_height(),
                   (int16_t)bdx,                (int16_t)bdy });
  }
  blt_tile_list(&d->em, tex, bl, key, /*alpha=*/255, fl, es.data(), (int)es.size());
  d->alias_drawn_this_frame = true;   // the aliased surface is live this frame
  if (d->diag) d->g_alias_blits += (long)es.size();
}

// ── [#52 resident] Tier A resident animated-tile list (SOLARUS_TILERESIDENT) ──
// Returns the per-frame mode: 0 = legacy (engine uses draw_tile_batch), 1 = build
// (engine walks + resident_record_batch/resident_escape), 2 = fast (engine skips the
// walk; patch ticked patterns + resident_emit_layer). Memoized per frame (res_epoch).
int MisterBlitterRenderer::resident_begin_frame(uintptr_t map_id, uintptr_t tileset_id) {
  // Adopt the camera alias every frame (idempotent), mirroring draw_tile_batch, so the
  // animated-tile batch composites onto the same aliased camera surface.
  if (d->camera_tag && g_tagged_camera && !g_transition_scroll &&
      d->alias_target != g_tagged_camera) {
    d->alias_target = g_tagged_camera;
    d->alias_off_x = 0; d->alias_off_y = 0;
  }
  if (d->res_decided_epoch == d->res_epoch) return d->res_mode;   // memoized this frame
  d->res_decided_epoch = d->res_epoch;
  if (!d->res_enabled || d->blitter_off() || g_transition_scroll) {
    d->res_building = false; d->res_mode = 0; return 0;
  }
  const bool sig = d->res_valid && d->res_map == map_id && d->res_tileset == tileset_id;
  if (sig) {
    d->res_building = false;
    d->res_mode = d->res_eligible ? 2 : 0;        // fast, or legacy for an escape scene
    if (d->diag && d->res_mode == 2) d->res_noops++;
    return d->res_mode;
  }
  // New / changed signature: rebuild the resident list THIS frame.
  d->res_map = map_id; d->res_tileset = tileset_id;
  d->res_buckets.clear(); d->res_ops.clear();
  d->res_patterns.clear(); d->res_pat_index.clear();
  d->res_building = true; d->res_build_escape = false; d->res_valid = false;
  d->res_hw_overflow = false; d->res_hw_armed = false; d->res_frt_uploaded = false;
  if (d->diag) d->res_rebuilds++;
  d->res_mode = 1;
  return 1;
}

bool MisterBlitterRenderer::resident_take_patch_turn() {
  if (d->res_patch_epoch == d->res_epoch) return false;
  d->res_patch_epoch = d->res_epoch;
  if (d->diag) d->res_patch_passes++;
  return true;
}

size_t MisterBlitterRenderer::resident_pattern_count() const {
  return d->res_patterns.size();
}

uintptr_t MisterBlitterRenderer::resident_pattern_token(size_t k) const {
  return k < d->res_patterns.size() ? d->res_patterns[k].token : 0;
}

void MisterBlitterRenderer::resident_update(uintptr_t token, const Rectangle& cur_src,
        int current_frame, int frame_count, const Rectangle* frames) {
  auto it = d->res_pat_index.find(token);
  if (it == d->res_pat_index.end()) return;
  const size_t slot = it->second;
  Impl::ResPattern& rp = d->res_patterns[slot];
  // [#52 camera-independent] Tier B (fabric FRT/CFT) is the sole resident src path now: the
  // fabric resolves each entry's src from FRT[pid][CFT[pid]]; the A9 only writes the
  // per-pattern current frame. Capture the frame rects (for FRT, written at arm) + the
  // current frame, and write CFT[slot] to DDR each frame. (The Tier A in-place src-patch
  // branch is removed — 8-byte biased map-coord entries have no patchable src field.)
  if (!d->res_hw_armed) {
    rp.frame_count = (frame_count < 1) ? 1 : (frame_count > BLT_MAXF ? BLT_MAXF : frame_count);
    for (int f = 0; f < rp.frame_count; ++f) rp.frames[f] = frames ? frames[f] : cur_src;
  }
  rp.cur_frame = (uint16_t)((current_frame < 0) ? 0
                            : (current_frame >= BLT_MAXF ? BLT_MAXF - 1 : current_frame));
  volatile uint8_t* p = d->ddr + OFF_CFTBUF + slot * 2u;
  p[0] = (uint8_t)rp.cur_frame; p[1] = (uint8_t)(rp.cur_frame >> 8);
  if (d->diag && rp.cur_frame != 0) d->res_patched_entries++;
}

// [#52 camera-independent] `scroll_ratio` (1 = normal, r = parallax) selects the per-bucket
// camera bias applied on emit; `entries[i].dst` is now in MAP coords (whole map, camera
// independent). Buckets are split by {tsimg, blend, scroll_ratio} on the engine side.
void MisterBlitterRenderer::resident_record_batch(int layer, int scroll_ratio,
        const SurfaceImpl& tileset_image,
        BlendMode blend, const std::vector<TileBatchEntry>& entries,
        const std::vector<uintptr_t>& tokens) {
  d->mark_render();
  if (!d->res_building || entries.empty()) return;
  blt_surface_ref_t tex; uint8_t bl, fl, fmt; uint16_t key;
  if (!d->res_bucket_params(tileset_image, blend, tex, bl, key, fl, fmt)) {
    // Can't batch this bucket: draw per-entry now (correct) + disqualify the scene
    // from the fast path so future frames fall back to the legacy batched walk. The
    // stored dsts are MAP coords, so apply this bucket's camera bias to reach screen coords
    // (mirrors the fabric bias in res_emit_bucket_: normal -> -camera, parallax -> cam/r-cam).
    const int fcx = mister_camera_x(), fcy = mister_camera_y();
    const int fbx = (scroll_ratio <= 1) ? -fcx : (fcx / scroll_ratio - fcx);
    const int fby = (scroll_ratio <= 1) ? -fcy : (fcy / scroll_ratio - fcy);
    d->res_build_escape = true;
    d->ensure_frame();
    for (const auto& e : entries) {
      Rectangle reg = e.src; Point dp(e.dst.x + fbx, e.dst.y + fby), org(0, 0); Scale sc(1.f);
      DrawInfos di(reg, dp, org, blend, /*opacity=*/255, /*rotation=*/0.0, sc, null_proxy);
      d->emit_draw(tileset_image, di, d->alias_off_x, d->alias_off_y);
    }
    return;
  }
  d->ensure_frame();
  const uint32_t eoff = (uint32_t)d->em.tl_used;   // where blt_tile_list writes the entries
  std::vector<blt_tile_entry_t> es; es.reserve(entries.size());
  for (const auto& e : entries) {
    // [#52 camera-independent] store the MAP-coord dst verbatim (no alias_off / camera);
    // the per-frame per-bucket bias in res_emit_bucket_ shifts map -> screen.
    es.push_back({ (uint16_t)e.src.get_x(),     (uint16_t)e.src.get_y(),
                   (uint16_t)e.src.get_width(), (uint16_t)e.src.get_height(),
                   (int16_t)e.dst.x,            (int16_t)e.dst.y });
  }
  if (blt_tile_list(&d->em, tex, bl, key, /*alpha=*/255, fl, es.data(), (int)es.size()) != 0) {
    d->res_build_escape = true;                  // tl_buf/ring overflow -> bail to legacy
    return;
  }
  Impl::ResBucket bk{ &tileset_image, bl, fl, fmt, key, eoff, (int)es.size(), layer,
                      scroll_ratio, /*hw_off=*/0, /*hw_count=*/0, {} };
  for (size_t i = 0; i < entries.size(); ++i) {
    const uintptr_t tok = (i < tokens.size()) ? tokens[i] : 0;
    if (!tok) continue;                          // unbatchable / no pattern identity
    auto it = d->res_pat_index.find(tok);
    size_t pi;
    if (it == d->res_pat_index.end()) {
      pi = d->res_patterns.size();
      if (pi >= (size_t)BLT_MAXP) {               // [Tier B] too many patterns -> use Tier A
        d->res_hw_overflow = true;
        // still need a slot for Tier A patching, but cap it (no Tier B FRT slot).
      }
      d->res_pat_index[tok] = pi;
      Impl::ResPattern rp; rp.token = tok; rp.src = entries[i].src;
      d->res_patterns.push_back(std::move(rp));
    } else pi = it->second;
    d->res_patterns[pi].offs.push_back(
        eoff + (uint32_t)i * (uint32_t)sizeof(blt_tile_entry_t));
    // [Tier B] record the (pattern_id, MAP-coord dst) for this entry's 8-byte resident form.
    // The fabric adds this bucket's camera bias per frame (res_emit_bucket_), so the stored
    // dst stays camera-independent — a camera move never rebuilds the list.
    const auto& e = entries[i];
    bk.hw.push_back({ (uint16_t)pi, (int16_t)e.dst.x, (int16_t)e.dst.y });
  }
  d->res_buckets.push_back(std::move(bk));
  d->res_ops.push_back({false, (uint32_t)(d->res_buckets.size() - 1), 0, layer});
  d->alias_drawn_this_frame = true;
  if (d->diag) d->g_alias_blits += (long)es.size();
}

// [#52 resident] A tile that can't batch (repeated/fill: tile size > pattern size, or a
// parallax pattern). Record it as an ordered escape op so the fast path re-issues its
// tile.draw() in paint order. Does NOT disqualify the scene (only a non-batchable bucket
// blend or a tl_buf overflow latches res_build_escape -> legacy).
void MisterBlitterRenderer::resident_escape(int layer, uintptr_t tile) {
  if (!d->res_building || !tile) return;
  d->res_ops.push_back({true, 0, tile, layer});
}

// [#52 Tier B] Arm the fabric resident path once per scene (first fast frame): write the
// frame-rect table (FRT) + the 8-byte resident entries to DDR. CFT is written per frame in
// resident_update. frt_bram/8-byte entries persist across fast frames (TL_BUF untouched).
void MisterBlitterRenderer::res_hw_arm_() {
  // FRT: FRT[slot*MAXF + f] = {src_x, src_y, w, h} (LE), one qword each.
  for (size_t s = 0; s < d->res_patterns.size() && s < (size_t)BLT_MAXP; ++s) {
    const Impl::ResPattern& rp = d->res_patterns[s];
    for (int f = 0; f < rp.frame_count && f < BLT_MAXF; ++f) {
      volatile uint8_t* p = d->ddr + OFF_FRTBUF + (s * BLT_MAXF + f) * 8u;
      const uint16_t sx=(uint16_t)rp.frames[f].get_x(), sy=(uint16_t)rp.frames[f].get_y(),
                     w=(uint16_t)rp.frames[f].get_width(), h=(uint16_t)rp.frames[f].get_height();
      p[0]=(uint8_t)sx; p[1]=(uint8_t)(sx>>8); p[2]=(uint8_t)sy; p[3]=(uint8_t)(sy>>8);
      p[4]=(uint8_t)w;  p[5]=(uint8_t)(w>>8);  p[6]=(uint8_t)h;  p[7]=(uint8_t)(h>>8);
    }
  }
  // 8-byte resident entries, contiguous in TL_BUF; record per-bucket hw_off/hw_count.
  uint32_t cur = 0;
  for (auto& b : d->res_buckets) {
    b.hw_off = cur; b.hw_count = (int)b.hw.size();
    for (const auto& e : b.hw) {
      volatile uint8_t* p = d->ddr + OFF_TLBUF + cur;
      p[0]=(uint8_t)e.pid; p[1]=(uint8_t)(e.pid>>8);
      p[2]=(uint8_t)e.dx;  p[3]=(uint8_t)((uint16_t)e.dx>>8);
      p[4]=(uint8_t)e.dy;  p[5]=(uint8_t)((uint16_t)e.dy>>8);
      p[6]=0; p[7]=0;
      cur += 8;
    }
  }
  d->res_hw_armed = true;
}

// Emit ONE recorded bucket via Tier B (8-byte TILELIST_RES with FRT/CFT fabric resolution).
// The stored entry dsts are MAP coords; this applies the bucket's per-frame camera bias so
// the fabric shifts them to screen coords (blitter_top: c_dst = res_dx + res_bias). Per-scene
// arm/FRT_UPLOAD happen lazily on the first bucket emitted (guarded + idempotent).
// ensure_frame/mark_render are idempotent.
void MisterBlitterRenderer::res_emit_bucket_(size_t idx) {
  if (idx >= d->res_buckets.size()) return;
  d->mark_render();
  d->ensure_frame();
  const Impl::ResBucket& b = d->res_buckets[idx];
  if (d->res_hw_active()) {
    if (!d->res_hw_armed) res_hw_arm_();
    // FRT_UPLOAD once per scene, BEFORE the first TILELIST_RES header (frt_bram persists).
    if (!d->res_frt_uploaded) {
      blt_frt_upload(&d->em, (uint32_t)BLT_MAXP * BLT_MAXF);
      d->res_frt_uploaded = true;
    }
    if (b.hw_count == 0) return;
    blt_surface_ref_t tex = d->upload(*b.tsimg, b.fmt);
    if (!tex.valid) return;
    // [#52 camera-independent] per-bucket signed dst bias from the LIVE camera + scroll ratio.
    //   normal (ratio<=1): screen = map - camera            -> bias = -camera
    //   parallax (ratio>1): screen = map - camera + cam/r    -> bias = cam/r - camera
    // (upstream parallax draws at dst_position + viewport/ratio, dst_position = map - camera;
    //  storing map coords + this bias reproduces it exactly, camera-independently.)
    const int cx = mister_camera_x(), cy = mister_camera_y();
    int16_t bx, by;
    if (b.scroll_ratio <= 1) { bx = (int16_t)(-cx); by = (int16_t)(-cy); }
    else { bx = (int16_t)(cx / b.scroll_ratio - cx); by = (int16_t)(cy / b.scroll_ratio - cy); }
    blt_tile_list_res(&d->em, tex, b.blend, b.key, /*alpha=*/255, b.flags,
                      b.hw_off, b.hw_count, bx, by);
    d->alias_drawn_this_frame = true;
    if (d->diag) d->g_alias_blits += b.hw_count;
    return;
  }
  // (Tier A 12-byte blt_tile_list_at emit removed — Tier B is the sole resident emit now.
  //  The remaining Tier A build-time scaffolding/data is cleaned up in Task 7.)
}

// Bucket-only emit of a whole layer (kept for completeness; the engine fast path now
// drives the interleaved op list below so escapes replay in paint order).
void MisterBlitterRenderer::resident_emit_layer(int layer) {
  for (size_t i = 0; i < d->res_ops.size(); ++i)
    if (d->res_ops[i].layer == layer && !d->res_ops[i].esc)
      res_emit_bucket_(d->res_ops[i].bk);
}

// ── Engine-driven interleaved replay (fast path) ─────────────────────────────
// The engine iterates a layer's ops in paint order: for a bucket op it calls
// resident_emit_layer_op (renderer emits the TILELIST); for an escape op
// resident_layer_op_tile returns the Tile* so the engine re-issues tile.draw().
int MisterBlitterRenderer::resident_layer_op_count(int layer) const {
  int n = 0;
  for (const auto& o : d->res_ops) if (o.layer == layer) ++n;
  return n;
}

uintptr_t MisterBlitterRenderer::resident_layer_op_tile(int layer, int i) const {
  int k = 0;
  for (const auto& o : d->res_ops)
    if (o.layer == layer) {
      if (k == i) {
        if (o.esc && d->diag) ++d->res_escapes;   // tally escapes replayed /fast frame
        return o.esc ? o.tile : 0;
      }
      ++k;
    }
  return 0;
}

void MisterBlitterRenderer::resident_emit_layer_op(int layer, int i) {
  int k = 0;
  for (const auto& o : d->res_ops)
    if (o.layer == layer) { if (k == i) { if (!o.esc) res_emit_bucket_(o.bk); return; } ++k; }
}

// Remaining TL_BUF room in 12-byte tile entries (tl_used is cumulative across the frame's
// buckets). Lets the engine expand repeated tiles into cells up to capacity (else escape).
int MisterBlitterRenderer::resident_room_entries() const {
  size_t cap = d->em.tl_cap, used = d->em.tl_used;
  if (used >= cap) return 0;
  return (int)((cap - used) / sizeof(blt_tile_entry_t));
}

void MisterBlitterRenderer::present(SDL_Window* window) {
  bool committed = (d->frame_active && !d->frame_escaped && !d->em.overflow);

  // [#52 resident] Finalize a resident build done during this frame, then advance the
  // per-frame epoch (memoization reset). A build is fast-usable next frame only if it
  // had no escapes (non-batchable bucket / overflow).
  if (d->res_building) {
    d->res_valid = true;
    d->res_eligible = !d->res_build_escape;
    d->res_building = false;
  }
  d->res_epoch++;

  // frame-period (present-to-present) + jitter for the timing diag
  if (d->diag) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    if (d->t_prev_present.tv_sec || d->t_prev_present.tv_nsec) {
      long long p = Impl::ns_diff(now, d->t_prev_present);
      d->t_period_ns += p;
      if (d->t_period_min == 0 || p < d->t_period_min) d->t_period_min = p;
      if (p > d->t_period_max) d->t_period_max = p;
    }
    // A9-breakdown: draw+emit phase = first render op -> this present entry
    if (d->frame_drawn) d->t_draw_ns += Impl::ns_diff(now, d->t_first_draw);
    d->t_prev_present = now;
  }

  // PER-FRAME TRACE (first 60 frames): reveals whether the engine emits a
  // different command list on alternating frames (the suspected flashing cause).
  if (d->diag && d->diag_frame_log < d->diag_frame_log_max) {
    std::fprintf(stderr,
      "[blt f%02d] cmds=%d committed=%d active=%d esc=%d ovf=%d tbuf=%d alias=%d\n",
      d->diag_frame_log++, d->em.cmd_count, committed, d->frame_active,
      d->frame_escaped, d->em.overflow, d->em.target_buf,
      d->alias_target ? 1 : 0);
  }

  // Heap-churn handling. An overflow means stale (old-scene) atlases are crowding
  // out the new scene -> reclaim the heap next frame so it re-uploads fresh (see
  // ensure_frame). BUT if we already reset at the start of THIS frame and it STILL
  // overflowed, the scene's working set genuinely exceeds the heap; resetting again
  // can't help and would thrash (full re-upload every frame), so suppress further
  // resets until the scene changes (invalidate() clears scene_too_big). A frame
  // that fits clears it too.
  if (d->em.overflow) {
    if (d->did_reset_last)        d->scene_too_big = true;   // reset didn't help
    else if (!d->scene_too_big)   d->heap_reset_pending = true;
  } else if (d->frame_active) {
    // A frame that actually USED the blitter fit -> churn recovery can resume.
    // (scene_too_big is otherwise cleared on a scene change by invalidate(). With
    // the 4 MiB command region a real working set never approaches the heap cap,
    // so this guard is effectively dormant — but kept as a safety valve.)
    d->scene_too_big = false;
  }
  d->did_reset_last = false;

  // fold this frame's per-layer param hashes (classification — needed by the bg cache
  // independently of diag).
  if (d->diag || d->bgcache_enabled) d->ps_frame_end();

  if (d->diag) {
    if (committed) d->g_frames_emit++; else d->g_frames_escape++;
    if (++d->diag_n >= 60) {
      std::fprintf(stderr,
        "[blitter diag] /60fr: emit=%ld escape=%ld | fills=%ld blits=%ld "
        "alias_blits=%ld uploads=%ld reup=%ld offtarget=%ld | hwclear=%ld carryfwd=%ld | "
        "esc: rot=%ld scale=%ld "
        "tint=%ld alpha=%ld mode=%ld upload=%ld ovf=%ld toobig=%ld | cmdcnt=%d "
        "heap=%zu/%zu overflow=%d target_locked=%d alias_locked=%d\n",
        d->g_frames_emit, d->g_frames_escape, d->g_fills, d->g_blits,
        d->g_alias_blits, d->g_uploads, d->g_reuploads, d->g_offtarget_draw,
        d->g_hwclear, d->g_carryfwd,
        d->g_esc_rot, d->g_esc_scale, d->g_esc_tint, d->g_esc_alpha,
        d->g_esc_mode, d->g_esc_upload, d->g_esc_overflow, d->g_esc_toobig,
        d->em.cmd_count, d->em.heap_used, d->em.heap_cap, d->em.overflow,
        d->fpga_target ? 1 : 0, d->alias_target ? 1 : 0);
      // [#52] convert-cost split: how much per-window conversion is COLD (cache-miss
      // upload, removable by a permanent/pre-loaded static atlas pool) vs DYNAMIC
      // (dirty-surface reupload, NOT removable — runtime-generated pixels). MB =
      // converted bytes (px*2) /60fr; big = surfaces >= 256x256 in each bucket.
      std::fprintf(stderr,
        "[blitter cvt] /60fr: cold_upload=%ld px (%.2f MB, big=%ld) | "
        "dyn_reup=%ld px (%.2f MB, big=%ld) | sdl_fallback=%ld\n",
        d->g_upload_px, d->g_upload_px * 2.0 / (1024 * 1024), d->g_upload_big,
        d->g_reup_px, d->g_reup_px * 2.0 / (1024 * 1024), d->g_reup_big,
        d->g_cvt_fallback);
      std::fprintf(stderr, "[blitter offtgt] alias_target=%p :", (const void*)d->alias_target);
      for (int i = 0; i < d->off_dst_n; i++)
        std::fprintf(stderr, " %p(%dx%d)x%ld", d->off_dst[i], d->off_dst_w[i],
                     d->off_dst_h[i], d->off_dst_cnt[i]);
      std::fprintf(stderr, "\n");
      d->off_dst_n = 0;
      if (d->res_enabled)
        std::fprintf(stderr,
          "[blitter resident] /60fr: rebuild=%ld fast_noop=%ld patch_pass=%ld "
          "patched_entries=%ld escapes=%ld | buckets=%zu patterns=%zu eligible=%d valid=%d\n",
          d->res_rebuilds, d->res_noops, d->res_patch_passes, d->res_patched_entries,
          d->res_escapes, d->res_buckets.size(), d->res_patterns.size(),
          d->res_eligible ? 1 : 0, d->res_valid ? 1 : 0);
      d->res_rebuilds = d->res_noops = d->res_patch_passes = d->res_patched_entries = 0;
      d->res_escapes = 0;
      std::fprintf(stderr,
        "[blitter p0] /60fr: draws=%ld fills=%ld | blend NONE=%ld BLEND=%ld ADD=%ld MUL=%ld | "
        "op full=%ld part=%ld | xform rot=%ld scale=%ld colormod=%ld | distinct_tex=%d\n",
        d->p0_draws, d->p0_fills, d->p0_blend[0], d->p0_blend[1], d->p0_blend[2], d->p0_blend[3],
        d->p0_op_full, d->p0_op_part, d->p0_rot, d->p0_scale, d->p0_colormod, d->p0_tex_n);
      d->p0_draws = d->p0_fills = 0;
      for (int i = 0; i < 4; i++) d->p0_blend[i] = 0;
      d->p0_op_full = d->p0_op_part = 0;
      d->p0_rot = d->p0_scale = d->p0_colormod = 0;
      d->p0_tex_n = 0;
      std::fprintf(stderr, "[blitter offsrc] camera-composite DRAWN sizes:");
      for (int i = 0; i < d->osrc_n; i++)
        std::fprintf(stderr, " %dx%d:%ld", d->osrc_w[i], d->osrc_h[i], d->osrc_cnt[i]);
      std::fprintf(stderr, "\n");
      d->osrc_n = 0;
      if (d->bgcache_enabled) {
        int nstatic = 0;
        for (int i = 0; i < d->ps_used; i++)
          if (d->ps_is_static(d->ps_ptr[i])) nstatic++;
        std::fprintf(stderr,
          "[blitter bgcache] state=%d(0=L,1=S,2=A) copies=%ld skips=%ld snaps=%ld "
          "stable_run=%d nstatic=%d/%d bg_hash=%llx cache_hash=%llx | cam=(%d,%d) "
          "snap=(%d,%d) shift=(%d,%d)\n",
          d->bg_state, d->bg_copies, d->bg_skips, d->bg_snaps, d->bg_stable_run,
          nstatic, d->ps_used, (unsigned long long)d->bg_last_hash,
          (unsigned long long)d->bg_cache_hash,
          g_cam_x, g_cam_y, d->snap_cam_x, d->snap_cam_y,
          g_cam_x - d->snap_cam_x, g_cam_y - d->snap_cam_y);
        d->bg_copies = d->bg_skips = d->bg_snaps = 0;
      }
      {
        const double N = 60.0;
        double per_ms = d->t_period_ns / N / 1e6;
        double fab_ms = d->t_fab_ns    / N / 1e6;
        double slp_ms = d->t_sleep_ns  / N / 1e6;
        double a9_ms  = (d->t_period_ns - d->t_fab_ns - d->t_sleep_ns) / N / 1e6;
        double fps    = per_ms > 0 ? 1000.0 / per_ms : 0;
        // pipeline ceiling: if the command ring were double-buffered, frame time
        // would be max(A9,fabric) instead of their sum -> this fps.
        double pipe_ms = (a9_ms > fab_ms ? a9_ms : fab_ms) + slp_ms;
        double pipe_fps = pipe_ms > 0 ? 1000.0 / pipe_ms : 0;
        std::fprintf(stderr,
          "[blitter timing] /60fr: fps=%.1f period=%.1fms | fabric=%.1fms A9=%.1fms "
          "sleep=%.1fms | jitter=%.1fms spin_iters=%.0f | pipeline_ceiling=%.1ffps "
          "| fastpace=%s skips=%ld/60\n",
          fps, per_ms, fab_ms, a9_ms, slp_ms,
          (d->t_period_max - d->t_period_min) / 1e6, d->t_fab_iters / N, pipe_fps,
          d->vsync_fastpace ? "on" : "off", d->g_fastpace_skips);
        // A9 breakdown (issue #26): is the A9 cost Lua game logic or blit emission?
        // present = A9 - lua - emit (submit/doorbell/input-poll/bgcache state machine).
        double lua_ms    = d->t_lua_ns / N / 1e6;
        double emit_ms   = (d->t_draw_ns - d->t_fab_ns - d->t_sleep_ns) / N / 1e6;
        double presov_ms = a9_ms - lua_ms - emit_ms;
        std::fprintf(stderr,
          "[blitter a9split] /60fr: A9=%.1fms = lua=%.1fms + emit=%.1fms + present=%.1fms\n",
          a9_ms, lua_ms, emit_ms, presov_ms);
        // [#26] split the update() "lua" phase into Lua-VM time vs pure C++ engine
        // work (entity/collision/movement). lua_vm = wall time inside the outermost
        // Lua call (LuaTools::call_function); eng_cpp = the rest of the update tick.
        long long vm_now = g_mister_lua_vm_ns;
        double luavm_ms  = (vm_now - d->t_lua_vm_prev) / N / 1e6;
        d->t_lua_vm_prev = vm_now;
        double engcpp_ms = lua_ms - luavm_ms;
        std::fprintf(stderr,
          "[blitter luasplit] /60fr: update=%.1fms = lua_vm=%.1fms + eng_cpp=%.1fms\n",
          lua_ms, luavm_ms, engcpp_ms);
        // [#52 lever-1] draw-category split: are the ~thousands of per-frame draws
        // ANIMATED TILES (drawn individually) or ENTITIES (sprites)? Engine-classified
        // in Entities::draw; the remainder vs [blitter p0] draws= is static cells/HUD/Lua.
        {
          long long da = g_me_draw_anim_tiles, de = g_me_draw_entities;
          double anim_pf = (da - d->t_da_anim_prev) / N;
          double ent_pf  = (de - d->t_da_ent_prev)  / N;
          d->t_da_anim_prev = da; d->t_da_ent_prev = de;
          std::fprintf(stderr,
            "[blitter drawcat] /60fr: anim_tiles=%.0f/fr + entities=%.0f/fr (engine-classified)\n",
            anim_pf, ent_pf);
        }
        // [#52 lever-3] eng_cpp split: where does the engine UPDATE tick go?
        // [eng_cpp "other" attribution] also pull out System::update/Sound (audio
        // mix+pump+music decode) and report the catch-up STEP multiplier. Each tick
        // (step()) runs all of entities/hero/nonanim/tileset/sound, and the slow
        // system runs step() ~steps/fr times per DISPLAYED frame to hold game-time
        // at 60Hz -> every bucket below is ~steps/fr-amplified. per_step normalises
        // eng_cpp to a single tick so the genuine per-tick engine cost is visible.
        {
          long long uh = g_me_upd_hero_ns, ue = g_me_upd_entities_ns;
          long long un = g_me_upd_nonanim_ns, ut = g_me_upd_tileset_ns;
          long long us = g_me_upd_sound_ns,  st = g_me_steps;
          double hero_ms = (uh - d->t_uh_prev) / N / 1e6;
          double ent_ms  = (ue - d->t_ue_prev) / N / 1e6;
          double nan_ms  = (un - d->t_un_prev) / N / 1e6;
          double ts_ms   = (ut - d->t_ut_prev) / N / 1e6;
          double snd_ms  = (us - d->t_usnd_prev) / N / 1e6;
          double steps_pf = (st - d->t_steps_prev) / N;
          d->t_uh_prev = uh; d->t_ue_prev = ue; d->t_un_prev = un; d->t_ut_prev = ut;
          d->t_usnd_prev = us; d->t_steps_prev = st;
          double other_ms = engcpp_ms - hero_ms - ent_ms - nan_ms - ts_ms - snd_ms;
          double per_step = steps_pf > 0 ? engcpp_ms / steps_pf : engcpp_ms;
          std::fprintf(stderr,
            "[blitter engcpp] /60fr: eng_cpp=%.1fms = entities=%.1f + hero=%.1f + "
            "nonanim=%.1f + tileset=%.1f + sound=%.1f + other=%.1f | steps/fr=%.2f "
            "per_step=%.1fms\n",
            engcpp_ms, ent_ms, hero_ms, nan_ms, ts_ms, snd_ms, other_ms,
            steps_pf, per_step);
        }
        // [HW perf] fabric-internal busy time straight from the fabric's clk_sys
        // counters (clk_sys ~= 98.4375 MHz). fabric_hw = on-fabric busy ms/frame;
        // comp = the comp_pipeline (compositor) subset; comp% = how much of the
        // fabric's work is the pixel pipeline. This is the precise on-silicon
        // attribution (vs the host-polled fabric=%.1fms above, which adds poll slop).
        const double FABRIC_HZ = 98.4375e6;
        double fab_hw_ms  = d->t_hw_fab_cyc  / N / FABRIC_HZ * 1e3;
        double pipe_hw_ms = d->t_hw_pipe_cyc / N / FABRIC_HZ * 1e3;
        double comp_pct   = d->t_hw_fab_cyc ? 100.0 * d->t_hw_pipe_cyc / d->t_hw_fab_cyc : 0.0;
        std::fprintf(stderr,
          "[blitter hwperf] /60fr: fabric_hw=%.2fms comp=%.2fms comp%%=%.0f%% "
          "(%.0f cyc/frame) | A9-or-fabric-bound: %s\n",
          fab_hw_ms, pipe_hw_ms, comp_pct, d->t_hw_fab_cyc / N,
          fab_hw_ms > a9_ms ? "FABRIC" : "A9");
      }
      // per-layer param stability: stable% = frames where this layer's composite
      // (src-region + dst) is IDENTICAL to the previous frame. High = cacheable
      // static background; low = scrolling/animated (hero/sprites).
      for (int i = 0; i < d->ps_used; i++) {
        long tot = d->ps_stable[i] + d->ps_vary[i];
        std::fprintf(stderr,
          "[blitter paramstab] src=%p %dx%d  stable=%.0f%% (%ld/%ld)\n",
          d->ps_ptr[i], d->ps_w[i], d->ps_h[i],
          tot ? 100.0 * d->ps_stable[i] / tot : 0.0, d->ps_stable[i], tot);
        d->ps_stable[i] = d->ps_vary[i] = 0;   // reset counts (keep ptr/lasthash)
      }
      d->t_period_ns = d->t_fab_ns = d->t_sleep_ns = 0;
      d->t_hw_fab_cyc = d->t_hw_pipe_cyc = 0;   // [HW perf] window reset
      d->t_lua_ns = d->t_draw_ns = 0;   // A9-breakdown window reset
      d->t_fab_iters = 0; d->t_period_min = d->t_period_max = 0;
      d->g_frames_emit = d->g_frames_escape = 0;
      d->g_fills = d->g_blits = d->g_alias_blits = 0;
      d->g_escapes = d->g_offtarget_draw = 0;
      d->g_uploads = d->g_reuploads = 0;
      d->g_upload_px = d->g_reup_px = d->g_upload_big = d->g_reup_big = 0;
      d->g_cvt_fallback = 0;   // [#52]
      d->g_hwclear = d->g_carryfwd = 0;
      d->g_fastpace_skips = 0;   // [lever-b]
      d->g_esc_rot = d->g_esc_scale = d->g_esc_tint = d->g_esc_alpha = 0;
      d->g_esc_mode = d->g_esc_upload = d->g_esc_overflow = d->g_esc_toobig = 0;
      d->diag_n = 0;
    }
  }

  // The MiSTer controller is normally polled inside mister_present_frame() (the
  // base present we no longer call), so poll it here every frame.
  mister_poll_input();

  // FABRIC IS THE SOLE RENDERER (no SDL readback fallback anymore). When the
  // engine drew to the quest surface this frame (frame_active), we submit it to
  // the fabric — every backed op composited on-fabric; nothing escapes to a
  // software path. On a heap overflow (which the 4 MiB region makes effectively
  // impossible) we still submit what we have rather than dropping to a software
  // composite: the persistence + carry-forward keep the buffer's prior complete
  // frame so a partial frame never blanks the screen. If the engine drew NOTHING
  // to the quest surface this frame (frame_active==false — rare), there is no new
  // command list: skip the submit and let the fabric keep showing the last buffer.
  if (d->frame_active) {
    int submitted_buf = d->em.target_buf;
    blt_end_frame(&d->em);
    d->ddr_w32(C_CMDCOUNT, (uint32_t)d->em.cmd_count);
    d->ddr_w32(C_TARGET,   (uint32_t)d->em.target_buf);
    d->ddr_w32(C_CLEAR,    d->em.clear_color);
    d->ddr_w32(C_FLAGS,    d->em.flags);
    // [collapse-single-source] C_SRCSEL bit0 is now a no-op in the fabric (source is
    // always SDRAM), but we still write 1 for protocol/back-compat clarity. bits[15:8]
    // = f2h WRITE THROTTLE (idle cycles the blitter inserts after each f2h write so the
    // scanout keeps its bandwidth). HW-tunable via SOLARUS_BLT_THROTTLE without a rebuild.
    d->ddr_w32(C_SRCSEL,   1u | ((d->throttle_val & 0xFFu) << 8));
    __sync_synchronize();                 // commit ring+ctrl before the doorbell
    d->ddr_w32(C_SUBMIT,   d->em.submit_seq);
    // [lever-b] Snapshot the scanout vsync counter at the submit doorbell so the
    // next frame's FASTPACE barrier can tell how many scan frames have elapsed since
    // this frame's vctrl was committed (>= 2 ticks => already latched + swapped).
    if (d->vid) d->submit_vsync = *(volatile uint32_t*)(d->vid + VSYNC_OFF);
    // Don't flip the display buffer for the off-screen CACHE_BUILD pass (target==2):
    // it composes into the cache, not a framebuffer, so the next ACTIVE frame still
    // uses the same fb buffer alternation.
    if (!d->single_buf && submitted_buf != 2) d->target_buf ^= 1;
    if (d->diag && submitted_buf == 2)
      std::fprintf(stderr, "[CACHE_BUILD] submit cmds=%d alias_blits=%ld heap=%zu\n",
                   d->em.cmd_count, d->g_alias_blits, d->em.heap_used);
    d->verify_committed(window, submitted_buf);

    // ===== BACKGROUND-CACHE state machine (post-submit) =====
    if (d->bgcache_enabled) {
      // [MiSTer #23/#24] Suspend caching during a menu/pause/dialog (#23) or a map
      // transition (#24): force LEARN so the frame is composited live and NEVER
      // snapshotted as the bg (which would persist / show stale). Map relearns on resume.
      if (g_paused || g_in_transition) { d->bg_state = Impl::BG_LEARN; d->bg_stable_run = 0; }
      const bool bg_changed = (d->bg_hash != d->bg_last_hash);
      bool has_static = false;
      for (int i = 0; i < d->ps_used; i++)
        if (d->ps_is_static(d->ps_ptr[i])) { has_static = true; break; }
      switch (d->bg_state) {
        case Impl::BG_LEARN:
          if (!bg_changed && d->bg_hash != 0) d->bg_stable_run++; else d->bg_stable_run = 0;
          // Snapshot only after SUSTAINED stillness (was 8). The SNAPSHOT frame renders
          // static-ONLY (no entities) and the fabric always displays the buffer it
          // composites -> that frame shows a 1-frame entity DROPOUT (hero/NPCs/bush
          // sprites vanish). At threshold 8, brief stabilizations DURING movement
          // triggered frequent snapshots -> visible flicker while walking. Requiring
          // ~0.5s of stillness keeps movement in LEARN (full composite, no dropout);
          // a snapshot (one brief blink) happens only once you settle. (A fully
          // dropout-free cache needs an RBF 'capture without flipping the display'.)
          // Snapshot only after sustained stillness so movement stays in LEARN (full
          // composite). The CACHE_BUILD pass is now INVISIBLE (off-screen, no flip), so
          // it no longer causes an entity dropout — but keeping the threshold avoids
          // rebuilding the cache on every micro-pause.
          if (!g_paused && d->bg_stable_run >= 30 && has_static) d->bg_state = Impl::BG_SNAPSHOT;
          break;
        case Impl::BG_SNAPSHOT: {
          // CACHE_BUILD just composed the static layers into the OFF-SCREEN cache region
          // (C_TARGET=2, no display flip — the previous frame stayed on screen). The
          // fabric wrote the cache directly; no fb->cache memcpy needed. Point bg_handle
          // at the fixed cache region and go ACTIVE. (ensure_frame's handshake already
          // waited for the cache compose to finish before the next frame.)
          d->bg_handle.off = BGCACHE_HEAP_OFF; d->bg_handle.stride = FB_W * 2;
          d->bg_handle.w = FB_W; d->bg_handle.h = FB_H; d->bg_handle.format = BLT_FMT_RGB565;
          d->bg_handle.valid = 1;   // hand-built ref: blt_blit rejects !valid (sets overflow)
          // [MiSTer #34] The cache is staged #19-style (blt_stage, dest==DDR3 off) to
          // SDRAM at BGCACHE_HEAP_OFF, so its SDRAM source offset == its DDR3 offset.
          // Set sdram_off explicitly: blt_blit then tags the cache->fb blit F_SRC_SDRAM
          // and reads SDRAM[BGCACHE_HEAP_OFF]. (A zero-init handle left sdram_off=0,
          // which the per-command mux would have read from SDRAM[0] — the wrong cell.)
          d->bg_handle.sdram_off = BGCACHE_HEAP_OFF;   // single source pipeline: always SDRAM
          d->bg_cache_hash = d->bg_hash; d->bg_state = Impl::BG_ACTIVE; d->bg_snaps++;
          d->snap_cam_x = g_cam_x; d->snap_cam_y = g_cam_y;
          // [MiSTer #19] The fabric just composited a fresh cache into DDR3. Restart the
          // chunked STAGE sweep from offset 0 so the cache is copied DDR3->SDRAM a small
          // slice per ACTIVE frame before being read (the source is always SDRAM now, so
          // the cache MUST be staged). A re-snapshot mid-sweep simply resets the cursor
          // and re-sweeps from the start over the changed cache.
          d->bg_stage_off = 0;
          break;
        }
        case Impl::BG_ACTIVE:
          if (d->scroll_cache) {
            // SCROLL mode: stay ACTIVE while the camera shift is small (the shifted
            // snapshot + live edge cells cover it). When the shift outgrows the
            // snapshot, re-SNAPSHOT at the new position (straight to SNAPSHOT, not
            // LEARN, so continuous walking keeps re-capturing instead of stalling in
            // the full-composite LEARN state). Map/scene change -> invalidate() drops
            // the alias+handle -> bg_handle.w==0 -> bg_active false -> normal path.
            int dx = g_cam_x - d->snap_cam_x, dy = g_cam_y - d->snap_cam_y;
            if (dx < 0) dx = -dx; if (dy < 0) dy = -dy;
            if (dx > Impl::MAXSHIFT || dy > Impl::MAXSHIFT) d->bg_state = Impl::BG_SNAPSHOT;
          } else if (d->bg_hash != d->bg_cache_hash) {   // scene change / scroll -> relearn
            d->bg_state = Impl::BG_LEARN; d->bg_stable_run = 0;
          }
          break;
      }
      d->bg_last_hash = d->bg_hash; d->bg_hash = 0;
    }

    // Pace the producer to the scanout. ANTI-TEARING is now done by the post-handshake
    // vblank barrier in ensure_frame() (it blocks until the scanout has swapped off the
    // buffer we are about to overwrite — the correct point, AFTER the fabric committed
    // vctrl). So when vsync_pace is on there is nothing to do here; doing the wait here
    // too would double-pace (halve fps). When vsync is DISABLED we still need the
    // free-running ~60fps cap below.
    if (d->vsync_pace && d->vid) {
      // pacing handled at frame start (ensure_frame vblank barrier) — no-op here.
    } else {
      // free-running ~60 fps cap (vsync disabled)
      static struct timespec last = {0, 0};
      struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
      if (last.tv_sec != 0 || last.tv_nsec != 0) {
        long dus = (now.tv_sec - last.tv_sec) * 1000000L
                 + (now.tv_nsec - last.tv_nsec) / 1000L;
        const long target_us = 16667;
        if (dus >= 0 && dus < target_us) {
          struct timespec ts{0, (target_us - dus) * 1000L};
          nanosleep(&ts, nullptr);
          if (d->diag) d->t_sleep_ns += (target_us - dus) * 1000L;
        }
      }
      clock_gettime(CLOCK_MONOTONIC, &last);
    }
  }
  (void)committed;

  d->frame_active = false;
  d->frame_escaped = false;

  // A9-breakdown: mark the frame boundary (start of the next lua/update phase).
  if (d->diag) { clock_gettime(CLOCK_MONOTONIC, &d->t_present_ret); d->frame_drawn = false; }
}

}  // namespace Solarus

#else  // !MISTER_NATIVE_VIDEO — stub so non-MiSTer builds fall through to SDL

namespace Solarus {
MisterBlitterRenderer* MisterBlitterRenderer::try_create(struct SDL_Renderer*, bool) {
  return nullptr;
}
}

#endif
