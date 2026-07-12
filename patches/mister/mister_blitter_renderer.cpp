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
#include "blitter/bgplane_geom.h"     // [Phase 3b] cell grid / plane-offset math
#include "blitter/bgplane_bounds.h"   // [bug #1 fix] base-layer-only bounding box
#include "loadbar.h"                  // issue #72: pure bar-width math
#include "fps_overlay.h"              // OSD FPS overlay: clamp + 7-seg digit table
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
  volatile long long g_me_drawcache_hit   = 0;  // [SOLARUS_DRAWCACHE]
  volatile long long g_me_drawcache_miss  = 0;  // [SOLARUS_DRAWCACHE]
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
  // [eng_cpp entities drill-down] per-EntityType update ns + count (index = (int)EntityType, 0..30).
  volatile long long g_me_ent_type_ns[32]  = {0};
  volatile long long g_me_ent_type_cnt[32] = {0};
  // [emit drill-down] wall-ns inside our per-blit emit_draw (the blit-emission work)
  // vs the total emit phase (the rest = the Solarus-side draw-walk). g_emit_psadd_ns
  // isolates the diag-only ps_add tax (subtract for the shippable emit estimate).
  volatile long long g_emit_blit_ns  = 0;
  volatile long long g_emit_psadd_ns = 0;
  // [enemy SIMD-vs-throttle] wall-ns in the enemy AI Lua callback (entity_on_update).
  volatile long long g_me_enemy_lua_ns = 0;
  // [enemy entsplit] non-lua enemy update-cost split across Entity::update phases
  // (enemy-only, diag-gated). g_me_ent_coll_ns is the *nested* collision subset
  // (Map::check_collision_with_detectors quadtree+overlap) spanning sprite+move.
  volatile long long g_me_ent_sprite_ns = 0;
  volatile long long g_me_ent_move_ns   = 0;
  volatile long long g_me_ent_state_ns  = 0;
  volatile long long g_me_ent_coll_ns   = 0;
  // [move drill] terrain-obstacle collision subset of the move phase
  // (Movement::test_collision_with_obstacles). integration-math = move - obstacle.
  volatile long long g_me_ent_obst_ns   = 0;
  // [move drill L2] per-move bookkeeping in notify_position_changed: quadtree
  // remove+reinsert vs map ground re-query. Both nested in the move phase.
  volatile long long g_me_ent_qtree_ns  = 0;
  volatile long long g_me_ent_ground_ns = 0;
  // [SOLARUS_IDLESKIP diagnostic] destructibles seen vs skipped-as-idle this run.
  volatile long long g_me_destr_seen    = 0;
  volatile long long g_me_destr_skipped = 0;
}

// [HW-validated defaults] These perf/correctness gates were validated on hardware, so
// they ship ON by default — no diag.env / env var required (an end-user launch that
// doesn't source diag.env still gets the validated path). An explicit "SOLARUS_<flag>=0"
// opts out (kept so a lever can be A/B'd or disabled without a rebuild). Unset, or any
// value not starting with '0', -> ON (matches the historical "=1" enable).
static inline bool mister_flag_default_on(const char* name) {
  const char* v = std::getenv(name);
  return !(v && v[0] == '0');
}

#include <solarus/graphics/sdlrenderer/SDLSurfaceImpl.h>
#include <solarus/graphics/SurfaceImpl.h>
#include <solarus/graphics/DrawProxies.h>
#include <solarus/graphics/Color.h>
#include <solarus/core/Rectangle.h>
#include <solarus/core/Point.h>
#include <solarus/core/QuestFiles.h>
#include <solarus/graphics/Surface.h>
#include <solarus/core/Debug.h>

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

// [emit drill-down] Scoped wall-ns accumulator: adds (dtor-ctor) into *acc when
// `on`. Used to time the per-blit emit_draw body and the diag-only ps_add.
namespace {
struct ScopedNs {
  volatile long long* acc; struct timespec t0; bool on;
  ScopedNs(volatile long long* a, bool diag) : acc(a), on(diag) {
    if (on) clock_gettime(CLOCK_MONOTONIC, &t0);
  }
  ~ScopedNs() {
    if (!on) return;
    struct timespec t1; clock_gettime(CLOCK_MONOTONIC, &t1);
    *acc += (long long)(t1.tv_sec - t0.tv_sec) * 1000000000LL + (t1.tv_nsec - t0.tv_nsec);
  }
};
}  // namespace

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

// Camera top-left in MAP coords. Game::draw publishes it each frame so the [#52]
// resident tile path can compute each bucket's screen bias (normal: -camera; parallax:
// camera/ratio - camera) live, so a camera move never rebuilds the resident list.
static int g_cam_x = 0, g_cam_y = 0;
void mister_set_camera_pos(int x, int y) { g_cam_x = x; g_cam_y = y; }
// [#52] Published camera top-left. The resident path stores camera-INDEPENDENT map-coord
// dsts and reads this live each frame to compute the per-bucket screen bias (normal:
// -camera; parallax: camera/ratio - camera), so a camera move never rebuilds the list.
int mister_camera_x() { return g_cam_x; }
int mister_camera_y() { return g_cam_y; }

// [Phase 3b] The tileset's map-wide background color (Game::draw publishes it each
// frame, same site as the fill_with_color(background_color) call it mirrors -- see
// patches/series camera-tag patch). NonAnimatedRegions::record_static only ever
// records explicit placed tiles, never this background fill, so the bgplane bake
// (bake_background_plane_step) must know this color itself to clear empty cells to
// it instead of black -- otherwise every pixel with no tile bakes as black, and the
// plane's later full-screen opaque COPY permanently hides the real background color
// wherever no tile covers it. Raw components (not pre-converted to RGB565) so this
// stays independent of to_rgb565's definition order in this TU.
static uint8_t g_bg_color_r = 0, g_bg_color_g = 0, g_bg_color_b = 0;
void mister_set_background_color(uint8_t r, uint8_t g, uint8_t b) {
  g_bg_color_r = r; g_bg_color_g = g; g_bg_color_b = b;
}

// [MiSTer #24] Map-to-map transition tracking (set each frame from Game::draw). The
// scrolling transition (TransitionScrolling) blits the OLD (previous_map_surface) and
// NEW (camera surface) maps onto the root at animating scroll offsets — but our alias
// optimization composites the new map's content straight into DDR at (0,0), leaving the
// camera SURFACE's own pixels empty, so the new map has nothing to scroll in (only the
// old map scrolls away), and the two maps' atlases co-resident overflow the heap (black
// flicker).
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
// merging out of the workstream.
static bool g_transition_scroll = false;  // scrolling transition (alias-disable + heap-reset)
void mister_set_transition(bool active, bool needs_prev) {
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
// handler used to latch a blitter-off fallback -> every draw falls to the software
// offtarget path -> BLACK SCREEN (#52). The fabric composites the tiles trivially
// (~0.24 Mpx/frame); the ring was the sole limit. The heap base moves up to 0x80000 to
// make room (heap still ~15.2 MiB vs ~9.7 MiB peak use). RBF coupling: OFF_HEAP MUST
// match the fabric `SRC_QW` = (BLT_DDR_PHYS + OFF_HEAP) >> 3 = 0x07610000 in
// blitter_defs.vh — the fabric reads STAGE sources from SRC_QW + src_off.
constexpr uint32_t RING_CAP      = 0x0007FFC0u;  // ring spans 0x40..0x80000 (~512 KiB)
constexpr uint32_t OFF_HEAP      = 0x00080000u;  // heap @ 0x3B080000 (~15.2 MiB to bg-cache)
static_assert(OFF_RING + RING_CAP == OFF_HEAP,
              "[#52] command ring must be contiguous from OFF_RING up to the heap base");
// RESERVED DDR GAP at a FIXED location 0x3BF00000 (= BLT_DDR_PHYS + 0xF00000) — MUST
// MATCH the fabric's `CACHE_QW` in blitter_defs.vh. Formerly the background-composite
// cache; that feature is gone, but the gap and the heap cap below it are kept as part of
// the HW memory-map contract (the bump heap is still capped here, never overwrites it).
constexpr uint32_t OFF_BGCACHE   = 0x00F00000u;                    // ddr-relative: 0x3BF00000
constexpr uint32_t BGCACHE_HEAP_OFF = OFF_BGCACHE - OFF_HEAP;      // bump heap cap (reserves the gap)
// [#52] TILE-LIST entry buffer (BLT_OP_TILELIST). The fabric reads 12-byte tile
// entries from a fixed DDR base. MUST match fabric TL_BUF byte base 0x3BF40000
// (blitter_top.sv TL_BUF_QW). It sits ABOVE the reserved gap (0x3BF00000, 153600 B
// = 0x25800 -> ends 0x3BF25800) so the two never overlap. 512 KiB matches the
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
// [PAL8 v1] CLUT (palette lookup table) upload DMA source region. Streamed by
// BLT_OP_CLUT_UPLOAD into the fabric's clut_bram, ONE 32-bit entry (high 32 = 0)
// per 64-bit qword, mirroring FRT_UPLOAD's wire packing. MUST match the fabric
// CLUT_BUF_QW=0x3BFC3000 (blitter_defs.vh) and comp_clut.vh's CLUT_BANKS/ENTRIES.
constexpr uint32_t OFF_CLUTBUF   = 0x00FC3000u;                    // ddr-relative: 0x3BFC3000
constexpr uint32_t CLUT_BANKS    = 8u;
constexpr uint32_t CLUT_ENTRIES  = 256u;
constexpr uint32_t CLUTBUF_BYTES = CLUT_BANKS * CLUT_ENTRIES * 8u;  // 8 B (one qword) per entry
static_assert(OFF_CLUTBUF >= OFF_CFTBUF + CFT_BUF_BYTES,
              "[PAL8 v1] CLUTBUF must not overlap CFT");
static_assert(OFF_CLUTBUF + CLUTBUF_BYTES <= BLT_DDR_SIZE,
              "[PAL8 v1] CLUTBUF must fit inside the mapped DDR region");
// [MiSTer #33] SDRAM-VRAM (decoupled source addressing). The fitted AS4C32M16 chip is
// 64 MiB. The dynamic atlas allocator is based ABOVE the fixed bg-cache SDRAM offset
// (BGCACHE_HEAP_OFF ~15.7 MiB, staged at the same offset #19-style) so atlas offsets
// never collide with it. 16 MiB base -> ~48 MiB atlas region.
// [residency/XL] 128 MiB — jtframe XL (fbcache SDRAM_AW=25 in Solarus.sv) exposes both
// 64 MiB halves on the primary bus. MUST stay in lockstep with that RTL param. MoSDX's
// whole-set atlas footprint is ~60 MiB (HW-measured), which overflowed the 64 MiB chip;
// 128 MiB gives the permanent region room to fit it (perm is 64 MiB post-relocate, see
// the DIAG relocate comment below).
constexpr uint32_t SDRAM_CAP        = 0x08000000u;                 // 128 MiB (dual AS4C32M16, XL)
constexpr uint32_t SDRAM_ATLAS_BASE = 0x01000000u;                 // 16 MiB; > BGCACHE_HEAP_OFF
// [residency] Split the atlas space [SDRAM_ATLAS_BASE, SDRAM_CAP) into a large
// PERMANENT immutable region (whole-quest file assets, never freed) and a small
// recycled INTERMEDIATE region (mutable menu/text/target surfaces). Disjoint; both
// on the fabric SDRAM bus. Must not overlap the FB bases (< SDRAM_ATLAS_BASE).
constexpr uint32_t SDRAM_PERM_BASE  = SDRAM_ATLAS_BASE;                 // 16 MiB
constexpr uint32_t SDRAM_INTER_SIZE = 0x00400000u;                     // 4 MiB intermediates
// [DIAG relocate 2026-07-06] HW evidence: gameplay-background garbage reads come ENTIRELY
// from the intermediate region, which sat at SDRAM_CAP-SIZE = 124 MiB — the TOP 4 MiB of
// the 128 MiB XL space (address bit25=1), a range no HW test ever validated (clean perm
// assets only reach ~76 MiB, all bit25=0). Move inter DOWN to a proven die1 address
// (80 MiB, bit25=0) to discriminate top-of-XL fabric addressing from engine content.
// Inter working set is ~2 MiB (measured), so 4 MiB here is ample; perm shrinks to 64 MiB
// (fits the HW-measured 60.16 MiB footprint). If garbage clears, this is also the ship fix.
constexpr uint32_t SDRAM_INTER_BASE = 0x05000000u;                    // 80 MiB (die1, bit25=0)
constexpr uint32_t SDRAM_PERM_SIZE  = SDRAM_INTER_BASE - SDRAM_PERM_BASE; // 64 MiB
static_assert(SDRAM_INTER_BASE > SDRAM_PERM_BASE, "perm region must be non-empty");
// [#24] Third, disjoint SDRAM arena for the per-layer bgplane bake's ARGB4444 planes
// (Task 6). Previously these allocated out of sdram_perm alongside the whole-quest
// atlas -- on a large map (1152x1040 overworld, ~60 MiB atlas, ~4 MiB perm headroom)
// only 1 of 3 layer-planes fit, so 2 layers hit perm_overflow and fell back to the
// per-bucket replay (correct, but capped the perf win). No RTL change is needed --
// the fabric serves the whole 128 MiB; PERM/INTER/BGPLANE are a host-allocator
// concept only -- so this just carves the bgplane bake its own budget out of the
// SDRAM that was otherwise unused between INTER's top (84 MiB) and the 124 MiB
// boundary below. 124..128 MiB is DELIBERATELY left unused: the exact top-of-XL
// range (address bit25=1) that showed HW garbage under INTER's churn before INTER
// was relocated down to 80 MiB (see the DIAG relocate comment above) -- its root
// cause was never found, so BGPLANE must not extend into it either.
constexpr uint32_t SDRAM_BGPLANE_BASE = 0x05400000u;  // 84 MiB (right after INTER's 80..84)
constexpr uint32_t SDRAM_BGPLANE_SIZE = 0x02800000u;  // 40 MiB -> ends at 0x07C00000 = 124 MiB
static_assert(SDRAM_BGPLANE_BASE >= SDRAM_INTER_BASE + SDRAM_INTER_SIZE,
              "bgplane must not overlap inter");
static_assert(SDRAM_BGPLANE_BASE + SDRAM_BGPLANE_SIZE <= 0x07C00000u,
              "bgplane must stay below the 124 MiB dead zone");
// control-block byte offsets — QWORD-spaced (fabric reads qword fields), low 32 used
constexpr uint32_t C_SUBMIT = 0x00, C_CMDCOUNT = 0x08, C_TARGET = 0x10,
                   C_CLEAR  = 0x18, C_FLAGS    = 0x20, C_DONE = 0x28,
                   C_STATUS = 0x30,  // low32=status; high32=perf_pipe_cyc (HW perf)
                   C_SRCSEL = 0x38;   // bit0 (source mux) now dead — source always
                                      // SDRAM; bits[15:8] carry the f2h write-throttle

constexpr int FB_W = 320, FB_H = 240;

// [#72] Load-progress bar geometry (RGB565) + colors. Centered on the 320x240 FB.
static const int      LOADBAR_TRACK_W = 200;
static const int      LOADBAR_TRACK_H = 12;
static const int      LOADBAR_TRACK_X = (FB_W - LOADBAR_TRACK_W) / 2;   // 60
static const int      LOADBAR_TRACK_Y = 150;
static const uint16_t LOADBAR_BG      = 0x0000;   // black background
static const uint16_t LOADBAR_TRACK   = 0x8410;   // mid gray (empty) — visible on black from 0%
static const uint16_t LOADBAR_FILL    = 0xFFFF;   // white (filled)

// [OSD-fps] FPS overlay geometry (RGB565), bottom-right corner of the 320x240 FB.
// 2 digits (0-99, per fps_overlay_clamp), 7-segment style, drawn as blt_fill rects.
static const int      FPSOV_DIGIT_W = 8;
static const int      FPSOV_DIGIT_H = 14;
static const int      FPSOV_SEG_T   = 2;    // segment thickness
static const int      FPSOV_GAP     = 2;    // gap between the two digits
static const int      FPSOV_MARGIN  = 12;   // margin from the FB's right/bottom edges
                                             // (12 - BG_PAD=2 -> ~10px visible inset,
                                             // clears CRT overscan; was 4)
static const int      FPSOV_BG_PAD  = 2;    // background panel padding around the digits
static const uint16_t FPSOV_BG      = 0x0000;   // black background panel
static const uint16_t FPSOV_FG      = 0x07E0;   // green digits (RGB565)

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

  // Mapping of the VIDEO framebuffer region (0x3A000000). Used by the persistence
  // model's carry-forward (DDR-to-DDR copy of the prior committed buffer) and to
  // read the scanout vsync counter for frame pacing.
  volatile uint8_t* vid = nullptr;
  int vid_fd = -1;

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

  // ── [#52 resident, Task 7] Resident animated-tile list (SOLARUS_TILERESIDENT) ──
  // SINGLE fabric-resolved path, no fallback. The animated tiles are STATIC content:
  // while the camera is still and the map/tileset are unchanged, the set of visible
  // tiles + their dst are identical frame-to-frame; only each pattern's src rect
  // changes, and only when it ticks. So we build the resident list ONCE (a "build"
  // frame: walk + resident_record_batch), then on later "fast" frames the engine skips
  // the walk entirely and just patches each ticked pattern's current frame (CFT) +
  // replays the recorded per-bucket BLT_OP_TILELIST_RES headers (fabric resolves each
  // entry's src from FRT[pid][CFT[pid]]). There is no legacy/engine-src-patch tier and
  // no per-scene escape-to-legacy: an unbatchable bucket or a TL_BUF overflow is a BUG,
  // surfaced via res_fatal (loud fprintf), never a silent degrade.
  bool res_enabled = false;                    // SOLARUS_TILERESIDENT
  bool res_fatal   = false;                    // [Task 7] loud hard-fail latch; SCENE-scoped
                                               // (reset per rebuild in resident_begin_frame so one
                                               //  unbatchable map can't flat the whole session)
  // cached scene signature [#52 camera-independent] — camera (vpx/vpy) is NO LONGER part
  // of the signature: the resident list stores whole-map MAP-coord dsts and the fabric
  // applies a per-bucket camera bias each frame, so a camera move never forces a rebuild.
  uintptr_t res_map = 0, res_tileset = 0;
  bool res_valid    = false;                   // a completed build is cached
  bool res_building = false;                   // recording a build this frame
  bool res_armed = false;                      // 8-byte entries + FRT written for this scene
  bool res_frt_uploaded = false;               // FRT_UPLOAD emitted this scene
  // one resident entry's (pattern_id, dst) for the 8-byte TL_BUF layout.
  struct ResEnt { uint16_t pid; int16_t dx, dy; };
  struct ResBucket {
    const SurfaceImpl* tsimg; uint8_t blend, flags, fmt; uint16_t key;
    int layer;
    int scroll_ratio;                          // [#52 camera-indep] 1=normal, r=parallax
    uint32_t hw_off; int hw_count;             // 8-byte entries written at arm
    std::vector<ResEnt> hw;                    // (pid,dst) sequence for the 8-byte entries
  };
  struct ResPattern {
    uintptr_t token;
    int frame_count = 1; Rectangle frames[BLT_MAXF]; uint16_t cur_frame = 0;  // FRT/CFT
  };
  std::vector<ResBucket>  res_buckets;
  // [#52 resident] Per-layer ordered bucket list, replayed in strict encounter (paint)
  // order on the fast path. [Task 7] every op IS a bucket now — the earlier per-op
  // escape/esc replay (re-issuing a non-batchable tile's tile.draw()) is gone; a
  // non-batchable tile is a res_fatal, not a per-tile fallback.
  struct ResOp { uint32_t bk; int layer; };
  std::vector<ResOp>      res_ops;
  // [static tile-list] 12-byte direct-src entry (map-coord dst) + its bucket. Parallel
  // to ResBucket/ResEnt but for BLT_OP_TILELIST (no pattern indirection, no BLT_MAXP cap).
  struct StaticEnt { uint16_t sx, sy, w, h; int16_t dx, dy; };   // matches blt_tile_entry_t
  struct StaticBucket {
    const SurfaceImpl* tsimg; uint8_t blend, flags, fmt; uint16_t key;
    int layer; int scroll_ratio;
    uint32_t hw_off; int hw_count;              // 12-byte entries written at arm
    std::vector<StaticEnt> ent;
  };
  std::vector<StaticBucket> res_static_buckets;
  std::vector<ResOp>        res_static_ops;      // (bucket idx, layer) in paint order
  std::vector<ResPattern> res_patterns;        // distinct pattern tokens (animated + static)
  std::unordered_map<uintptr_t, size_t> res_pat_index;  // token -> res_patterns idx
  // per-frame memoization (keyed by res_epoch, bumped each present())
  unsigned res_epoch = 0;
  unsigned res_decided_epoch = ~0u; int res_mode = 0;
  unsigned res_patch_epoch = ~0u;
  // diag tallies (/60fr)
  long res_rebuilds = 0, res_patch_passes = 0, res_noops = 0, res_patched_entries = 0;

  // [Phase 3b, generalized Task 6] Background-plane cache: the static resident
  // buckets (res_static_buckets) are baked ONCE per map/tileset change into a
  // permanent SDRAM plane, cell by cell (comp_fbram-sized 320x240 cells, see
  // bgplane_geom.h), instead of being replayed via BLT_OP_TILELIST every
  // frame. Bake progress is spread across frames (one cell per present(),
  // like the load-progress bar at preload_quest_assets) so a large map's
  // bake never stalls a single frame noticeably. [Task 6] Generalized from a
  // single hardcoded base-layer plane (the old flat bg_* fields below) to one
  // plane per layer that has static content -- every layer gets baked now,
  // keyed by layer in bg_planes instead of an implicit bg_base_layer.
  bool bgplane_enabled = false;   // SOLARUS_BGPLANE, opt-in (default OFF until HW-validated)
  // [ARGB4444 plane bake] one bake per layer that has static content, keyed by
  // layer instead of a single hardcoded bg_base_layer. bg_clear_rgb565 is gone --
  // ARGB4444 alpha=0 gaps need no clear-color tracking (see patch 0033 removal,
  // Task 7).
  struct BgPlane {
    bool     valid = false;    // a completed bake is ready to use
    bool     baking = false;   // a bake is in progress this map for this layer
    bool     copied_this_frame = false; // latch: this layer's plane COPY
                                  // (resident_emit_static_layer) fires at most
                                  // once per frame even though the engine calls
                                  // it once per map layer
    uint32_t sdram_base = 0;   // SDRAM byte offset of this layer's plane (in the
                                  // dedicated sdram_bgplane arena, #24 -- not
                                  // sdram_perm, which holds only the atlas)
    bool     sdram_allocated = false; // true iff sdram_base/map_w/h name a live
                                  // blt_alloc(sdram_bgplane) region owed a free
    int      bake_cell_idx = 0; // next cell index to bake (0..grid.count) for
                                  // this layer's plane
    int      bake_cell_retries = 0; // [#109] consecutive ring-overflow retries of
                                  // the CURRENT bake_cell_idx. The ring is emptied
                                  // every frame, so a cell that keeps overflowing a
                                  // FRESH ring cannot fit at all -> bounded so it
                                  // hard-fails+skips instead of stalling forever.
    int      map_w = 0, map_h = 0; // map pixel dims this plane covers
    int      origin_x = 0, origin_y = 0; // true min map-coord x/y across all
                                  // recorded static tiles on this layer -- a
                                  // map's content is NOT guaranteed to start at
                                  // (0,0) (seen as low as x=-8/y=-24 on real
                                  // hardware); the plane's internal coordinate
                                  // space always starts at (0,0), so every
                                  // producer (bake bias) and consumer (camera-
                                  // relative read) must shift by this origin to
                                  // land in-bounds.
  };
  std::unordered_map<int, BgPlane> bg_planes;   // keyed by layer

  // per-frame state
  bool frame_active  = false;
  bool frame_escaped = false;
  bool clear_requested = false;   // Solarus issued clear(fpga_target) this frame ->
                                  // hardware-clear the DDR buffer; else persist it
  int  target_buf    = 0;
  // [#91] Single-buffer is the SAFE DEFAULT (never alternate the display buffer;
  // composite into buffer 0 forever). The FB-in-BRAM fabric keeps ONE persistent
  // on-chip framebuffer (comp_fbram), so the legacy double-buffer carry-forward
  // (see ensure_frame) reads an SDRAM FB that fabric no longer writes -> stale
  // garbage. The double-buffer path is now an explicit diagnostic opt-out
  // (SOLARUS_BLITTER_SINGLEBUF=0) and is known-broken under the current fabric.
  bool single_buf    = true;

  // env-gated diagnostics (SOLARUS_BLITTER_DIAG=1): per-window tallies.
  bool diag = false;
  // [#24 arena probe] SOLARUS_ARENA_PROBE=1: replace gameplay with the definitive
  // SDRAM-arena HW probe (see run_arena_probe()).
  bool arena_probe = false;
  bool bgw_probe = false;   // [bgw] SOLARUS_BGW_PROBE: HW OP_BGPLANE_WRITE write-path test
  // [#24 host bake audit, DIAGNOSTIC ONLY] SOLARUS_BGPLANE_DIAG=1: per-layer
  // fprintf + runtime log-and-continue asserts in res_arm_ and
  // resident_emit_static_layer, to read the actual runtime geometry/arena
  // values off a failing map (the fabric bake path is HW/sim-proven bit-exact
  // at arena bases -- .superpowers/sdd/task-24-host-bake-audit.md -- so any
  // remaining #24 banding must be a host runtime value this surfaces). Zero
  // cost when unset; NOT a fix, purely observability. Separate from the
  // general SOLARUS_BLITTER_DIAG (`diag` above) so it can be enabled alone.
  bool bgplane_diag = false;
  // [pot diag, DIAGNOSTIC ONLY] SOLARUS_POT_DIAG=1 traces small sprite/tile draws
  // (<=32x32 src region) through emit_draw, so a destructible's entities-image draw
  // can be told apart -- on HW, by source identity and resolved SDRAM offset -- from a
  // tiles-image draw (e.g. deep_water). Answers: is the pot's blit even emitted under
  // bgplane, and does its source resolve to the entities atlas or somewhere else?
  // Zero cost when unset; separate flag so it can run without the noisy bgplane bake diag.
  bool pot_diag = false;
  // Dedup by (source surface, src rect) so each DISTINCT source-region logs exactly once
  // across the session -- a static destructible logs one line no matter how many frames it
  // survives, and the trace can't push the pot past a per-frame cap on a busy screen.
  std::unordered_set<uint64_t> pot_diag_seen;
  static constexpr size_t POT_DIAG_MAX_LINES = 512;   // total output guard
  // [#24 host bake audit, DIAGNOSTIC ONLY] SOLARUS_BGPLANE_SOLID=1 (v2 --
  // row-gradient): replace each layer's real bake content with a per-layer
  // ARGB4444-channel gradient derived from PLANE ROW (layer 0=RED channel,
  // layer 1=GREEN, layer 2=BLUE; cycles for any other layer index), painted
  // ONLY at each real static tile's own destination rectangle -- so the REAL
  // per-tile coverage footprint is preserved (gaps stay transparent, lower
  // layers still show through) -- see bake_background_plane_step() and
  // bgplane_gradient_debug_color(). A correct read shows a smooth
  // top-to-bottom gradient in that layer's hue; an offset read shows a
  // discontinuity/seam at the exact row the bug kicks in, whose color decodes
  // the offset delta; the wrong hue at a seam would name cross-layer
  // contamination. (v1 used one flat color per layer -- superseded: a flat
  // color can't reveal an intra-layer offset, since a shifted uniform block
  // still looks uniform.) Zero cost when unset; NOT a fix.
  bool bgplane_solid = false;
  // [FORK-SPLITTER DIAGNOSTIC ONLY] SOLARUS_BGPLANE_COPYDBG=1: force the per-
  // frame plane COPY (resident_emit_static_layer) to BLT_BLEND_COPY instead of
  // BLT_BLEND_PALPHA, i.e. blit the plane's RGB unconditionally and IGNORE the
  // ARGB4444 alpha nibble. Splits the "committed plane reads transparent" bug:
  //   floor's brown RGB APPEARS -> plane RGB is present, ALPHA is wrong (the
  //     coverage->alpha pack wrote 0). Fix = OP_BGPLANE_WRITE/coverage pack.
  //   floor STILL blank -> nothing meaningful is in the plane at all (WORK paint
  //     or OP_BGPLANE_WRITE not landing). Fix = the bake write path.
  // Transparent GAPS will over-paint (their stale WORK color) under COPY -- that
  // over-paint is EXPECTED and does not affect the yes/no "is the floor RGB
  // there" read. Zero cost when unset; NOT a fix.
  bool bgplane_copydbg = false;
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
  //   present-ov = A9 - lua - emit  (submit/doorbell/input-poll in present())
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
  long long t_enttype_ns_prev[32] = {0};         // [enttype] per-EntityType ns snapshot
  long long t_enttype_cnt_prev[32] = {0};        // [enttype] per-EntityType count snapshot
  long long t_emit_blit_prev = 0, t_emit_psadd_prev = 0;  // [emit drill-down] snapshots
  long long t_enemy_lua_prev = 0;                // [enemy split] enemy AI Lua snapshot
  long long t_ent_sprite_prev = 0, t_ent_move_prev = 0;   // [entsplit] phase snapshots
  long long t_ent_state_prev = 0,  t_ent_coll_prev = 0;   // [entsplit] phase snapshots
  long long t_ent_obst_prev = 0;                          // [move drill] obstacle snapshot
  long long t_ent_qtree_prev = 0, t_ent_ground_prev = 0;  // [move drill L2] snapshots
  long long t_destr_seen_prev = 0, t_destr_skip_prev = 0;  // [idleskip] destr skip snapshot
  long long t_dch_prev = 0, t_dcm_prev = 0;  // [SOLARUS_DRAWCACHE] hit/miss snapshot
  void mark_render() {                    // call at top of clear/fill/draw
    if (!diag || frame_drawn) return;
    struct timespec n; clock_gettime(CLOCK_MONOTONIC, &n);
    if (t_present_ret.tv_sec || t_present_ret.tv_nsec)
      t_lua_ns += ns_diff(n, t_present_ret);
    t_first_draw = n;
    frame_drawn = true;
  }

  // --- per-layer BLIT-PARAM stability DIAGNOSTIC ("does the background scroll?") --
  // For each distinct source surface, hash ALL its blit params (src-region + dst)
  // within a frame; compare that hash to last frame's. stable% = how often a layer's
  // composite is IDENTICAL frame-to-frame (a static background layer); a scrolling/
  // animated layer (hero) varies -> low stable%. Reported in [blitter paramstab].
  // 128 slots (was 16): with only 16, early DYNAMIC sources filled the table and
  // ps_add() dropped later cells (returns when full), skewing the stats. Sizing for the
  // full per-scene source set (tiles+sprites, P0 distinct_tex<=~12/window) covers them.
  static const int PST_N = 128;
  const void* ps_ptr[PST_N] = {0};
  unsigned long long ps_hash[PST_N] = {0}, ps_lasthash[PST_N] = {0};
  long ps_stable[PST_N] = {0}, ps_vary[PST_N] = {0};   // per-diag-window (reset each 60fr)
  int  ps_w[PST_N] = {0}, ps_h[PST_N] = {0};
  bool ps_drawn[PST_N] = {false};            // appeared this frame
  int  ps_used = 0;
  void ps_add(const void* p, int sx, int sy, int w, int h, int dx, int dy,
              int sw, int sh) {
    ScopedNs _ps(&g_emit_psadd_ns, diag);   // [emit drill-down] isolate the diag-only ps_add tax
    int i; for (i = 0; i < ps_used; i++) if (ps_ptr[i] == p) break;
    if (i == ps_used) { if (ps_used >= PST_N) return;
      ps_ptr[i] = p; ps_w[i] = sw; ps_h[i] = sh; ps_used++; }
    // Hash the dst in SCREEN coords: while scrolling this changes the hash, which is the
    // correct signal for the param-stability diagnostic (a scrolling layer reads as varying).
    const int mdx = dx;
    const int mdy = dy;
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
      ps_lasthash[i] = ps_hash[i]; ps_hash[i] = 0; ps_drawn[i] = false;
    }
  }

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
  // [collapse-single-source] Source staging is now UNCONDITIONAL: the fabric reads
  // every atlas source from SDRAM (the DDR3 live-source path was removed), so we
  // ALWAYS stage atlases DDR3->SDRAM and ALWAYS write C_SRCSEL=1. No env opt-in.
  bool stage_enabled   = true;           // always: stage sources + read them from SDRAM
  uint32_t throttle_val = 32;            // [MiSTer #34] f2h write-throttle cycles (SOLARUS_BLT_THROTTLE)

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

  // [residency] Surfaces classified IMMUTABLE (whole-quest file assets, staged once
  // into the permanent region by the preload driver). Members are quest-lifetime
  // (Solarus image_files_cache keeps them alive), so their pointer identity is stable
  // and they are never re-staged or dirty-tracked. Everything NOT in this set is a
  // mutable intermediate (staged into the recycled region, refreshed on dirty, freed
  // on destruction).
  std::unordered_set<const SurfaceImpl*> immutable_set;
  bool is_immutable(const SurfaceImpl* p) const { return immutable_set.count(p) != 0; }

  // [residency] Keep every preloaded SurfacePtr alive for the quest so its SurfaceImpl
  // pointer stays valid + resident (belt-and-braces alongside Solarus's own
  // image_files_cache). Also the one-shot guard for the preload pass.
  std::vector<Solarus::SurfacePtr> preload_pins;
  bool preloaded = false;

  // [#72] load-progress-bar state (set in preload_quest_assets, read in the drain seam)
  bool     loadbar_on     = false;   // cached SOLARUS_LOADBAR gate
  uint32_t preload_total  = 0;       // total PNGs to stage (pre-count)
  uint32_t preload_staged = 0;       // PNGs staged so far
  uint32_t loadbar_step   = 1;       // repaint the bar every N staged PNGs (~40 updates)

  // [OSD-restart] Edge-detect state for the OSD "Restart Quest" toggle (status[19],
  // mirrored into C_STATUS low32 bit0 by blitter_top's S_WR_STATUS write).
  bool prev_osd_restart = false;

  // [OSD-fps] Latest rolling FPS value (set by MainLoop via mister_set_fps() every
  // ~30 frames) and drawn in present() when the OSD "FPS Overlay" toggle
  // (status[20], mirrored into C_STATUS low32 bit1) is on.
  double fps_value = 0.0;

  // [residency] immutable file assets never mutate; only track intermediates.
  void mark_src_dirty(const SurfaceImpl* p) { if (p && !is_immutable(p)) dirty_src.insert(p); }

  // [residency] Evict a destroyed surface from all caches and free its recycled slot.
  // Immutable file assets are never destroyed mid-quest, but guard anyway.
  void forget_surface(const SurfaceImpl* p) {
    for (uint8_t fmt : { (uint8_t)BLT_FMT_RGB565, (uint8_t)BLT_FMT_ARGB4444 }) {
      auto it = handles.find(SurfKey{ p, fmt });
      if (it == handles.end()) continue;
      if (!is_immutable(p)) {                 // permanent slots are never freed
        blt_sdram_free(&em, &it->second);     // return the intermediate SDRAM slot
        blt_emitter_free(&em, it->second.off, it->second.size);  // return the DDR bounce block
      }
      handles.erase(it);
    }
    dirty_src.erase(p);
    too_big.erase(p);
    immutable_set.erase(p);
  }

  bool map_ddr() {
    mem_fd = ::open("/dev/mem", O_RDWR | O_SYNC);
    if (mem_fd < 0) return false;
    void* p = ::mmap(nullptr, BLT_DDR_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
                     mem_fd, BLT_DDR_PHYS);
    if (p == MAP_FAILED) { ::close(mem_fd); mem_fd = -1; return false; }
    ddr = static_cast<volatile uint8_t*>(p);
    // Cap the bump heap BELOW the fixed reserved DDR gap (OFF_BGCACHE) so it can never
    // overwrite it. With the 16 MiB region the heap still gets ~15.7 MiB —
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

  // [OSD-restart] True exactly once per off->on transition of C_STATUS low32 bit0.
  bool take_restart_edge() {
    if (!ddr) return false;
    bool cur = (ddr_r32(C_STATUS) & 0x1u) != 0;
    bool edge = cur && !prev_osd_restart;
    prev_osd_restart = cur;
    return edge;
  }

  // [OSD-fps] Whether the OSD "FPS Overlay" toggle is currently on (C_STATUS low32 bit1).
  bool fps_overlay_enabled() {
    return ddr && (ddr_r32(C_STATUS) & 0x2u) != 0;
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

  // Whole-quest asset residency (Task 6/7) keeps every atlas permanently resident
  // in SDRAM, so the working set no longer overflows the heap mid-session — the
  // only reason the blitter can be unusable is the absence of the FPGA/DDR path
  // itself (software-only build, or the DDR map failed at init).
  bool blitter_off() const { return !ddr; }

  void ensure_frame() {
    if (!frame_active) {
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
      // protection. Falls back fast if the counter isn't advancing (old RBF).
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
      // [Task 6] reset every layer's per-frame bg-plane-COPY latch (was a single
      // flat flag when there was only ever one plane; now one per baked layer).
      for (auto& kv : bg_planes) kv.second.copied_this_frame = false;
    }
  }

  // [residency] Publish the current command batch and block until the fabric finishes
  // it. Used by the preload driver to drain a staging batch before reusing the DDR3
  // bounce heap. Mirrors present()'s doorbell (control-block writes + fence + C_SUBMIT)
  // and ensure_frame()'s C_DONE handshake.
  void submit_and_drain() {
    blt_end_frame(&em);
    ddr_w32(C_CMDCOUNT, (uint32_t)em.cmd_count);
    ddr_w32(C_TARGET,   (uint32_t)em.target_buf);
    ddr_w32(C_CLEAR,    em.clear_color);
    ddr_w32(C_FLAGS,    em.flags);
    ddr_w32(C_SRCSEL,   1u | ((throttle_val & 0xFFu) << 8));
    __sync_synchronize();                 // commit ring+ctrl before the doorbell
    ddr_w32(C_SUBMIT,   em.submit_seq);
    struct timespec ts{0, 200000};        // 0.2 ms between polls
    for (int spin = 0; spin < 5000 && ddr_r32(C_DONE) != em.submit_seq; ++spin)
      nanosleep(&ts, nullptr);            // up to ~1 s, then give up (fabric wedged)
  }

  // [#24 arena probe] SOLARUS_ARENA_PROBE=1: the definitive HW test for whether the
  // 84-124 MiB SDRAM arena PHYSICALLY corrupts (vs a logic/host bug). Each of 10
  // SDRAM bases is written a 32x192 RGB565 pattern whose per-32px-band color is a
  // bijection of the band's GLOBAL SDRAM row (rowabs = byte>>11), then read back to
  // an on-screen 32px strip via an opaque COPY (SDRAM source, ch5 P_SRC). A correct
  // read shows a deterministic per-band color; a mis-addressed band decodes (host
  // harness) to WHICH row it aliased from; a dead cell shows non-invertible noise.
  // Bases cover: chip0 sanity, chip1/bank0 perm control, the arbiter pair
  // chip1/bank1 INTER-low (80 MiB, works) vs arena-mid (84 MiB, bands) -- same bank,
  // only row differs, byte-identical code -- and bank1/2/3 high rows. The fabric
  // address path is sim-proven bit-exact (tb_sdram_fb_cache_xl arena_uniqueness), so
  // any corruption here is physical. Spec: .superpowers/sdd/task-24-probe-spec.md.
  void run_arena_probe() {
    static const uint32_t BASE[10] = {
      0x0800000u, 0x4000000u, 0x4F00000u, 0x5000000u, 0x5400000u,
      0x5F00000u, 0x6000000u, 0x6F00000u, 0x7000000u, 0x7B00000u };
    blt_heap_reset(&em);   // begin_frame does NOT reset the heap; reclaim last frame's uploads
    blt_begin_frame(&em, target_buf, /*clear=*/1, /*clear_color=*/0x0000);
    static uint16_t pat[32 * 192];
    for (int i = 0; i < 10; ++i) {
      const uint32_t S = BASE[i];
      for (int r = 0; r < 192; ++r) {               // 32 source-rows == one 2048B SDRAM row
        const uint32_t rowabs = (S + (uint32_t)(r >> 5) * 2048u) >> 11;
        const uint16_t v = (uint16_t)((rowabs * 0x9E37u) & 0xFFFFu);      // bijective diffusion
        const uint16_t c = (uint16_t)(((v & 0x1F) << 11) | (((v >> 5) & 0x3F) << 5) | ((v >> 11) & 0x1F));
        for (int x = 0; x < 32; ++x) pat[r * 32 + x] = c;
      }
      blt_surface_ref_t ref = blt_upload(&em, pat, 32, 192, 32 * 2);      // pattern -> DDR bounce
      if (!ref.valid) continue;
      blt_stage_to(&em, ref.off, S, 32u * 192u * 2u);                     // DDR -> SDRAM @ S (auto-barrier)
      blt_surface_ref_t raw;
      std::memset(&raw, 0, sizeof(raw));
      raw.sdram_off = S; raw.w = 32; raw.h = 192; raw.stride = 32 * 2;
      raw.format = BLT_FMT_RGB565; raw.valid = 1;
      blt_blit(&em, raw, 0, 0, 32, 192, 32 * i, 0, BLT_BLEND_COPY, 0, 255, 0);  // SDRAM @ S -> strip
    }
    submit_and_drain();
  }

  // [BGW-PROBE, DIAGNOSTIC ONLY] SOLARUS_BGW_PROBE=1: the definitive HW test for
  // whether OP_BGPLANE_WRITE's SDRAM WRITE path actually lands on hardware. The
  // ARENA_PROBE above only validates the STAGE write (DDR->SDRAM) + P_SRC read of
  // the arena; it never exercises OP_BGPLANE_WRITE (the fbram_to_sdram streamer ->
  // ch0 dst_wr/ok_hold handshake). HW A/B (engine 639aa284) shows every baked plane
  // reads back ENTIRELY ZERO (COPYDBG=black + PALPHA=transparent) while the fabric
  // bake logic is bit-exact in sim (tb_bgplane_equivalence TL_COV_PA), which points
  // straight at this unvalidated write path. This probe paints a known WORK pattern,
  // OP_BGPLANE_WRITEs it to the arena, and (on later frames) reads it straight back
  // via a normal COPY blit. If the readback frames are BLACK, OP_BGPLANE_WRITE's
  // write does not land on HW -- the root cause. If they show the red/green bands,
  // the write works and the bug is elsewhere. Two-phase by frame count so the write
  // (ch0) commits across a vblank before the read (ch5/P_SRC) -- same cross-frame
  // coherency the real bake relies on (write frame N, COPY frame N+1).
  int  bgw_probe_frame = 0;
  // A/B airtight version: region A is written ONLY via OP_BGPLANE_WRITE (the
  // unvalidated path), region B ONLY via blt_stage_to (the #24-validated DDR->SDRAM
  // write). BOTH are read back with the SAME COPY blit. Readback (left half = A, right
  // half = B):
  //   A black + B red  -> OP_BGPLANE_WRITE write does NOT land on HW (readback + STAGE
  //                        both proven good by B) == ROOT CAUSE, airtight.
  //   A green + B red   -> OP_BGPLANE_WRITE works; the bug is elsewhere.
  void run_bgw_probe() {
    static constexpr uint32_t ARENA_W = 0x05400000u;   // OP_BGPLANE_WRITE target
    static constexpr uint32_t ARENA_S = 0x05480000u;   // blt_stage_to target (disjoint, known-good path)
    static constexpr uint32_t STRIDE_QW = 80;          // 320px cell: 320*2B/8
    static uint16_t spat[320 * 240];
    blt_heap_reset(&em);
    blt_begin_frame(&em, target_buf, /*clear=*/1, /*clear_color=*/0x0000);
    if (bgw_probe_frame < 30) {
      // (A) OP_BGPLANE_WRITE path: fill WORK green, stream WORK -> ARENA_W.
      blt_fill(&em, 0, 0, FB_W, FB_H, 0x07E0);                          // green
      blt_bgplane_write_cell(&em, ARENA_W / 8, STRIDE_QW, /*flags=*/0); // raw RGB565
      // (B) STAGE path (known-good): upload a red image to DDR, stage DDR -> ARENA_S.
      for (int i = 0; i < 320 * 240; ++i) spat[i] = 0xF800;            // red
      blt_surface_ref_t ref = blt_upload(&em, spat, 320, 240, 320 * 2);
      if (ref.valid) blt_stage_to(&em, ref.off, ARENA_S, 320u * 240u * 2u);
    } else {
      // READBACK: both regions via the SAME COPY blit. A -> left half, B -> right half.
      blt_surface_ref_t pa; std::memset(&pa, 0, sizeof(pa));
      pa.sdram_off = ARENA_W; pa.w = 320; pa.h = 240;
      pa.stride = (uint16_t)(STRIDE_QW * 8); pa.format = BLT_FMT_RGB565; pa.valid = 1;
      blt_blit(&em, pa, 0, 0, FB_W / 2, FB_H, 0, 0, BLT_BLEND_COPY, 0, 255, 0);
      blt_surface_ref_t pb; std::memset(&pb, 0, sizeof(pb));
      pb.sdram_off = ARENA_S; pb.w = 320; pb.h = 240;
      pb.stride = (uint16_t)(320 * 2); pb.format = BLT_FMT_RGB565; pb.valid = 1;
      blt_blit(&em, pb, FB_W / 2, 0, FB_W / 2, FB_H, FB_W / 2, 0, BLT_BLEND_COPY, 0, 255, 0);
    }
    if (bgw_probe_frame < 100000) ++bgw_probe_frame;
    submit_and_drain();
  }

  static bool ends_with_png(const std::string& p) {
    return p.size() >= 4 && p.compare(p.size() - 4, 4, ".png") == 0;
  }

  // [#72] Count quest PNGs without decoding — directory listing only. Denominator
  // for the progress bar. Mirrors the stage-loop walk shape but never loads a surface.
  uint32_t count_quest_pngs() {
    uint32_t n = 0;
    std::vector<std::string> stack{ std::string() };
    while (!stack.empty()) {
      std::string dir = stack.back(); stack.pop_back();
      for (const std::string& name : Solarus::QuestFiles::data_file_list_dir(dir)) {
        std::string path = dir.empty() ? name : dir + "/" + name;
        if (Solarus::QuestFiles::data_file_is_dir(path)) { stack.push_back(path); continue; }
        if (ends_with_png(path)) ++n;
      }
    }
    return n;
  }

  // [#72] Emit the bar's three FILL rects into the CURRENTLY-OPEN frame (no begin/submit).
  // Full-screen bg fill makes each frame self-contained (idempotent) regardless of WORK
  // persistence; then track, then the growing fill. Composites into WORK -> snapshot -> SCAN.
  void emit_loadbar_fills() {
    if (!loadbar_on) return;
    blt_fill(&em, 0, 0, FB_W, FB_H, LOADBAR_BG);
    blt_fill(&em, LOADBAR_TRACK_X, LOADBAR_TRACK_Y, LOADBAR_TRACK_W, LOADBAR_TRACK_H, LOADBAR_TRACK);
    int fw = loadbar_fill_w(LOADBAR_TRACK_W, preload_staged, preload_total);
    if (fw > 0)
      blt_fill(&em, LOADBAR_TRACK_X, LOADBAR_TRACK_Y, fw, LOADBAR_TRACK_H, LOADBAR_FILL);
  }

  // [#72] Paint one standalone bar frame (own begin_frame + submit). Used for the
  // initial 0% (kills garbage at frame 0) and any point not piggybacking a stage drain.
  void paint_loadbar() {
    if (!loadbar_on) return;
    blt_begin_frame(&em, target_buf, /*clear=*/0, /*clear_color=*/0x0000);
    emit_loadbar_fills();
    submit_and_drain();
  }

  // [OSD-fps] Draw one 7-segment digit (0-9) via blt_fill segment rects.
  // (x,y) = top-left of the digit cell.
  void emit_fps_digit(int x, int y, int digit) {
    if (digit < 0 || digit > 9) return;
    uint8_t segs = FPSOV_SEGMENTS[digit];
    const int W = FPSOV_DIGIT_W, H = FPSOV_DIGIT_H, T = FPSOV_SEG_T;
    if (segs & 0x01) blt_fill(&em, x + 1,     y,             W - 2, T,       FPSOV_FG); // a
    if (segs & 0x02) blt_fill(&em, x + W - T, y + 1,         T,     H/2 - 1, FPSOV_FG); // b
    if (segs & 0x04) blt_fill(&em, x + W - T, y + H/2,       T,     H/2 - 1, FPSOV_FG); // c
    if (segs & 0x08) blt_fill(&em, x + 1,     y + H - T,     W - 2, T,       FPSOV_FG); // d
    if (segs & 0x10) blt_fill(&em, x,         y + H/2,       T,     H/2 - 1, FPSOV_FG); // e
    if (segs & 0x20) blt_fill(&em, x,         y + 1,         T,     H/2 - 1, FPSOV_FG); // f
    if (segs & 0x40) blt_fill(&em, x + 1,     y + (H-T)/2,   W - 2, T,       FPSOV_FG); // g
  }

  // [OSD-fps] Draw the 2-digit FPS readout (00-99) with a background panel, bottom-
  // right corner of the currently-open frame. Called from present() right before
  // blt_end_frame, so it overlays the game's own draws for this frame.
  void emit_fps_overlay_fills() {
    int fps = fps_overlay_clamp(fps_value);
    int tens = fps / 10, ones = fps % 10;
    const int total_w = FPSOV_DIGIT_W * 2 + FPSOV_GAP;
    const int x0 = FB_W - total_w - FPSOV_MARGIN;
    const int y0 = FB_H - FPSOV_DIGIT_H - FPSOV_MARGIN;
    blt_fill(&em, x0 - FPSOV_BG_PAD, y0 - FPSOV_BG_PAD,
             total_w + 2 * FPSOV_BG_PAD, FPSOV_DIGIT_H + 2 * FPSOV_BG_PAD, FPSOV_BG);
    emit_fps_digit(x0, y0, tens);
    emit_fps_digit(x0 + FPSOV_DIGIT_W + FPSOV_GAP, y0, ones);
  }

  // [#72] Force a bar repaint mid-staging on a fixed per-file cadence: paint the bar into
  // the open staging frame, flush it (submit+snapshot so the scanout advances), reset the
  // DDR3 bounce, and reopen a staging frame. Mirrors the overflow-drain sequence. Needed
  // because the bounce-overflow drains cluster near the END of the load, so without this
  // the bar sits at 0% then jumps to 100% (HW-observed) instead of advancing smoothly.
  // Perm SDRAM allocations persist across the bounce reset; called only BETWEEN fully
  // staged assets, so no asset is mid-flight.
  void flush_with_loadbar() {
    if (!loadbar_on) return;
    emit_loadbar_fills();
    submit_and_drain();
    blt_heap_reset(&em);
    blt_begin_frame(&em, target_buf, /*clear=*/0, /*clear_color=*/0x0000);
  }

  // [residency] One-time whole-quest asset residency. Walks the quest data tree for
  // every image file, forces Solarus to load+cache it (stable SurfaceImplPtr), marks
  // it immutable, and stages it into the PERMANENT SDRAM region — batching through the
  // DDR3 bounce (drain + reset between batches). On permanent-region exhaustion: loud
  // fatal (no runtime fallback — that absence is what let the heap-reset/transition-
  // reclaim machinery and its scene-too-big fallback be removed entirely).
  void preload_quest_assets() {
    if (preloaded) return;
    preloaded = true;
    if (!ddr) return;   // no fabric (software path) — nothing to stage
    // [format-fix] The upfront preload guesses a single format per surface, but a
    // surface's REAL format is whatever map_blend picks per draw (opaque->RGB565,
    // blended->ARGB4444). ISPIXELFORMAT_ALPHA is a bad predictor (PNGs carry alpha
    // but tiles draw opaque) -> mass cache-miss -> fresh gameplay re-stages -> garbage.
    // SOLARUS_PRELOAD=0 skips the guess and relies on lazy stage-to-perm on first draw
    // (correct format, cached, persistent) — the diagnostic/robust path.
    if (!mister_flag_default_on("SOLARUS_PRELOAD")) return;

    // [#72] Load-progress bar: count PNGs for the denominator, paint 0% now so the
    // scanout shows a clean bar instead of dirty WORK-BRAM garbage during staging.
    loadbar_on     = mister_flag_default_on("SOLARUS_LOADBAR");
    preload_total  = loadbar_on ? count_quest_pngs() : 0;
    preload_staged = 0;
    loadbar_step   = (preload_total > 40u) ? preload_total / 40u : 1u;  // ~40 smooth updates
    paint_loadbar();   // no-op if loadbar_on == false

    blt_begin_frame(&em, target_buf, /*clear=*/0, /*clear_color=*/0x0000);

    // Recursive data-tree walk (iterative; data-relative paths).
    std::vector<std::string> stack{ std::string() };
    while (!stack.empty()) {
      std::string dir = stack.back(); stack.pop_back();
      for (const std::string& name : Solarus::QuestFiles::data_file_list_dir(dir)) {
        std::string path = dir.empty() ? name : dir + "/" + name;
        if (Solarus::QuestFiles::data_file_is_dir(path)) { stack.push_back(path); continue; }
        if (!ends_with_png(path)) continue;

        Solarus::SurfacePtr surf =
            Solarus::Surface::create(path, Solarus::Surface::DIR_DATA);
        if (!surf) continue;                       // not a loadable image; skip
        const SurfaceImpl& impl = surf->get_impl();
        preload_pins.push_back(surf);
        immutable_set.insert(&impl);

        // [ARGB4444-dedup] Stage the SINGLE format the surface is actually blitted with,
        // matching map_blend: a per-pixel-alpha surface (SDL alpha channel) is drawn as
        // BLT_BLEND_PALPHA -> ARGB4444; everything else -> RGB565. Preloading the wrong
        // format is the residency's core bug: the blit then misses the cache and stages a
        // FRESH copy at gameplay into a runaway perm offset -> tile garbage that worsens as
        // more maps' tilesets get re-staged. (HW root-caused: res-emit tex.sdram_off ran
        // past the perm region because tilesets have an alpha channel but were RGB565.)
        SDL_Surface* pss = impl.get_surface();
        uint8_t pfmt = (pss && pss->format && SDL_ISPIXELFORMAT_ALPHA(pss->format->format))
                     ? BLT_FMT_ARGB4444 : BLT_FMT_RGB565;
        preload_stage_one(impl, pfmt);
        ++preload_staged;
        // [#72] advance the bar smoothly (forced repaint every loadbar_step assets),
        // not only at bounce-overflow drains which cluster near the end.
        if (loadbar_on && (preload_staged % loadbar_step) == 0) flush_with_loadbar();
      }
    }
    preload_staged = preload_total;   // [#72] guarantee the bar reads 100% on the last frame
    emit_loadbar_fills();             // into the final open frame -> snapshot shows full bar
    submit_and_drain();   // flush the final batch
    blt_heap_reset(&em);  // reclaim the DDR3 bounce (perm SDRAM allocations persist)
    // [footprint] report perm high-water so we can size the SDRAM region / die-fit.
    uint32_t used = blt_alloc_used(&em.sdram_perm);
    std::fprintf(stderr,
        "[MiSTer blitter] preload complete: perm used %u bytes (%.2f MiB), "
        "base 0x%08x end 0x%08x (die boundary 0x04000000)\n",
        used, used / (1024.0 * 1024.0), SDRAM_PERM_BASE, SDRAM_PERM_BASE + used);
    // [#24] Sibling report for the dedicated bgplane arena, so its headroom is
    // visible alongside perm's on every boot. Reads 0 here -- the whole-quest
    // atlas preload above runs before any map is entered, and bgplane planes
    // are allocated lazily per-map in res_arm_ -- but the base/size printed
    // are the fixed arena bounds regardless, useful for confirming the layout.
    std::fprintf(stderr,
        "[MiSTer blitter] bgplane arena: base 0x%08x size %u bytes (%.1f MiB), "
        "end 0x%08x\n",
        SDRAM_BGPLANE_BASE, SDRAM_BGPLANE_SIZE,
        SDRAM_BGPLANE_SIZE / (1024.0 * 1024.0),
        SDRAM_BGPLANE_BASE + SDRAM_BGPLANE_SIZE);
  }

  // Stage one immutable surface in its SINGLE correct format, draining + resetting the
  // bounce when it fills. `fmt` MUST match how the surface is blitted (map_blend):
  // ARGB4444 for per-pixel-alpha surfaces (SDL alpha channel), RGB565 otherwise. Staging
  // the wrong format here is the residency's core failure mode — the blit then MISSES the
  // cache and stages a FRESH copy at gameplay into a runaway perm offset (garbage).
  void preload_stage_one(const SurfaceImpl& impl, uint8_t fmt) {
    em.overflow = 0;
    (void)upload(impl, fmt);   // convert -> bounce -> stage-perm -> cache (single correct fmt)
    if (em.perm_overflow) {
      Solarus::Debug::die("[residency] permanent SDRAM region exhausted during preload; "
                          "quest asset footprint exceeds the region cap");
    }
    if (em.overflow) {
      // DDR3 bounce full: drain this batch, reset the bounce, retry this asset once.
      em.overflow = 0;
      handles.erase(SurfKey{ &impl, fmt });   // drop the failed cache entry
      emit_loadbar_fills();   // [#72] advance the bar on the drain we're about to submit
      submit_and_drain();
      blt_heap_reset(&em);
      blt_begin_frame(&em, target_buf, /*clear=*/0, /*clear_color=*/0x0000);
      (void)upload(impl, fmt);
      if (em.perm_overflow)
        Solarus::Debug::die("[residency] permanent SDRAM region exhausted during preload");
      if (em.overflow)   // a single asset larger than the whole bounce — cannot happen
        Solarus::Debug::die("[residency] single asset exceeds the DDR3 bounce heap");
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
      if (stage_enabled) {
        // [residency] immutable file assets go to the permanent region; everything
        // else to the recycled intermediate region.
        if (is_immutable(&src)) blt_stage_surface_perm(&em, &r);
        else                    blt_stage_surface(&em, &r);
      }
      handles[kkey] = r;
    }
    return r;
  }

  // [#52 resident] Derive a bucket's shared blend/format/key/flags for the tile-list ABI.
  // Returns false (= this bucket can't be batched; Task 7: caller treats this as a hard
  // failure, not an escape) on a non-batchable blend, a color-mod (tile-list carries no
  // tint) or an un-uploadable tileset.
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

  // [pot diag, DIAGNOSTIC ONLY] Emit one trace line for a small (sprite/tile-sized)
  // draw. `stage` names where in emit_draw this fired: "EMIT" (blit issued, or clipped
  // fully off-screen if onscreen==0), "ESC-blend" (map_blend rejected -> not drawn),
  // "ESC-upload" (atlas upload failed -> not drawn). srcWxH identifies WHICH source
  // image (tileset entities.png vs tiles.png differ in height); sdram_off is the
  // resolved atlas byte base the fabric will actually read from.
  void pot_diag_log(const char* stage, const SurfaceImpl& src, const Rectangle& r,
                    int dst_x, int dst_y, int blend, int fmt, uint16_t key,
                    const blt_surface_ref_t* h, int onscreen) {
    if (!pot_diag) return;
    if (r.get_width() > 32 || r.get_height() > 32) return;   // sprites/tiles only
    if (pot_diag_seen.size() >= POT_DIAG_MAX_LINES) return;
    // signature = source identity + src rect (NOT dst): each distinct source-region
    // logs once, so a static pot is one line and a moving hero doesn't re-spam per pixel.
    const uint64_t sig = ((uint64_t)(uintptr_t)&src)
                       ^ ((uint64_t)(uint32_t)r.get_x() << 40)
                       ^ ((uint64_t)(uint32_t)r.get_y() << 28)
                       ^ ((uint64_t)(uint32_t)r.get_width() << 16)
                       ^ ((uint64_t)(uint32_t)r.get_height());
    if (!pot_diag_seen.insert(sig).second) return;   // already logged this source-region
    std::fprintf(stderr,
        "[pot diag %-10s] src=%p srcWxH=%dx%d srcrect=(%d,%d %dx%d) dst=(%d,%d) "
        "blend=%d fmt=%d key=%04x sdram_off=0x%08x valid=%d onscreen=%d bgplane=%d\n",
        stage, (const void*)&src, src.get_width(), src.get_height(),
        r.get_x(), r.get_y(), r.get_width(), r.get_height(), dst_x, dst_y,
        blend, fmt, (unsigned)key, h ? (unsigned)h->sdram_off : 0u,
        h ? (int)h->valid : 0, onscreen, (int)bgplane_enabled);
  }

  bool emit_draw(const SurfaceImpl& src, const DrawInfos& infos,
                 int off_x, int off_y) {
    ScopedNs _eb(&g_emit_blit_ns, diag);   // [emit drill-down] time the per-blit work
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
      if (pot_diag) { Rectangle edr = infos.dst_rectangle();
        pot_diag_log("ESC-blend", src, infos.region, edr.get_x()+off_x, edr.get_y()+off_y,
                     -1, -1, 0, nullptr, 0); }
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
      if (pot_diag) { Rectangle edr = infos.dst_rectangle();
        pot_diag_log("ESC-upload", src, infos.region, edr.get_x()+off_x, edr.get_y()+off_y,
                     blend, want_fmt, key, &h, 0); }
      return false;
    }
    ensure_frame();
    const Rectangle& r = infos.region;
    Rectangle dr = infos.dst_rectangle();
    // Clip the destination to the framebuffer bounds (the title clouds are drawn
    // off-surface and rely on it). Fully off-screen -> emit nothing, NOT an escape.
    int sx = r.get_x(), sy = r.get_y(), bw = r.get_width(), bh = r.get_height();
    int bdx = dr.get_x() + off_x, bdy = dr.get_y() + off_y;
    const int pre_bdx = bdx, pre_bdy = bdy;   // [pot diag] dst before clip mutates it
    const bool onscreen = clip_to_fb(sx, sy, bw, bh, bdx, bdy, flags);
    // [pot diag] log the resolved blit (source identity + atlas offset + on-screen)
    // BEFORE the early-out, so a fully-clipped pot still shows up as onscreen=0.
    pot_diag_log("EMIT", src, r, pre_bdx, pre_bdy, blend, want_fmt, key, &h, onscreen ? 1 : 0);
    if (!onscreen) return true;
    // colormod rides alongside the clip (post-clip): blt_blit_mod when the flag is
    // set, plain blt_blit otherwise (hot path stays unchanged).
    if (flags & BLT_F_COLORMOD) {
      blt_blit_mod(&em, h, sx, sy, bw, bh, bdx, bdy, blend, key,
                   infos.opacity, flags, cm_r, cm_g, cm_b);
    } else {
      blt_blit(&em, h, sx, sy, bw, bh, bdx, bdy, blend, key, infos.opacity, flags);
    }
    if (diag)
      ps_add((const void*)&src, r.get_x(), r.get_y(), r.get_width(), r.get_height(),
             dr.get_x() + off_x, dr.get_y() + off_y, src.get_width(), src.get_height());
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

// [residency] The live blitter impl, for free functions called from outside the class
// (quest-open preload hook, ~SurfaceImpl forget hook). Set in try_create, cleared in dtor.
static MisterBlitterRenderer::Impl* g_active_impl = nullptr;
void mister_preload_quest_assets() {
  if (g_active_impl) g_active_impl->preload_quest_assets();
}

// [residency] Called from ~SurfaceImpl so the blitter cache never serves a freed-and-
// reused surface address (root cause of the render-corruption stale-pointer bug).
void mister_forget_surface(const Solarus::SurfaceImpl* p) {
  if (!p || !g_active_impl) return;
  g_active_impl->forget_surface(p);
}

// [OSD] See mister_blitter_renderer.h for contract.
bool mister_osd_restart_requested() {
  if (!g_active_impl) return false;
  return g_active_impl->take_restart_edge();
}

void mister_set_fps(double fps) {
  if (g_active_impl) g_active_impl->fps_value = fps;
}

// =====================================================================
MisterBlitterRenderer::MisterBlitterRenderer(SDL_Renderer* renderer, bool shaders)
    : SDLRenderer(renderer, shaders), d(new Impl()) {}

MisterBlitterRenderer::~MisterBlitterRenderer() {
  g_active_impl = nullptr;
  if (d->ddr) ::munmap((void*)d->ddr, BLT_DDR_SIZE);
  if (d->mem_fd >= 0) ::close(d->mem_fd);
  if (d->vid) ::munmap((void*)d->vid, 0x00100000u);
  if (d->vid_fd >= 0) ::close(d->vid_fd);
}

MisterBlitterRenderer* MisterBlitterRenderer::try_create(SDL_Renderer* renderer,
                                                         bool shaders) {
  if (std::getenv("SOLARUS_BLITTER") == nullptr) return nullptr;

  auto* self = new MisterBlitterRenderer(renderer, shaders);
  g_active_impl = self->d.get();   // [residency] live for quest-open preload hook (both return paths below)
  self->d->diag = (std::getenv("SOLARUS_BLITTER_DIAG") != nullptr);
  g_mister_lua_diag = self->d->diag ? 1 : 0;   // [#26] enable Lua-VM timing in LuaTools
  self->d->alias_allow_sw = (std::getenv("SOLARUS_ALIAS_SW") != nullptr);
  self->d->camera_tag = (std::getenv("SOLARUS_NO_CAMERA_TAG") == nullptr);
  self->d->vsync_pace = (std::getenv("SOLARUS_NO_VSYNC") == nullptr);
  self->d->vsync_fastpace = mister_flag_default_on("SOLARUS_FASTPACE");  // [lever-b] HW-validated default ON
  // [single pipeline] The background-composite / scroll-aware cache (SOLARUS_BGCACHE /
  // SOLARUS_SCROLLCACHE) was REMOVED — it diverged the double buffer's blended layers
  // (the ~3-5s overworld flip). The carry-forward path is the sole compositing pipeline.
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
  // [#91] Safe path is the DEFAULT: single-buffer matches the FB-in-BRAM fabric
  // (comp_fbram is one persistent on-chip buffer). Only an explicit
  // SOLARUS_BLITTER_SINGLEBUF=0 opts back into the legacy double-buffer FB->FB
  // carry-forward, which copies the SDRAM FB the fabric no longer writes ->
  // stale-carry garbage. Warn loudly if that diagnostic path is selected.
  {
    const char* sb = std::getenv("SOLARUS_BLITTER_SINGLEBUF");
    self->d->single_buf = !(sb && sb[0] == '0');   // default ON; only "=0" opts out
    if (!self->d->single_buf) {
      std::fprintf(stderr, "[MiSTer blitter] WARNING: SOLARUS_BLITTER_SINGLEBUF=0 "
          "selects the legacy double-buffer FB-copy path, which carries forward "
          "STALE pixels under the FB-in-BRAM fabric (comp_fbram is a single "
          "persistent buffer) -> expect stale-carry garbage. Diagnostic use only.\n");
    }
  }
  self->d->arena_probe = (std::getenv("SOLARUS_ARENA_PROBE") != nullptr);   // [#24] HW SDRAM-arena probe
  self->d->bgw_probe   = (std::getenv("SOLARUS_BGW_PROBE") != nullptr);      // [bgw] HW OP_BGPLANE_WRITE write-path probe
  self->d->bgplane_diag = (std::getenv("SOLARUS_BGPLANE_DIAG") != nullptr); // [#24] per-layer bake diag
  self->d->pot_diag     = (std::getenv("SOLARUS_POT_DIAG") != nullptr);      // [pot] small-draw source trace
  self->d->bgplane_solid = (std::getenv("SOLARUS_BGPLANE_SOLID") != nullptr); // [#24] solid-color debug bake
  self->d->bgplane_copydbg = (std::getenv("SOLARUS_BGPLANE_COPYDBG") != nullptr); // [fork-splitter] COPY-blend plane read
  // [#52 resident, Task 7] Single gate — the resident fabric-resolved tile list is the
  // ONLY animated-tile path when the blitter is live (default OFF).
  self->d->res_enabled = mister_flag_default_on("SOLARUS_TILERESIDENT");  // HW-validated default ON (required for animated tiles)
  if (self->d->res_enabled)
    std::fprintf(stderr, "[MiSTer blitter] resident tile-list ENABLED (fabric TILELIST_RES)\n");
  // [Phase 3b] Background-plane bake (SOLARUS_BGPLANE), opt-in: default OFF until
  // HW-validated, matching every other lever in this campaign at introduction.
  self->d->bgplane_enabled = (std::getenv("SOLARUS_BGPLANE") != nullptr);
  if (self->d->bgplane_enabled)
    std::fprintf(stderr, "[MiSTer blitter] background-plane bake ENABLED (SOLARUS_BGPLANE)\n");
  if (const char* tn = std::getenv("SOLARUS_BLITTER_TRACE_N"))
    self->d->diag_frame_log_max = std::atoi(tn);   // extend per-frame trace window
  // Map the VIDEO framebuffer region unconditionally: the persistence model
  // (flashing fix) carries the previous committed buffer forward into the next
  // target buffer (DDR-to-DDR memcpy) on frames Solarus does NOT clear, so an
  // incrementally-drawn frame stays complete while keeping the tear-free double
  // buffer.
  if (!self->d->map_video()) {
    std::fprintf(stderr, "[MiSTer blitter] video-region map failed; "
                         "carry-forward disabled\n");
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
  blt_sdram_regions_init(&self->d->em, SDRAM_PERM_BASE, SDRAM_PERM_SIZE,
                         SDRAM_INTER_BASE, SDRAM_INTER_SIZE);
  // [#24] Third arena for the per-layer bgplane bake's planes -- disjoint from both
  // regions blt_sdram_regions_init just set up. Plain blt_alloc_init (not a regions_
  // init wrapper) so blt_sdram_regions_init's shared two-region API stays unchanged
  // for other consumers of this engine-agnostic emitter. Same post-memset ordering
  // requirement as the call above (must follow map_ddr()'s blt_emitter_init()).
  blt_alloc_init(&self->d->em.sdram_bgplane, SDRAM_BGPLANE_BASE, SDRAM_BGPLANE_SIZE);
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
    // the current frame (gated to the fabric by tb_blitter_cafill_pipe). The overlay
    // must land on top of the live frame. Opaque (a==255) BLEND fills — the
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
    int ox = alias ? d->alias_off_x : 0, oy = alias ? d->alias_off_y : 0;
    uint8_t r, g, b, a; color.get_components(r, g, b, a);
    uint16_t fill_rgb565 = to_rgb565(r, g, b);
    // [#dungeon diag] Identify the opaque map-background paint fill
    // specifically -- mode==BLEND && a==255, which the comment above already
    // identifies as "the per-frame tileset background fill" (Solarus's
    // Surface::fill_with_color(background_color) mirror, Game::draw).
    // mode==COPY fills also fall through to this same blt_fill call for
    // other purposes and must NOT be recolored/logged as if they were it.
    const bool is_map_bg_fill = (mode == BlendMode::BLEND && a == 255);
    if (is_map_bg_fill && d->bgplane_diag) {
      // [#dungeon diag, DIAGNOSTIC ONLY] SOLARUS_BGPLANE_DIAG=1: log this
      // fill's emit so its position/timing can be correlated against the
      // per-layer plane COPYs (resident_emit_static_layer) -- were they
      // emitted before (correct, behind) or after (bug, drawing on top of
      // the tile layers) this call, this frame?
      std::fprintf(stderr,
          "[bgplane diag PAINTFILL] rgb=(%u,%u,%u) where=%d,%d,%d,%d\n",
          (unsigned)r, (unsigned)g, (unsigned)b,
          where.get_x() + ox, where.get_y() + oy,
          where.get_width(), where.get_height());
    }
    if (is_map_bg_fill && d->bgplane_solid) {
      // [#dungeon diag, DIAGNOSTIC ONLY] SOLARUS_BGPLANE_SOLID=1: recolor
      // ONLY this map-background fill to an unmistakable debug color (bright
      // MAGENTA, RGB565 0xF81F = R31/G0/B31) -- distinct from every bgplane
      // gradient hue (layer0=R, layer1=G, layer2=B channel) and from the
      // dungeon's real teal, so on HW it can only mean "this is the tileset
      // background paint fill, not a layer plane". If magenta covers the
      // tile layers, this fill draws ON TOP of them (a draw-order bug); if
      // it only shows in the gaps behind the tiles, draw order is fine and
      // something else is hiding them.
      fill_rgb565 = 0xF81Fu;
    }
    blt_fill(&d->em, where.get_x() + ox, where.get_y() + oy,
             where.get_width(), where.get_height(), fill_rgb565);
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
  if (d->blitter_off()) {               // pass-through SDLRenderer (no fabric/DDR)
    SDLRenderer::draw(dst, src, infos);
    if (d->diag) {
      d->g_offtarget_draw++;
      // [#52] record the REAL blitted-region size dist in the blitter-off
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

// ── [#52 resident, Task 7] Resident animated-tile list (SOLARUS_TILERESIDENT) ──
// SINGLE fabric-resolved path, no fallback: the non-resident per-frame batched-tile
// virtual (and its engine-side legacy walk) was deleted entirely. Returns the per-frame
// mode: 1 = build (engine walks + resident_record_batch), 2 = fast (engine skips the
// walk; patch ticked patterns + resident_emit_layer). Memoized per frame (res_epoch).
int MisterBlitterRenderer::resident_begin_frame(uintptr_t map_id, uintptr_t tileset_id, int min_layer) {
  // Adopt the camera alias every frame (idempotent), mirroring the animated-tile batch, so the
  // animated-tile batch composites onto the same aliased camera surface.
  if (d->camera_tag && g_tagged_camera && !g_transition_scroll &&
      d->alias_target != g_tagged_camera) {
    d->alias_target = g_tagged_camera;
    d->alias_off_x = 0; d->alias_off_y = 0;
  }
  if (d->res_decided_epoch == d->res_epoch) return d->res_mode;   // memoized this frame
  d->res_decided_epoch = d->res_epoch;
  // 0 = disabled (SOLARUS_TILERESIDENT unset, fabric off, or mid transition-scroll) —
  // the engine's caller treats mode 0 as "nothing to do" (no legacy walk exists anymore).
  if (!d->res_enabled || d->blitter_off() || g_transition_scroll) {
    d->res_building = false; d->res_mode = 0; return 0;
  }
  const bool sig = d->res_valid && d->res_map == map_id && d->res_tileset == tileset_id;
  if (sig) {
    d->res_building = false;
    d->res_mode = 2;                              // [Task 7] fast — no escape-to-legacy gate
    if (d->diag) d->res_noops++;
    // [Phase 3b, Task 6b] Advance the one-time background-plane bake by ONE cell,
    // HERE and nowhere else. resident_begin_frame is the engine's per-frame resident
    // entry point: called at the top of Entities::draw() (before its per-layer content
    // loop) and memoized to run its body exactly once per frame (res_decided_epoch ==
    // res_epoch guard above; res_epoch is bumped once per present(), :2317). So this
    // fires once per FAST frame, BEFORE any real map content is emitted into the frame's
    // command list.
    //
    // WHY THIS SITE IS SNAPSHOT-SAFE (the transient bake content can NEVER be displayed):
    //  - The fabric takes EXACTLY ONE work->scan snapshot per submitted command list,
    //    sequenced AFTER the whole list + OP_END: blitter_top.sv S_SETUP OP_END ->
    //    S_FRAME_VCTRL (:544) / S_FETCH exhaustion (:500), then S_WR_STATUS -> S_SNAP_WAIT
    //    (:828-834) waits for a real vblank (vs_rise) and copies WORK->SCAN. It is NOT a
    //    free-running vblank timer independent of the list, so the snapshot always reflects
    //    WORK's FINAL state after the entire list. (OP_BGPLANE_WRITE only READS work,
    //    S_BGW_WAIT/BUSY :852-853; it never snapshots and never writes work.)
    //  - bake_background_plane_step() appends [OP_TILELIST cell-paint -> OP_BGPLANE_WRITE]
    //    to the frame's ring here, at frame start. Its cell-paint scribbles WORK with
    //    cell-local static tiles (NOT the real picture). Because we run BEFORE the per-layer
    //    loop, this frame's normal full redraw (the resident static ground layer covers the
    //    whole visible framebuffer -- that full static background is the very premise of the
    //    bgplane feature -- plus animated tiles + entities; the overworld also hardware-clears
    //    every frame, clear() :1608) is emitted AFTER the bake in the SAME list and overwrites
    //    every WORK pixel the bake touched before OP_END. The camera is clamped within the map
    //    during FAST mode (resident is disabled mid transition-scroll, :1808), so no beyond-map
    //    pixels are visible. Thus WORK's final state at OP_END is the real frame, and the single
    //    snapshot can only ever capture the real frame -- never the bake scribble.
    // See docs/frame-dataflow.md; this is the #68 failure class (out-of-band composite into
    // the shared on-chip buffer displayed at the wrong point), avoided by ordering.
    if (d->bgplane_enabled) bake_background_plane_step();
    return d->res_mode;
  }
  // New / changed signature: rebuild the resident list THIS frame.
  // [Task 6] min_layer is no longer latched anywhere -- the old single-plane
  // design needed it (bg_base_layer) to know which one layer to bake; the
  // generalized per-layer design (bg_planes) instead derives its layer set
  // directly from res_static_buckets in res_arm_, once every bucket for this
  // build is known. Kept as a parameter (Renderer:: override signature) but
  // unused in this function now.
  (void)min_layer;
  d->res_map = map_id; d->res_tileset = tileset_id;
  d->res_buckets.clear(); d->res_ops.clear();
  d->res_static_buckets.clear(); d->res_static_ops.clear();
  d->res_patterns.clear(); d->res_pat_index.clear();
  d->res_building = true; d->res_valid = false;
  d->res_armed = false; d->res_frt_uploaded = false;
  // res_fatal is a hard-fail latch (a bucket/pattern/TL_BUF limit the resident model
  // can't express). It gates BOTH resident emit paths (res_emit_bucket_/
  // res_emit_static_bucket_ -> `if (res_fatal) return;`), so while set NOTHING resident
  // draws -- only the plain background fill + entities -> a flat, tile-less frame. It must
  // be scoped to the SCENE that tripped it, NOT the whole session: whether a NEW map/
  // tileset can be expressed by the resident model is independent of the previous map's
  // failure. Left latched across a rebuild, one unbatchable map permanently flats every
  // subsequent map until the engine restarts (observed on HW: enter a bad room, then every
  // other room -- castle, house -- stays flat too). Clear it here so a genuinely-bad map
  // re-trips (loud, during its own build walk) but a good map recovers cleanly.
  d->res_fatal = false;
  if (d->diag) d->res_rebuilds++;
  // [Phase 3b, Task 6] A resident rebuild means the map/tileset changed -- every
  // layer's background plane is stale too. Invalidate all of them now (do not
  // erase the map entries yet -- res_arm_ still needs each one's sdram_base/
  // map_w/map_h to free its SDRAM region). The bake itself can NOT (re)start
  // here: this fires BEFORE this frame's build walk populates res_static_buckets/
  // res_buckets (resident_record_static/resident_record_batch, called per layer
  // later in THIS SAME frame), so no layer's pixel bounds are knowable yet. The
  // bake actually (re)starts in res_arm_ -- it runs lazily on the first FAST frame
  // after this build, by which point every bucket is fully populated and stable
  // (no more rebuilds until the next signature change), so that's the first point
  // each layer's bounding box + a fresh SDRAM allocation can be computed correctly.
  if (d->bgplane_enabled) {
    for (auto& kv : d->bg_planes) { kv.second.valid = false; kv.second.baking = false; }
  }
  d->res_mode = 1;
  return 1;
}

// [Phase 3b, Task 6] Advance the background-plane bake by (at most) one real
// cell paint -- exactly the same "one cell per present()" budget as the
// original single-plane design, now shared/sequenced across however many
// layers have static content to bake: this scans bg_planes for the first
// entry still baking (baking == true); a layer whose bake just completed
// (bake_cell_idx has reached its grid's cell count) is flipped to valid
// in-place and the scan continues to the NEXT still-baking layer in the same
// call (so a completed layer never costs a present() call with nothing to
// show for it) -- the actual cell paint + write only happens for the first
// layer found with real work left, and returns immediately after. A layer
// that isn't baking at all (not eligible, already valid, or hasn't been armed
// yet) is skipped outright. Called once per FAST frame from
// resident_begin_frame()'s sig branch
// (Task 6b) -- at frame start, BEFORE Entities::draw()'s per-layer content
// loop, so this frame's full redraw overwrites the transient cell-paint in
// WORK before the fabric's one-per-list snapshot can capture it (full safety
// rationale at that call site). By the time any bg_planes entry has
// baking == true (set in res_arm_, once the whole resident build's buckets are
// known and that layer's plane SDRAM is allocated), res_armed is already true,
// so every b.hw_off/b.hw_count read below is valid without re-arming here.
// Returns true once no layer is (still) baking -- every eligible layer's plane
// is valid, or this map had no baking-eligible layer at all.
// [#24 host bake audit, DIAGNOSTIC ONLY] SOLARUS_BGPLANE_SOLID's per-layer
// ROW-GRADIENT debug color (v2 -- supersedes the flat-color v1). A FLAT color
// can't reveal an intra-layer read offset: a uniform block that's shifted still
// LOOKS uniform. Instead, pack a value derived from the pixel's PLANE row (not
// a flat constant) into a per-layer ARGB4444 channel, so a correct read shows a
// smooth top-to-bottom gradient in that layer's hue, and an offset read shows a
// visible discontinuity/seam at the exact row the bug kicks in -- the color
// value at the seam decodes to the wrong source row (the offset delta).
// f(plane_row) = (plane_row >> 4) & 0xF: steps once per 16 plane-rows, chosen
// because ARGB4444 only HAS a 4-bit channel (pack_argb4444 in
// fbram_to_sdram.sv truncates each channel to its top 4 bits -- r4=bits[15:12],
// g4=bits[10:7], b4=bits[4:1] of the RGB565 word fed to blt_fill). layer 0 ->
// R channel, layer 1 -> G channel, layer 2 -> B channel (cycles via layer%3 for
// any other index); the other two channels stay 0, so hue alone names the
// layer, independent of the gradient value.
static uint16_t bgplane_gradient_rgb565(int channel, uint8_t val4) {
  // Set ONLY the given channel's top 4 bits to val4 (0..15) -- exactly the bits
  // pack_argb4444 keeps; that channel's own LSB (5-bit R/B, 6-bit G fields have
  // one/two more bits than ARGB4444 keeps) is left 0, harmless since it's
  // truncated away on packing. channel: 0=R, 1=G, 2=B.
  uint16_t r5 = 0, g6 = 0, b5 = 0;
  switch (channel) {
    case 0: r5 = (uint16_t)(val4 << 1); break;
    case 1: g6 = (uint16_t)(val4 << 2); break;
    default: b5 = (uint16_t)(val4 << 1); break;
  }
  return (uint16_t)((r5 << 11) | (g6 << 5) | b5);
}
static uint16_t bgplane_gradient_debug_color(int layer, int plane_row) {
  const uint8_t val4 = (uint8_t)(((unsigned)plane_row >> 4) & 0xFu);
  int idx = layer % 3;
  if (idx < 0) idx += 3;
  return bgplane_gradient_rgb565(idx, val4);
}

bool MisterBlitterRenderer::bake_background_plane_step() {
  for (auto& kv : d->bg_planes) {
    Impl::BgPlane& p = kv.second;
    if (!p.baking) continue;
    const int layer = kv.first;
    bgplane_grid_t g = bgplane_grid(p.map_w, p.map_h);
    if (p.bake_cell_idx >= g.count) {
      p.baking = false;
      p.valid = true;
      continue;   // this layer just finished -- another layer may still be
                  // baking (or have real cell work left), so keep scanning
                  // instead of returning early; the aggregate "done" check is
                  // below, after the loop.
    }
    bgplane_cell_t cell = bgplane_cell(p.bake_cell_idx, p.map_w, p.map_h);
    // [#dungeon diag, DIAGNOSTIC ONLY] SOLARUS_BGPLANE_DIAG=1: per-cell bake
    // trace -- how many recorded static entries this layer's paint step
    // iterates, their approximate total placed area, and the EXACT
    // cell-local paint bias (bx/by, the same int16_t-cast values the
    // real-content branch below computes and applies -- directly verifies
    // hypothesis (a), that the bx/by cast isn't truncating for this map,
    // rather than inferring it from bbox size). Logged for EVERY cell (the
    // bake is a one-time, bounded ~grid.count*layers total call count, not a
    // per-frame steady-state flood -- no rate limit needed). Entry/area
    // counts are NOT spatially filtered to this cell: every cell's paint
    // step re-emits the layer's FULL entry list and relies on the fabric to
    // clip/cull whatever doesn't land in this cell's local window (see the
    // per-branch comments below), so these two numbers are the SAME for
    // every cell of a given layer by construction -- only bx/by and the
    // write address (logged after the paint, below) vary per cell.
    if (d->bgplane_diag) {
      int entries_this_layer = 0;
      uint64_t px_this_layer = 0;
      for (const auto& b : d->res_static_buckets) {
        if (b.layer != layer) continue;
        entries_this_layer += b.hw_count;
        for (const auto& e : b.ent) px_this_layer += (uint64_t)e.w * (uint64_t)e.h;
      }
      const int16_t bake_bx = (int16_t)(-(cell.map_x + p.origin_x));
      const int16_t bake_by = (int16_t)(-(cell.map_y + p.origin_y));
      std::fprintf(stderr,
          "[bgplane diag BAKE] layer=%d cell=%d/%d cell.map=%d,%d "
          "entries=%d approx_px=%llu bx=%d by=%d\n",
          layer, p.bake_cell_idx, g.count, cell.map_x, cell.map_y,
          entries_this_layer, (unsigned long long)px_this_layer,
          (int)bake_bx, (int)bake_by);
      // [#dungeon diag, DIAGNOSTIC ONLY] Resource state at the START of this
      // PLANE's bake (cell 0 only, not every cell -- this is a per-plane
      // snapshot, not a per-cell one). TL_BUF is armed ONCE in res_arm_,
      // before any baking starts, and baking only ever REPLAYS already-armed
      // entries (b.hw_off/hw_count) -- it never writes new TL_BUF entries --
      // so tl_used/room should be CONSTANT across all 3 planes' bakes if
      // hypothesis (a) is wrong; if it's right, tl_used at layer0's cell-0
      // would already show near-zero room left (from the two earlier,
      // denser-in-aggregate layers' own TL_BUF entries already having
      // consumed it during THEIR res_arm_ arming, since TL_BUF holds every
      // layer's armed entries simultaneously, not per-plane). Also logs the
      // per-frame COMMAND RING state (cmd_count/ring_cap/overflow) and the
      // DDR3 upload heap (heap_used/heap_cap) -- NEITHER of these is
      // mentioned in the ask, but both are resources bake_background_plane_
      // step's paint step actually consumes live, per cell, unlike TL_BUF:
      // the ring holds this frame's FILL/TILELIST/BGPLANE_WRITE commands
      // (reset every blt_begin_frame, so it can genuinely fill up mid-bake
      // if enough commands are queued this frame), and the real-content
      // branch's d->upload() draws from the heap on a cache miss. Either
      // could silently starve a LATER (in bake order) plane's cell-paint
      // without TL_BUF ever being involved.
      if (p.bake_cell_idx == 0) {
        std::fprintf(stderr,
            "[bgplane diag PLANE-START] layer=%d tl_used=%zu/%zu room=%d "
            "heap_used=%zu/%zu ring_cmd_count=%d ring_cap=%zu overflow=%d\n",
            layer, d->em.tl_used, d->em.tl_cap, resident_room_entries(),
            d->em.heap_used, d->em.heap_cap, d->em.cmd_count, d->em.ring_cap,
            d->em.overflow);
      }
    }
    // Paint this cell's static tiles, offset from map coords to cell-local
    // coords (subtract the cell's map-space origin), reusing the SAME
    // BLT_OP_TILELIST-armed entries resident_record_static/res_arm_ already
    // wrote to TL_BUF -- only the per-bucket bias changes (cell-local instead
    // of camera-relative).
    d->ensure_frame();
    // [#dungeon diag, DIAGNOSTIC ONLY] Actual-emitted-work counters, distinct
    // from the "recorded" entries/approx_px the BAKE trace above already
    // logged: THOSE come straight from res_static_buckets (what's on record,
    // unconditionally); THESE count what this cell's paint step actually
    // iterated and emitted into the ring, catching a bucket the real-content
    // branch's `if (!tex.valid) continue;` silently drops (a heap-upload
    // failure -- a REAL gate that only exists in that branch, hypothesis (c)
    // in the ask) that the recorded count alone can't see. Cheap arithmetic
    // (a handful of adds over ~48 total bake calls), computed unconditionally
    // so the branches below don't need extra `if (d->bgplane_diag)` gating
    // scattered through their loops; only the fprintf after is gated.
    int tiles_emitted = 0;
    uint64_t paint_px_emitted = 0;
    int upload_fail_buckets = 0;
    if (d->bgplane_solid) {
      // [#24 host bake audit, DIAGNOSTIC ONLY] SOLARUS_BGPLANE_SOLID=1 (v2 --
      // row-gradient, supersedes v1's flat per-tile color). Paint ONLY each
      // real static tile's OWN destination rectangle -- preserving the REAL
      // per-tile coverage FOOTPRINT exactly like v1 (gaps stay uncovered so
      // lower layers show through) -- but instead of one flat fill per entry,
      // emit ONE 1-row-tall fill PER PLANE ROW the entry spans, each colored
      // by bgplane_gradient_debug_color(layer, plane_row). A flat color can't
      // reveal an intra-layer read offset (a shifted uniform block still
      // looks uniform); the gradient makes a wrong-row read visible as a
      // discontinuity/seam whose color decodes the offset, and the seam's
      // CHANNEL/hue would show cross-layer contamination.
      // This is still tile-RECTANGLE-granular, not per-source-pixel: a tile
      // with internal colorkey holes still fills its whole bounding rect
      // (small, localized over-coverage for such tiles only) -- same
      // disclosed, accepted imprecision as v1.
      blt_fill_flags(&d->em, 0, 0, FB_W, FB_H, 0, BLT_F_BGCOV);   // clear coverage, same as real bake
      for (size_t bi = 0; bi < d->res_static_buckets.size(); ++bi) {
        const Impl::StaticBucket& b = d->res_static_buckets[bi];
        if (b.layer != layer) continue;
        for (const auto& e : b.ent) {
          ++tiles_emitted;                                   // [#dungeon diag] no upload gate in this branch -- always emitted
          paint_px_emitted += (uint64_t)e.w * (uint64_t)e.h;  // [#dungeon diag]
          // Same map-coord -> cell-local bias the real branch's bx/by apply
          // (bx = -(cell.map_x + p.origin_x)), just added directly here since
          // blt_fill takes absolute cell-local coords, not a fabric-applied
          // per-batch bias like blt_tile_list_static's bx/by. blt_fill clips/
          // culls to the cell's FB_W x FB_H bounds itself, so a row straddling
          // or outside this cell needs no extra host-side check.
          const int fill_x   = (int)e.dx - (cell.map_x + p.origin_x);
          const int cell_y0  = (int)e.dy - (cell.map_y + p.origin_y);
          // plane_row: the entry's row position in the WHOLE plane's own
          // [0,padded_h) space (not just this cell) -- the true map row
          // (e.dy) shifted by the plane's origin, same convention every other
          // plane-space coordinate in this file uses. Independent of `cell`
          // (an entry's plane row never depends on which cell is currently
          // baking it), so the gradient is continuous across cell boundaries.
          const int plane_row0 = (int)e.dy - p.origin_y;
          for (int r = 0; r < (int)e.h; ++r) {
            blt_fill(&d->em, fill_x, cell_y0 + r, e.w, 1,
                     bgplane_gradient_debug_color(layer, plane_row0 + r));
          }
        }
      }
    } else {
      // Clear WORK before painting this cell's static tiles: any plane pixel not
      // covered by an opaque tile (a transparent gap, or space outside the tile
      // footprint) must bake as transparent, not whatever the previous command
      // list happened to leave in WORK. Transient: overwritten by this frame's
      // real drawing later in the same list, before OP_END/the snapshot (same
      // safety argument as the cell-paint itself, see the call site above).
      //
      // [ARGB4444 plane bake] clear-color is irrelevant now -- BLT_F_BGCOV makes this
      // FILL's own pixel-write loop clear the bake-coverage tracker (bgplane_coverage.sv)
      // instead of painting a background-color fill. Any tile subsequently painted this
      // cell sets its own covered pixels' coverage back to 1; anything left untouched
      // stays 0 (transparent) when OP_BGPLANE_WRITE packs this cell as ARGB4444 below.
      // NonAnimatedRegions::record_static only ever records explicit placed tiles, so a
      // solid-color "floor" the map never bothered to tile over now correctly bakes as
      // alpha=0 -- the plane's later PALPHA COPY leaves it untouched instead of
      // permanently replacing it with black, which is exactly the fix for map 119's
      // parallax layers (no more spurious opaque coverage of whatever's underneath).
      //
      // [MiSTer #102] Zero WORK's RGB before the coverage-clear + tile paint. The
      // BLT_F_BGCOV fill just below is coverage-ONLY: per bgplane_coverage.sv it
      // routes its per-pixel writes to the coverage tracker (clearing it) INSTEAD
      // of comp_fbram, so on its own it leaves WORK's RGB holding the PREVIOUS
      // scene's pixels. comp_fbram WORK persists across scene rebuilds, so those
      // stale pixels bake into every un-repainted gap on a map transition -- the
      // #84 residual "stale WORK" symptom (impl-rtl tb_bgplane_maptrans Scenario 2
      // reproduces it as prior-scene=36; Scenario 3 proves a clear-before-tiles
      // bakes CLEAN 0). The fabric's cure is a full-screen opaque FILL through
      // comp_pipeline that visits every cell pixel and writes comp_fbram WORK RGB
      // (equivalently a CLEAR-flagged submit); emit it in-list here, BEFORE the
      // coverage-clear and the tiles. It also SETS coverage=1 everywhere, but the
      // BGCOV fill immediately after resets coverage to 0 -- so ARGB4444 alpha
      // semantics are unchanged (un-covered gaps still bake alpha=0/transparent);
      // this only removes the RGB staleness. Order is load-bearing: RGB clear
      // FIRST, then the BGCOV coverage-clear.
      blt_fill(&d->em, 0, 0, FB_W, FB_H, /*clear_color=*/0x0000);
      blt_fill_flags(&d->em, 0, 0, FB_W, FB_H, 0, BLT_F_BGCOV);
      for (size_t bi = 0; bi < d->res_static_buckets.size(); ++bi) {
        const Impl::StaticBucket& b = d->res_static_buckets[bi];
        if (b.hw_count == 0) continue;
        // [Task 6] Only bake THIS layer's buckets -- this plane covers this one
        // layer alone (see res_arm_/compute_bgplane_bounds, called once per
        // distinct layer present in res_static_buckets). A bucket from any other
        // layer would have been ignored when sizing THIS plane, so painting it
        // here would write out of the allocated plane's bounds; skip it instead
        // (it gets baked into its OWN layer's plane, on that plane's turn).
        if (b.layer != layer) continue;
        // [FLOOR/POT DIAG, DIAGNOSTIC ONLY] SOLARUS_BGPLANE_DIAG=1: census the
        // ACTUAL source alpha of this layer's baked tiles, once per bake (first
        // cell only). Resolves the last fork in the "bgplane static plane bakes
        // empty" investigation: is this layer's floor bucket opaque COPY,
        // COLORKEY, or PALPHA with PARTIAL alpha? The proven partial-alpha bake
        // bug (tb_bgplane_equivalence PALPHA[1] FAIL: alpha in (0,255) packs
        // fully-opaque toward black) only bites tiles whose source alpha is
        // mid-valued -- binary alpha (0/255) and colorkey both bake correctly.
        // blend/fmt alone can't tell binary-PALPHA from partial-PALPHA, so scan
        // the real tile pixels this bucket references.
        if (d->bgplane_diag && p.bake_cell_idx == 0) {
          uint64_t n_zero = 0, n_full = 0, n_partial = 0;
          uint8_t amin = 255, amax = 0;
          SDL_Surface* ss = b.tsimg ? b.tsimg->get_surface() : nullptr;
          SDL_Surface* c  = ss ? SDL_ConvertSurfaceFormat(ss, SDL_PIXELFORMAT_ARGB8888, 0) : nullptr;
          if (c) {
            SDL_LockSurface(c);
            const uint8_t* base = static_cast<const uint8_t*>(c->pixels);
            for (const auto& e : b.ent) {
              for (int yy = 0; yy < (int)e.h; ++yy) {
                int py = (int)e.sy + yy;
                if (py < 0 || py >= c->h) continue;
                const uint32_t* row =
                    reinterpret_cast<const uint32_t*>(base + (size_t)py * c->pitch);
                for (int xx = 0; xx < (int)e.w; ++xx) {
                  int px = (int)e.sx + xx;
                  if (px < 0 || px >= c->w) continue;
                  uint8_t a, r, g, bb;
                  SDL_GetRGBA(row[px], c->format, &r, &g, &bb, &a);
                  if (a == 0) ++n_zero; else if (a == 255) ++n_full; else ++n_partial;
                  if (a < amin) amin = a;
                  if (a > amax) amax = a;
                }
              }
            }
            SDL_UnlockSurface(c);
            SDL_FreeSurface(c);
          }
          std::fprintf(stderr,
              "[bgplane diag BUCKET-ALPHA] layer=%d bucket=%zu blend=%u fmt=%u "
              "key=%04x flags=%u tiles=%d a0=%llu a255=%llu apartial=%llu "
              "amin=%u amax=%u%s\n",
              layer, bi, (unsigned)b.blend, (unsigned)b.fmt, (unsigned)b.key,
              (unsigned)b.flags, b.hw_count,
              (unsigned long long)n_zero, (unsigned long long)n_full,
              (unsigned long long)n_partial, (unsigned)amin, (unsigned)amax,
              n_partial ? "  <<< PARTIAL-ALPHA (proven bake bug)" : "");
        }
        blt_surface_ref_t tex = d->upload(*b.tsimg, b.fmt);
        if (!tex.valid) {
          ++upload_fail_buckets;   // [#dungeon diag] the silent-drop gate hypothesis (c) targets
          continue;
        }
        // [#dungeon diag] tiles_emitted counts TILES, not buckets, to match
        // the solid branch's per-entry granularity -- one blt_tile_list_static
        // call below covers b.hw_count tiles at once.
        tiles_emitted += b.hw_count;
        for (const auto& e : b.ent) paint_px_emitted += (uint64_t)e.w * (uint64_t)e.h;  // [#dungeon diag]
        // cell.map_x/map_y are in this plane's own [0,mw)x[0,mh) space
        // (bgplane_geom.h), but recorded entry dx/dy are TRUE map coords, which
        // may be offset from that space by p.origin_x/y (see the bounds
        // computation in res_arm_). Shift by the origin first (map coord ->
        // plane coord), then by the cell (plane coord -> cell-local coord),
        // mirroring res_emit_bucket_'s camera-relative bias convention (bx = -cx
        // there; bx = -(cell.map_x + p.origin_x) here).
        int16_t bx = (int16_t)(-(cell.map_x + p.origin_x));
        int16_t by = (int16_t)(-(cell.map_y + p.origin_y));
        blt_tile_list_static(&d->em, tex, b.blend, b.key, /*alpha=*/255, b.flags,
                              b.hw_off, b.hw_count, bx, by);
      }
    }
    // [#dungeon diag, DIAGNOSTIC ONLY] SOLARUS_BGPLANE_DIAG=1: what this
    // cell's paint step ACTUALLY emitted (tiles_emitted/paint_px_emitted,
    // upload_fail_buckets -- hypothesis (c), the tex.valid gate), plus the
    // command RING state right AFTER painting (cmd_count/ring_cap/overflow)
    // -- if the ring overflowed DURING this cell's paint, e->overflow flips
    // here and every command queued after the overflow point this frame,
    // including this cell's own upcoming OP_BGPLANE_WRITE below, is silently
    // dropped by the emitter (hypothesis (a)/(c) combined: not a TL_BUF/
    // recording problem, a per-frame ring-capacity problem). Logged for
    // every cell (bounded, one-time bake).
    if (d->bgplane_diag) {
      std::fprintf(stderr,
          "[bgplane diag PAINT] layer=%d cell=%d/%d tiles_emitted=%d "
          "paint_px=%llu upload_fail_buckets=%d ring_cmd_count=%d "
          "ring_cap=%zu overflow=%d\n",
          layer, p.bake_cell_idx, g.count, tiles_emitted,
          (unsigned long long)paint_px_emitted, upload_fail_buckets,
          d->em.cmd_count, d->em.ring_cap, d->em.overflow);
    }
    uint32_t cell_off = bgplane_cell_plane_byte_offset(p.bake_cell_idx, p.map_w, p.map_h);
    uint32_t qw_off    = (p.sdram_base + cell_off) / 8;
    uint32_t stride_qw = bgplane_row_stride_qw(p.map_w);
    // [#dungeon diag, DIAGNOSTIC ONLY] SOLARUS_BGPLANE_DIAG=1: the write
    // address OP_BGPLANE_WRITE actually targets for this cell -- cross-
    // reference byte_addr against the EMIT-side read address logged in
    // resident_emit_static_layer (bgplane diag EMIT) for the same layer at
    // whatever camera position is on-screen: do the WRITE cell that should
    // cover a given plane region and the READ that later asks for that same
    // region compute the SAME byte address? (E.g. for the lead's sample
    // read at plane (696,528): byte_addr = sdram_base + 528*stride_bytes +
    // 696*2 -- this cell's byte_addr should equal that exact value for
    // whichever cell_off/cell.map_x,y bracket (696,528).)
    if (d->bgplane_diag) {
      std::fprintf(stderr,
          "[bgplane diag BAKE-WRITE] layer=%d cell=%d/%d qw_off=0x%08x "
          "byte_addr=0x%08x cell_off=%u stride_qw=%u sdram_base=0x%08x\n",
          layer, p.bake_cell_idx, g.count, qw_off,
          p.sdram_base + cell_off, cell_off, stride_qw, p.sdram_base);
    }
    int bgw_rc = blt_bgplane_write_cell(&d->em, qw_off, stride_qw, BLT_F_BGCOV);
    if (bgw_rc != 0 || d->em.overflow) {
      // [MiSTer #109] Ring overflow this frame dropped this cell's
      // OP_BGPLANE_WRITE (or the paint commands before it), so the plane region
      // this cell should cover stays UNINITIALIZED in SDRAM -> stale/garbage on
      // read-back. Loud + always-on (a data-correctness fault, not a diagnostic):
      // the prior warning existed only under SOLARUS_BGPLANE_DIAG. Normally we
      // leave bake_cell_idx un-advanced so the incomplete cell is re-attempted on
      // the next bake step once the ring is empty again (blt_begin_frame clears
      // it every frame).
      //
      // [MiSTer #109 hardening] But if the SAME cell overflows a FRESH ring for
      // BAKE_CELL_MAX_RETRIES consecutive frames, it cannot fit at all -- an
      // un-advancing retry would stall this plane's bake forever (silent but for
      // this warning). Escalate to a loud hard-fail and ADVANCE past the one bad
      // cell so the rest of the plane still bakes (fail loud + bounded, not an
      // infinite silent stall).
      static const int BAKE_CELL_MAX_RETRIES = 8;
      if (++p.bake_cell_retries > BAKE_CELL_MAX_RETRIES) {
        std::fprintf(stderr,
            "[MiSTer bgplane] FATAL: layer=%d cell=%d/%d overflows the command "
            "ring on %d consecutive fresh-ring attempts (ring_cap=%zu) -- cell "
            "too large to bake; SKIPPING it (this plane region stays "
            "uninitialized) to avoid an infinite bake stall\n",
            layer, p.bake_cell_idx, g.count, BAKE_CELL_MAX_RETRIES,
            d->em.ring_cap);
        p.bake_cell_retries = 0;
        p.bake_cell_idx++;   // give up on this one cell; continue the rest
        return false;
      }
      std::fprintf(stderr,
          "[MiSTer bgplane] WARNING: OP_BGPLANE_WRITE dropped (ring overflow, "
          "rc=%d overflow=%d) layer=%d cell=%d/%d qw_off=0x%08x attempt=%d/%d -- "
          "plane region uninitialized; bake incomplete this pass, will retry\n",
          bgw_rc, d->em.overflow, layer, p.bake_cell_idx, g.count, qw_off,
          p.bake_cell_retries, BAKE_CELL_MAX_RETRIES);
      return false;
    }
    p.bake_cell_retries = 0;   // [MiSTer #109] this cell committed; reset the budget
    p.bake_cell_idx++;
    return false;
  }
  // No layer had a real cell left to paint this call -- either none was ever
  // eligible, or every layer that WAS baking just finished above (flipped to
  // valid in this same call, via the `continue` path). Only report "done"
  // once EVERY known layer's plane is actually valid; a layer that's neither
  // baking nor valid (invalidated by a rebuild in resident_begin_frame, not
  // yet re-armed) must still read as not-done.
  for (const auto& kv : d->bg_planes) if (!kv.second.valid) return false;
  return true;
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
  // [#52 camera-independent, Task 7] The fabric (FRT/CFT) is the SOLE resident src path:
  // it resolves each entry's src from FRT[pid][CFT[pid]]; the A9 only writes the
  // per-pattern current frame. Capture the frame rects (for FRT, written at arm) + the
  // current frame, and write CFT[slot] to DDR each frame. There is no in-place src-patch
  // path — the 8-byte biased map-coord entries have no patchable src field.
  if (!d->res_armed) {
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
    // [Task 7: no fallback] An unbatchable bucket (a blend/tex the tile-list ABI can't
    // express, or an un-uploadable tileset) is a BUG in the resident model, not a
    // degrade path: surface it loudly and stop recording this bucket. No per-entry
    // immediate draw, no scene-wide escape-to-legacy (there is no legacy).
    d->res_fatal = true;
    std::fprintf(stderr,
        "[blitter resident] FATAL: unbatchable bucket (blend/tex) in resident build "
        "(layer=%d scroll_ratio=%d n=%zu)\n", layer, scroll_ratio, entries.size());
    return;
  }
  d->ensure_frame();
  Impl::ResBucket bk{ &tileset_image, bl, fl, fmt, key, layer, scroll_ratio,
                      /*hw_off=*/0, /*hw_count=*/0, {} };
  for (size_t i = 0; i < entries.size(); ++i) {
    const uintptr_t tok = (i < tokens.size()) ? tokens[i] : 0;
    if (!tok) continue;                          // unbatchable / no pattern identity
    auto it = d->res_pat_index.find(tok);
    size_t pi;
    if (it == d->res_pat_index.end()) {
      pi = d->res_patterns.size();
      if (pi >= (size_t)BLT_MAXP) {
        // [Task 7: no fallback] More distinct animated patterns than the fabric's FRT
        // table has slots for. This used to demote the scene to Tier A (engine src-patch);
        // that tier is gone, so it's now a hard failure.
        d->res_fatal = true;
        std::fprintf(stderr,
            "[blitter resident] FATAL: pattern-table overflow (%zu >= BLT_MAXP=%d)\n",
            pi, BLT_MAXP);
        return;
      }
      d->res_pat_index[tok] = pi;
      Impl::ResPattern rp; rp.token = tok;
      d->res_patterns.push_back(std::move(rp));
    } else pi = it->second;
    // Record the (pattern_id, MAP-coord dst) for this entry's 8-byte resident form. The
    // fabric adds this bucket's camera bias per frame (res_emit_bucket_), so the stored
    // dst stays camera-independent — a camera move never rebuilds the list.
    const auto& e = entries[i];
    bk.hw.push_back({ (uint16_t)pi, (int16_t)e.dst.x, (int16_t)e.dst.y });
  }
  d->res_buckets.push_back(std::move(bk));
  d->res_ops.push_back({(uint32_t)(d->res_buckets.size() - 1), layer});
  d->alias_drawn_this_frame = true;
  if (d->diag) d->g_alias_blits += (long)entries.size();
}

// [static tile-list] Record one non-animated bucket for the direct BLT_OP_TILELIST path
// (12-byte entries, no FRT/pattern indirection). Parallel to resident_record_batch.
void MisterBlitterRenderer::resident_record_static(int layer, int scroll_ratio,
        const SurfaceImpl& tileset_image, BlendMode blend,
        const std::vector<TileBatchEntry>& entries) {
  d->mark_render();
  if (!d->res_building || entries.empty()) return;
  blt_surface_ref_t tex; uint8_t bl, fl, fmt; uint16_t key;
  if (!d->res_bucket_params(tileset_image, blend, tex, bl, key, fl, fmt)) {
    d->res_fatal = true;
    std::fprintf(stderr,
        "[blitter resident] FATAL: unbatchable STATIC bucket (blend/tex) layer=%d n=%zu\n",
        layer, entries.size());
    return;
  }
  d->ensure_frame();
  Impl::StaticBucket bk{ &tileset_image, bl, fl, fmt, key, layer, scroll_ratio, 0u, 0, {} };
  bk.ent.reserve(entries.size());
  for (const auto& e : entries)
    bk.ent.push_back({ (uint16_t)e.src.get_x(), (uint16_t)e.src.get_y(),
                       (uint16_t)e.src.get_width(), (uint16_t)e.src.get_height(),
                       (int16_t)e.dst.x, (int16_t)e.dst.y });
  d->res_static_buckets.push_back(std::move(bk));
  d->res_static_ops.push_back({(uint32_t)(d->res_static_buckets.size() - 1), layer});
  d->alias_drawn_this_frame = true;
  if (d->diag) d->g_alias_blits += (long)entries.size();
}

// [Task 7: no fallback] A tile that can't batch (repeated/fill: tile size > pattern size,
// or a parallax pattern whose get_draw_region failed) used to be recorded as an ordered
// escape op, replayed via tile.draw() on the fast path (a per-tile oracle). That mechanism
// is removed: hitting this during a resident build is now a loud hard failure — the engine
// caller still draws the tile directly (this frame only) so the screen isn't silently
// missing content, but the resident model considers it a bug to fix, not a path to keep.
void MisterBlitterRenderer::resident_escape(int layer, uintptr_t tile) {
  if (!d->res_building || !tile) return;
  d->res_fatal = true;
  std::fprintf(stderr,
      "[blitter resident] FATAL: non-batchable tile escaped resident build (layer=%d)\n",
      layer);
}

// [#52 resident, Task 7] Arm the fabric resident path once per scene (first fast frame):
// write the frame-rect table (FRT) + the 8-byte resident entries to DDR. CFT is written per
// frame in resident_update. FRT/8-byte entries persist across fast frames (TL_BUF untouched).
// [Task 7] Whole-map TL_BUF overflow is a hard failure here, not a degrade: if the total
// entry count across every recorded bucket doesn't fit TL_BUF, set res_fatal + a loud
// fprintf and DO NOT write a partial/corrupt table.
void MisterBlitterRenderer::res_arm_() {
  size_t res_bytes  = 0;
  for (const auto& b : d->res_buckets)        res_bytes  += b.hw.size()  * sizeof(blt_tile_entry_res_t);
  size_t stat_bytes = 0;
  for (const auto& b : d->res_static_buckets) stat_bytes += b.ent.size() * sizeof(blt_tile_entry_t);
  if (res_bytes + stat_bytes > d->em.tl_cap) {
    d->res_fatal = true;
    std::fprintf(stderr,
        "[blitter resident] TL_BUF OVERFLOW: need %zu (res %zu + static %zu) > cap %zu bytes\n",
        res_bytes + stat_bytes, res_bytes, stat_bytes, d->em.tl_cap);
    d->res_armed = true;
    return;
  }
  // FRT: FRT[slot*MAXF + f] = {src_x, src_y, w, h} (LE), one qword each.  (UNCHANGED)
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
  uint32_t cur = 0;
  // 8-byte RES entries first (UNCHANGED layout).
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
  // 12-byte static entries appended after; record per-bucket byte offset/count.
  for (auto& b : d->res_static_buckets) {
    b.hw_off = cur; b.hw_count = (int)b.ent.size();
    for (const auto& e : b.ent) {
      volatile uint8_t* p = d->ddr + OFF_TLBUF + cur;
      p[0]=(uint8_t)e.sx; p[1]=(uint8_t)(e.sx>>8);
      p[2]=(uint8_t)e.sy; p[3]=(uint8_t)(e.sy>>8);
      p[4]=(uint8_t)e.w;  p[5]=(uint8_t)(e.w>>8);
      p[6]=(uint8_t)e.h;  p[7]=(uint8_t)(e.h>>8);
      p[8]=(uint8_t)e.dx; p[9]=(uint8_t)((uint16_t)e.dx>>8);
      p[10]=(uint8_t)e.dy;p[11]=(uint8_t)((uint16_t)e.dy>>8);
      cur += 12;
    }
  }
  // [Phase 3b, generalized Task 6] This is the first point in the resident-build
  // lifecycle where res_static_buckets/res_buckets/res_patterns are FULLY
  // populated for the new scene AND stable (res_arm_ itself only runs once per
  // rebuild, gated by its callers checking res_armed -- see
  // resident_begin_frame's rebuild branch, where every existing bg_planes
  // entry's valid/baking were invalidated but the bake couldn't start yet
  // because this data didn't exist). Compute a per-LAYER pixel bounding box
  // from every recorded static-tile entry's map-coord dst + its w/h, for every
  // distinct layer that has any recorded static content, then allocate a fresh
  // permanent SDRAM region per layer sized for that layer's own bounding box
  // and start that layer's cell-by-cell bake. [Task 6] No single hardcoded
  // base layer anymore: every layer with static content gets its own plane.
  if (d->bgplane_enabled) {
    // Free every existing plane's SDRAM region before computing this map's
    // per-layer bounds -- res_arm_ runs once per rebuild, so any bg_planes
    // entries still name the map we're replacing. Without this, every map
    // transition leaked another map-sized region per layer out of the finite
    // sdram_bgplane pool. [#24] This arena is dedicated to bgplane planes
    // (SDRAM_BGPLANE_BASE/SIZE, disjoint from sdram_perm's whole-quest atlas)
    // so a large map's atlas footprint can no longer starve the bake.
    for (auto& kv : d->bg_planes) {
      Impl::BgPlane& p = kv.second;
      if (p.sdram_allocated) {
        blt_free(&d->em.sdram_bgplane, p.sdram_base, bgplane_total_bytes(p.map_w, p.map_h));
        p.sdram_allocated = false;
      }
    }
    d->bg_planes.clear();
    // [Task 6] Collect the distinct set of layers present in res_static_buckets
    // -- these are exactly the layers eligible for a plane bake (a layer with
    // zero recorded static content has nothing to bake and always falls back
    // to the per-bucket path, same as if BGPLANE were off for it).
    std::unordered_set<int> layers_present;
    for (const auto& b : d->res_static_buckets) layers_present.insert(b.layer);
    // Animated-bucket extents (res_buckets) never contribute to any layer's
    // bounds: animated tiles are never baked into a plane regardless of layer,
    // so folding their extent into a bounding box only risked over-sizing it
    // for no benefit. See
    // docs/superpowers/specs/2026-07-08-bgplane-base-layer-occlusion-design.md.
    std::vector<bgplane_tile_extent_t> extents;
    extents.reserve(d->res_static_buckets.size());
    for (const auto& b : d->res_static_buckets)
      for (const auto& e : b.ent)
        extents.push_back({b.layer, (int)e.dx, (int)e.dy, (int)e.w, (int)e.h});
    // [Task 6] The old scroll_ratio != 1 disqualification (a parallax pattern
    // sharing the base layer with static ground tiles used to disable the
    // WHOLE map's bake, because the single opaque-COPY design couldn't safely
    // order an opaque full-layer overwrite against a parallax backdrop that
    // must show through gaps) no longer applies to ANY layer: the ARGB4444
    // bake + BLT_BLEND_PALPHA readback (Task 1-5) gives every plane real
    // per-pixel transparency, so its COPY is safe to fire wherever the
    // per-bucket path already fires (after animated ops) on every layer,
    // parallax-sharing or not. No per-layer or per-map disqualification
    // remains -- every layer with static content gets a plane.
    for (int layer : layers_present) {
      bgplane_bounds_t bounds =
          compute_bgplane_bounds(extents.data(), (int)extents.size(), layer);
      if (!(bounds.any && bounds.mw > 0 && bounds.mh > 0)) continue;
      uint32_t need = bgplane_total_bytes(bounds.mw, bounds.mh);
      uint32_t off = blt_alloc(&d->em.sdram_bgplane, need);
      if (off == BLT_ALLOC_FAIL) {
        std::fprintf(stderr,
            "[blitter bgplane] FATAL: bgplane SDRAM arena exhausted allocating %u "
            "bytes for layer %d's %dx%d background plane -- that layer falls back "
            "to per-bucket replay, every other layer unaffected\n",
            need, layer, bounds.mw, bounds.mh);
        continue;   // no bg_planes[layer] entry -> resident_emit_static_layer
                    // falls back to per-bucket replay for this layer only
      }
      Impl::BgPlane& p = d->bg_planes[layer];
      p.map_w = bounds.mw; p.map_h = bounds.mh;
      p.origin_x = bounds.min_x; p.origin_y = bounds.min_y;
      p.sdram_base = off;
      p.sdram_allocated = true;
      p.bake_cell_idx = 0;
      p.bake_cell_retries = 0;   // [#109] fresh bake -> reset the per-cell retry budget
      p.baking = true;
      p.valid = false;
      if (bounds.min_x != 0 || bounds.min_y != 0) {
        std::fprintf(stderr,
            "[blitter bgplane] layer %d content extends into negative map-coord "
            "space (origin=%d,%d) -- compensated in the plane's internal "
            "coordinate space\n", layer, bounds.min_x, bounds.min_y);
      }
      // [#24 host bake audit, DIAGNOSTIC ONLY] SOLARUS_BGPLANE_DIAG=1: log this
      // layer's write-side geometry + arena placement right after it's finalized,
      // and log-and-continue-assert the two static invariants checkable here (the
      // fabric bake path is proven bit-exact at arena bases -- see
      // .superpowers/sdd/task-24-host-bake-audit.md -- so a violation here would
      // be a genuinely new finding, not the expected #24 symptom). Assert #1
      // (write/read stride agreement) lives in resident_emit_static_layer, where
      // plane_ref.stride is actually computed; assert #3 (pairwise plane overlap)
      // runs once after this whole loop, below, once every layer's plane for this
      // rebuild is known.
      if (d->bgplane_diag) {
        const int padded_w = bgplane_padded_w(p.map_w);
        bgplane_grid_t g = bgplane_grid(p.map_w, p.map_h);
        std::fprintf(stderr,
            "[bgplane diag ARM] layer=%d map=%dx%d padded_w=%d stride_qw=%u "
            "sdram_base=0x%08x total=%u grid.count=%d origin=%d,%d\n",
            layer, p.map_w, p.map_h, padded_w, bgplane_row_stride_qw(p.map_w),
            p.sdram_base, need, g.count, p.origin_x, p.origin_y);
        // Assert #2: the plane's [sdram_base, sdram_base+need) must land fully
        // inside the dedicated arena (log-and-continue -- never abort gameplay).
        if (!(p.sdram_base >= SDRAM_BGPLANE_BASE &&
              (uint64_t)p.sdram_base + need <= (uint64_t)SDRAM_BGPLANE_BASE + SDRAM_BGPLANE_SIZE)) {
          std::fprintf(stderr,
              "[bgplane diag ARM] ASSERT FAIL: layer=%d plane [0x%08x,0x%08x) "
              "escapes the arena [0x%08x,0x%08x)\n",
              layer, p.sdram_base, p.sdram_base + need,
              SDRAM_BGPLANE_BASE, SDRAM_BGPLANE_BASE + SDRAM_BGPLANE_SIZE);
        }
        // Assert #4: the two latent truncations the static audit flagged (only
        // ever expected to fire on a map far wider than any real quest content).
        if (!(padded_w * 2 <= 0xFFFF)) {
          std::fprintf(stderr,
              "[bgplane diag ARM] ASSERT FAIL: layer=%d padded_w*2=%d exceeds "
              "uint16_t plane_ref.stride range\n", layer, padded_w * 2);
        }
        if (!(p.origin_x >= -32768 && p.origin_x <= 32767 &&
              p.origin_y >= -32768 && p.origin_y <= 32767)) {
          std::fprintf(stderr,
              "[bgplane diag ARM] ASSERT FAIL: layer=%d origin=%d,%d out of "
              "int16_t range (cell-paint bias truncates)\n",
              layer, p.origin_x, p.origin_y);
        }
      }
    }
    // [#24 host bake audit, DIAGNOSTIC ONLY] Assert #3: once every layer's plane
    // for this rebuild is known, no two live planes' SDRAM byte ranges may
    // overlap -- the exact condition the old sdram_perm arena masked by only
    // ever fitting 1 of 3 planes (two planes were never simultaneously live to
    // collide). Now that all 3 co-reside, a wrong `need`/`sdram_base` pairing
    // would show up here as an overlap.
    if (d->bgplane_diag) {
      for (auto ia = d->bg_planes.begin(); ia != d->bg_planes.end(); ++ia) {
        if (!ia->second.sdram_allocated) continue;
        const uint32_t a0 = ia->second.sdram_base;
        const uint32_t a1 = a0 + bgplane_total_bytes(ia->second.map_w, ia->second.map_h);
        auto ib = ia; ++ib;
        for (; ib != d->bg_planes.end(); ++ib) {
          if (!ib->second.sdram_allocated) continue;
          const uint32_t b0 = ib->second.sdram_base;
          const uint32_t b1 = b0 + bgplane_total_bytes(ib->second.map_w, ib->second.map_h);
          if (a0 < b1 && b0 < a1) {
            std::fprintf(stderr,
                "[bgplane diag ARM] ASSERT FAIL: layer %d [0x%08x,0x%08x) overlaps "
                "layer %d [0x%08x,0x%08x)\n",
                ia->first, a0, a1, ib->first, b0, b1);
          }
        }
      }
    }
    // [#dungeon diag, DIAGNOSTIC ONLY] SOLARUS_BGPLANE_DIAG=1: per-layer
    // static-bucket census, right after this rebuild's bounds/allocation are
    // fully known. Answers: is a layer's detailed content actually RECORDED
    // as static entries at all, and if so, does it end up with a plane?
    // Distinguishes "recorded but the bake still renders almost nothing" (a
    // bake-time bug) from "never recorded as static to begin with" (excluded
    // upstream -- e.g. NonAnimatedRegions::record_static's
    // overlaps_animated_tile() check routes an overlapping tile to the
    // animated resident walk instead, or a non-batchable tile hits
    // resident_escape()). Caveat: only layers that appear in layers_present
    // (i.e. have at least one res_static_buckets entry) are logged here --
    // a layer with literally ZERO recorded static content across the whole
    // map has no bucket at all and is silently absent from this log, not
    // printed with static_entries=0.
    if (d->bgplane_diag) {
      for (int layer : layers_present) {
        int static_entries = 0;
        uint64_t covered_px = 0;
        for (const auto& e : extents) {
          if (e.layer != layer) continue;
          ++static_entries;
          covered_px += (uint64_t)e.w * (uint64_t)e.h;
        }
        bgplane_bounds_t bounds =
            compute_bgplane_bounds(extents.data(), (int)extents.size(), layer);
        const bool has_plane = d->bg_planes.find(layer) != d->bg_planes.end();
        std::fprintf(stderr,
            "[bgplane diag ARM-BUCKETS] layer=%d static_entries=%d "
            "covered_px=%llu bbox=%dx%d plane=%s\n",
            layer, static_entries, (unsigned long long)covered_px,
            bounds.mw, bounds.mh, has_plane ? "yes" : "no");
      }
    }
    // Any layer NOT in layers_present, or whose SDRAM allocation failed above,
    // simply has no bg_planes entry -- resident_emit_static_layer's lookup
    // (bg_planes.find(layer)) falls through to the per-bucket replay for it,
    // same as SOLARUS_BGPLANE being off entirely for that one layer.
  }
  d->res_armed = true;
}

// Emit ONE recorded bucket via the fabric-resolved 8-byte TILELIST_RES (FRT/CFT fabric
// resolution). The stored entry dsts are MAP coords; this applies the bucket's per-frame
// camera bias so the fabric shifts them to screen coords (blitter_top: c_dst = res_dx +
// res_bias). Per-scene arm/FRT_UPLOAD happen lazily on the first bucket emitted (guarded +
// idempotent). ensure_frame/mark_render are idempotent. [Task 7] this is now the ONLY
// resident emit path — no Tier A / no res_hw gate.
void MisterBlitterRenderer::res_emit_bucket_(size_t idx) {
  if (idx >= d->res_buckets.size()) return;
  d->mark_render();
  d->ensure_frame();
  const Impl::ResBucket& b = d->res_buckets[idx];
  if (!d->res_armed) res_arm_();
  if (d->res_fatal) return;   // arm found a whole-map TL_BUF overflow: nothing to emit
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
}

// [static tile-list] Emit one recorded static bucket via direct BLT_OP_TILELIST (no FRT/CFT
// indirection — entries carry their own src). Parallel to res_emit_bucket_.
void MisterBlitterRenderer::res_emit_static_bucket_(size_t idx) {
  if (idx >= d->res_static_buckets.size()) return;
  d->mark_render();
  d->ensure_frame();
  if (!d->res_armed) res_arm_();
  if (d->res_fatal) return;
  const Impl::StaticBucket& b = d->res_static_buckets[idx];
  if (b.hw_count == 0) return;
  blt_surface_ref_t tex = d->upload(*b.tsimg, b.fmt);
  if (!tex.valid) return;
  const int cx = mister_camera_x(), cy = mister_camera_y();
  int16_t bx, by;
  if (b.scroll_ratio <= 1) { bx = (int16_t)(-cx); by = (int16_t)(-cy); }
  else { bx = (int16_t)(cx / b.scroll_ratio - cx); by = (int16_t)(cy / b.scroll_ratio - cy); }
  blt_tile_list_static(&d->em, tex, b.blend, b.key, /*alpha=*/255, b.flags,
                       b.hw_off, b.hw_count, bx, by);
  d->alias_drawn_this_frame = true;
  if (d->diag) d->g_alias_blits += b.hw_count;
}

// Bucket-only emit of a whole layer (kept for completeness; the engine fast path now
// drives the interleaved op list below in paint order).
void MisterBlitterRenderer::resident_emit_layer(int layer) {
  for (size_t i = 0; i < d->res_ops.size(); ++i)
    if (d->res_ops[i].layer == layer)
      res_emit_bucket_(d->res_ops[i].bk);
}

// ── Engine-driven interleaved replay (fast path) ─────────────────────────────
// [Task 7] Every op is a bucket now (no per-tile escape replay), so the engine's
// per-layer loop just emits each op via resident_emit_layer_op in paint order.
int MisterBlitterRenderer::resident_layer_op_count(int layer) const {
  int n = 0;
  for (const auto& o : d->res_ops) if (o.layer == layer) ++n;
  return n;
}

uintptr_t MisterBlitterRenderer::resident_layer_op_tile(int layer, int i) const {
  (void)layer; (void)i;
  return 0;   // [Task 7] no escapes; every op is a bucket, never a re-drawn Tile*.
}

void MisterBlitterRenderer::resident_emit_layer_op(int layer, int i) {
  int k = 0;
  for (const auto& o : d->res_ops)
    if (o.layer == layer) { if (k == i) { res_emit_bucket_(o.bk); return; } ++k; }
}

// [static tile-list] Op-count/emit accessors for the static bucket list, mirroring
// resident_layer_op_count/resident_emit_layer_op above.
int MisterBlitterRenderer::resident_static_op_count(int layer) const {
  int n = 0;
  for (const auto& o : d->res_static_ops) if (o.layer == layer) ++n;
  return n;
}
void MisterBlitterRenderer::resident_emit_static_op(int layer, int i) {
  int k = 0;
  for (const auto& o : d->res_static_ops)
    if (o.layer == layer) { if (k == i) { res_emit_static_bucket_(o.bk); return; } ++k; }
}

// [Phase 3b, generalized Task 6] Replace the whole static-bucket replay with
// one ordinary windowed COPY from THIS layer's own baked background plane,
// when available. Falls back to the original per-bucket replay
// (res_emit_static_bucket_ per op, unchanged) when this layer has no
// bg_planes entry (no recorded static content, or its SDRAM allocation
// failed), it's not valid yet (still baking right after a map change), or the
// feature is gated off -- every layer without a ready plane always uses the
// per-bucket path, exactly as if BGPLANE were off for it. [Task 6] No longer
// restricted to one hardcoded base layer -- every layer gets its own plane
// and its own independent valid/baking state (d->bg_planes, keyed by layer).
// Because each plane is stored map-scan-order (bgplane_geom.h), the source
// window is always a single contiguous strided rect -- no per-cell splitting
// needed even when the camera straddles a cell boundary.
void MisterBlitterRenderer::resident_emit_static_layer(int layer) {
  // [Task 6] Look up THIS layer's own plane instead of comparing against a
  // single hardcoded bg_base_layer -- absent (no static content on this
  // layer, or its SDRAM allocation failed), invalid (still baking, or this
  // layer was never eligible), or still baking all fall back to the
  // per-bucket replay for this layer only, exactly as if BGPLANE were off for
  // it (every other layer, including ones WITH a ready plane, is unaffected).
  auto it = d->bg_planes.find(layer);
  if (!d->bgplane_enabled || it == d->bg_planes.end() || !it->second.valid) {
    for (size_t i = 0; i < d->res_static_ops.size(); ++i)
      if (d->res_static_ops[i].layer == layer)
        res_emit_static_bucket_(d->res_static_ops[i].bk);
    return;
  }
  Impl::BgPlane& p = it->second;
  // [Task 6] Every layer with static content now gets its own plane -- no
  // longer restricted to the base layer. [ARGB4444 plane bake] This COPY is
  // BLT_BLEND_PALPHA over an ARGB4444 plane (gaps baked alpha=0, see
  // bake_background_plane_step's BLT_F_BGCOV fill above), so it no longer
  // needs to fire before anything else has drawn to the framebuffer this
  // frame -- it's safe at whatever point in THIS layer's draw step it
  // happens to land (Entities::draw() now always emits static after animated,
  // unconditionally, for every layer -- see patch 0031/Task 7). A layer
  // without a ready plane (see the
  // fallback above) still gets the per-bucket path, which fires at the
  // correct point in ITS OWN layer's draw step and respects gaps/
  // transparency -- e.g. whatever occludes the hero (tree canopy,
  // doorframes) on a higher layer. The per-frame latch below is now
  // redundant in principle (this branch is only ever reached once per frame
  // per layer, since each layer appears exactly once in Entities::draw()'s
  // per-layer loop) but kept as cheap defense-in-depth.
  if (p.copied_this_frame) return;
  p.copied_this_frame = true;
  d->mark_render();
  d->ensure_frame();
  // mister_camera_x/y() are TRUE map coords; the plane's internal coordinate
  // space starts at (0,0) regardless of the map's true origin (see
  // p.origin_x/y), so the read position must shift into plane space the same
  // way the bake's per-cell bias does.
  const int cx = mister_camera_x() - p.origin_x;
  const int cy = mister_camera_y() - p.origin_y;
  blt_surface_ref_t plane_ref{};
  plane_ref.valid     = 1;
  plane_ref.off       = 0;                  // DDR heap offset unused -- sdram_off wins
  plane_ref.sdram_off = p.sdram_base;        // permanent SDRAM byte base of this layer's plane
  plane_ref.size      = 0;                   // not heap-allocated; no free needed
  plane_ref.w         = (uint16_t)p.map_w;
  plane_ref.h         = (uint16_t)p.map_h;
  plane_ref.stride    = (uint16_t)(bgplane_row_stride_qw(p.map_w) * 8);  // bytes/row
  plane_ref.format    = BLT_FMT_ARGB4444;   // [ARGB4444 plane bake] real per-pixel alpha;
                                             // gaps (alpha=0) leave whatever's already
                                             // drawn on this layer untouched -- see
                                             // BLT_BLEND_PALPHA below.
  // [#24 host bake audit, DIAGNOSTIC ONLY] SOLARUS_BGPLANE_DIAG=1: log this
  // layer's read-side geometry right before the COPY that actually consumes it,
  // and assert #1 (write/read stride agreement) -- the classic banding cause --
  // right where plane_ref.stride (the field the fabric's blit command actually
  // carries) is computed. Rate-limited to ~1/sec like the existing d->diag COPY
  // log below (a per-layer fprintf every frame would flood stderr on a sustained
  // gameplay run), but an assert FAILURE always prints unconditionally -- an
  // intermittent divergence must never be missed by the rate limiter.
  if (d->bgplane_diag) {
    static int _bgplane_diag_n = 0;
    const bool log_this_frame = ((_bgplane_diag_n++ % 60) == 0);
    const uint32_t expect_stride_bytes = bgplane_row_stride_qw(p.map_w) * 8u;
    const bool stride_ok = ((uint32_t)plane_ref.stride == expect_stride_bytes);
    if (log_this_frame) {
      std::fprintf(stderr,
          "[bgplane diag EMIT] layer=%d map=%dx%d padded_w=%d stride_qw=%u "
          "plane_ref.stride=%u sdram_base=0x%08x total=%u origin=%d,%d "
          "cx=%d cy=%d\n",
          layer, p.map_w, p.map_h, bgplane_padded_w(p.map_w),
          bgplane_row_stride_qw(p.map_w), (unsigned)plane_ref.stride,
          p.sdram_base, bgplane_total_bytes(p.map_w, p.map_h),
          p.origin_x, p.origin_y, cx, cy);
    }
    if (!stride_ok) {
      std::fprintf(stderr,
          "[bgplane diag EMIT] ASSERT FAIL: layer=%d plane_ref.stride=%u != "
          "expected %u (write stride_qw*8) -- write/read stride diverge, this "
          "IS the banding\n",
          layer, (unsigned)plane_ref.stride, expect_stride_bytes);
    }
    // [#24 host bake audit, DIAGNOSTIC ONLY, instrument 2] Per-cell expected-
    // vs-actual source-offset cross-check. For EACH of this layer's bake-grid
    // cells, independently recompute its byte offset from first principles --
    // the cell's TRUE, un-origin-shifted map coordinates and a stride
    // recomputed directly from bgplane_padded_w() (NOT by calling
    // bgplane_cell_plane_byte_offset(), so this is a genuinely separate
    // derivation, not a tautological re-check of the exact function the write
    // side already calls) -- and compare it against
    // bgplane_cell_plane_byte_offset()'s own answer for that same cell (the
    // actual byte offset bake_background_plane_step used when it wrote this
    // cell). Prints UNCONDITIONALLY on any mismatch -- never rate-limited --
    // naming the exact divergent cell(s) and the offset error numerically.
    {
      bgplane_grid_t g = bgplane_grid(p.map_w, p.map_h);
      const uint32_t stride_bytes_indep =
          (uint32_t)bgplane_padded_w(p.map_w) * (uint32_t)BGPLANE_BYTES_PER_PIXEL;
      for (int idx = 0; idx < g.count; ++idx) {
        bgplane_cell_t c = bgplane_cell(idx, p.map_w, p.map_h);
        const int world_x = c.map_x + p.origin_x;  // true, un-shifted map coord
        const int world_y = c.map_y + p.origin_y;
        const uint64_t expected_off = (uint64_t)p.sdram_base
            + (uint64_t)(world_y - p.origin_y) * stride_bytes_indep
            + (uint64_t)(world_x - p.origin_x) * BGPLANE_BYTES_PER_PIXEL;
        const uint64_t actual_off = (uint64_t)p.sdram_base
            + bgplane_cell_plane_byte_offset(idx, p.map_w, p.map_h);
        if (expected_off != actual_off) {
          std::fprintf(stderr,
              "[bgplane diag EMIT] ASSERT FAIL: layer=%d cell=%d cx=%d cy=%d "
              "camera=%d,%d expected_off=0x%llx actual_off=0x%llx delta=%lld\n",
              layer, idx, cx, cy, mister_camera_x(), mister_camera_y(),
              (unsigned long long)expected_off, (unsigned long long)actual_off,
              (long long)((int64_t)expected_off - (int64_t)actual_off));
        }
      }
    }
  }
  if (d->diag) {
    static int _bgplane_copy_diag_n = 0;
    if ((_bgplane_copy_diag_n++ % 60) == 0) {
      std::fprintf(stderr,
          "[blitter bgplane] COPY layer=%d cx=%d cy=%d plane=%dx%d origin=%d,%d "
          "sdram_off=%u camera=%d,%d\n",
          layer, cx, cy, p.map_w, p.map_h, p.origin_x, p.origin_y,
          p.sdram_base, mister_camera_x(), mister_camera_y());
    }
  }
  // [#24 FIX] Clip the read window to the plane's valid content extent
  // [0,map_w)x[0,map_h) before emitting the COPY. blt_blit (blt_emitter.c)
  // does not clip its source rect to the surface's own w/h -- it just packs
  // c.src_x=(uint16_t)sx / c.src_y=(uint16_t)sy and lets the fabric read
  // sx..sx+w, sy..sy+h verbatim. When the camera window falls even partially
  // outside a layer's baked content (a layer whose plane is smaller than the
  // full map, or simply near a map edge), the un-clipped read walks into
  // whatever SDRAM sits adjacent to this plane -- another layer's plane, or
  // unbaked padding -- showing as a misplaced/garbage background (root
  // cause of #24, confirmed via the row-gradient diag: layer 1's 552x632
  // plane read at camera map-x=800 > map_w=552 landed entirely out of
  // bounds). A negative cx/cy is worse: cast to the command's uint16_t
  // src_x/src_y, it wraps to ~65528 instead of going negative, reading a
  // wildly wrong SDRAM address. Same class of bug as the earlier intro
  // host-side-clip fix (docs/superpowers -- solarus-intro-host-side-clip-fix).
  //
  // Clip [cx,cx+FB_W) x [cy,cy+FB_H) (the camera window) against
  // [0,p.map_w) x [0,p.map_h) (the plane's real content, NOT the padded
  // storage size): a left/top clip both shrinks the read width/height AND
  // shifts the destination write position right/down by the same amount (so
  // the surviving content still lands at its correct screen position); a
  // right/bottom clip only shrinks the read size (the destination start is
  // already correct). If the two rects don't overlap at all, this layer's
  // plane contributes nothing to this frame -- skip the COPY entirely
  // (leaves whatever's already drawn on this layer untouched, exactly like
  // an all-transparent read would).
  {
    int sx = cx, sy = cy, w = FB_W, h = FB_H, ddx = 0, ddy = 0;
    if (sx < 0) { w += sx; ddx = -sx; sx = 0; }
    if (sy < 0) { h += sy; ddy = -sy; sy = 0; }
    if (sx + w > (int)p.map_w) w = (int)p.map_w - sx;
    if (sy + h > (int)p.map_h) h = (int)p.map_h - sy;
    if (w > 0 && h > 0) {
      // [FORK-SPLITTER] SOLARUS_BGPLANE_COPYDBG=1 forces BLT_BLEND_COPY so the
      // plane's RGB blits regardless of its alpha nibble -- see bgplane_copydbg.
      const uint8_t blend = d->bgplane_copydbg ? BLT_BLEND_COPY : BLT_BLEND_PALPHA;
      blt_blit(&d->em, plane_ref, sx, sy, w, h, ddx, ddy, blend, 0, 255, 0);
      d->alias_drawn_this_frame = true;
      if (d->diag) d->g_alias_blits++;
      // [FORK-SPLITTER / sampler-alias fix] one unconditional line per COPY that
      // actually issues, so layer 0 (the white floor) is never hidden by the
      // %60-shared-counter aliasing the EMIT log above suffers from. Gated on
      // bgplane_diag; rate-limited per layer so a sustained run doesn't flood.
      if (d->bgplane_diag) {
        static int _copyn[8] = {0,0,0,0,0,0,0,0};
        const int li = (layer >= 0 && layer < 8) ? layer : 7;
        if ((_copyn[li]++ % 120) == 0) {
          std::fprintf(stderr,
              "[bgplane diag COPY-ISSUE] layer=%d blend=%u sx=%d sy=%d w=%d h=%d "
              "ddx=%d ddy=%d sdram_base=0x%08x\n",
              layer, (unsigned)blend, sx, sy, w, h, ddx, ddy, p.sdram_base);
        }
      }
    }
    // w<=0 or h<=0: camera window has zero overlap with this layer's baked
    // content -- no COPY, no alias_drawn_this_frame/g_alias_blits bump
    // (nothing was actually drawn).
  }
}

// [Task 7] Remaining room, expressed as a conservative entry count, across the WHOLE scene
// recorded so far this build versus TL_BUF capacity. Lets the engine expand repeated/fill
// tiles into per-cell entries without exceeding TL_BUF; res_arm_ is the authoritative
// (whole-map) hard-fail check at write time.
//
// [#67] Two consumers share this estimate — the animated walk (8-byte blt_tile_entry_res_t)
// and the non-animated walk (12-byte blt_tile_entry_t). Mirror res_arm_'s byte accounting:
// sum BOTH bucket stores in bytes, and report remaining room in the LARGER (12-byte) entry
// size. That keeps the count safe for either caller — the earlier version counted only the
// animated buckets and reported 8-byte slots, over-estimating room ~1.5x during the static
// walk and letting a near-capacity map hit res_fatal instead of backing off cleanly. Under-
// estimating the 8-byte animated path only makes the batcher flush a touch early; never a
// hard fail.
int MisterBlitterRenderer::resident_room_entries() const {
  size_t used = 0;
  for (const auto& b : d->res_buckets)        used += b.hw.size()  * sizeof(blt_tile_entry_res_t);
  for (const auto& b : d->res_static_buckets) used += b.ent.size() * sizeof(blt_tile_entry_t);
  constexpr size_t esz = sizeof(blt_tile_entry_t) > sizeof(blt_tile_entry_res_t)
                           ? sizeof(blt_tile_entry_t) : sizeof(blt_tile_entry_res_t);
  const size_t cap = d->em.tl_cap;
  if (used >= cap) return 0;
  return (int)((cap - used) / esz);
}

void MisterBlitterRenderer::present(SDL_Window* /*window*/) {
  // [#24 arena probe] SOLARUS_ARENA_PROBE=1 hijacks the frame with the definitive
  // SDRAM-arena HW probe (no gameplay drawing). See Impl::run_arena_probe().
  if (d->arena_probe) { d->run_arena_probe(); return; }
  // [BGW-PROBE] SOLARUS_BGW_PROBE=1 hijacks the frame to test OP_BGPLANE_WRITE's
  // SDRAM write path in isolation (see Impl::run_bgw_probe()).
  if (d->bgw_probe) { d->run_bgw_probe(); return; }
  // [residency] !perm_overflow: if the PERMANENT region ever exhausts mid-gameplay (e.g.
  // an ARGB4444 variant staged on first draw pushes past the 44 MiB budget), the staged
  // sources hold sdram_off==FAIL; committing would let the fabric read a bogus offset ->
  // silent corruption. Treat it like a bounce overflow: drop the frame to the software
  // readback path. perm_overflow is a latch (grow-only region), so this is a permanent,
  // non-corrupting soft-fallback. Preload still hard-fatals on the same condition.
  bool committed = (d->frame_active && !d->frame_escaped && !d->em.overflow && !d->em.perm_overflow);

  // [#52 resident, Task 7] Finalize a resident build done during this frame, then advance
  // the per-frame epoch (memoization reset). No eligibility gate: the build is ALWAYS
  // fast-usable next frame (there is no legacy tier to fall back to). If a hard failure
  // was latched during the build (res_fatal), it stays latched and loud — it is not
  // silently downgraded to a working state.
  if (d->res_building) {
    d->res_valid = true;
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

  // fold this frame's per-layer param hashes for the [blitter paramstab] diagnostic.
  if (d->diag) d->ps_frame_end();

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
      if (d->res_enabled) {
        // [Task 7] whole-map entry-count banner: entries = total 8-byte resident hw
        // entries recorded across every bucket this scene; tl_used/cap tracks how much
        // of TL_BUF that consumes (the same quantity res_arm_ hard-fails on if it
        // wouldn't fit). fatal=1 latches forever once any resident hard failure fires
        // (unbatchable bucket / pattern-table overflow / TL_BUF overflow) — it is NOT
        // cleared by a scene change, matching "loud, not silently downgraded."
        size_t res_entries = 0;
        for (const auto& b : d->res_buckets) res_entries += b.hw.size();
        std::fprintf(stderr,
          "[blitter resident] /60fr: rebuild=%ld fast_noop=%ld patch_pass=%ld "
          "patched_entries=%ld | buckets=%zu patterns=%zu entries=%zu "
          "tl_used=%zu/%zu valid=%d fatal=%d\n",
          d->res_rebuilds, d->res_noops, d->res_patch_passes, d->res_patched_entries,
          d->res_buckets.size(), d->res_patterns.size(), res_entries,
          res_entries * sizeof(blt_tile_entry_res_t), d->em.tl_cap,
          d->res_valid ? 1 : 0, d->res_fatal ? 1 : 0);
      }
      d->res_rebuilds = d->res_noops = d->res_patch_passes = d->res_patched_entries = 0;
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
        // present = A9 - lua - emit (submit/doorbell/input-poll).
        double lua_ms    = d->t_lua_ns / N / 1e6;
        double emit_ms   = (d->t_draw_ns - d->t_fab_ns - d->t_sleep_ns) / N / 1e6;
        double presov_ms = a9_ms - lua_ms - emit_ms;
        std::fprintf(stderr,
          "[blitter a9split] /60fr: A9=%.1fms = lua=%.1fms + emit=%.1fms + present=%.1fms\n",
          a9_ms, lua_ms, emit_ms, presov_ms);
        // [emit drill-down] split emit into the Solarus draw-walk vs our per-blit
        // emit_draw work, and isolate the diag-only ps_add tax. blit = time inside
        // emit_draw (entity sprite blits); walk = emit - blit (entity/tile traversal,
        // z-sort, NonAnimatedRegions); real_emit = emit - ps_add (the shippable est.).
        {
          long long eb = g_emit_blit_ns, ep = g_emit_psadd_ns;
          double blit_ms  = (eb - d->t_emit_blit_prev) / N / 1e6;
          double psadd_ms = (ep - d->t_emit_psadd_prev) / N / 1e6;
          d->t_emit_blit_prev = eb; d->t_emit_psadd_prev = ep;
          double walk_ms = emit_ms - blit_ms;
          double real_emit_ms = emit_ms - psadd_ms;
          std::fprintf(stderr,
            "[blitter emitsplit] /60fr: emit=%.1fms = walk=%.1f + blit=%.1f | "
            "ps_add(diag-tax)=%.1f -> real_emit~%.1fms\n",
            emit_ms, walk_ms, blit_ms, psadd_ms, real_emit_ms);
        }
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
        // [enttype] Drill the entities bucket down by EntityType: which kinds of
        // entity eat the all_entities update loop. Per-type ms is /N (60fr) and
        // /steps_pf-amplified just like the entities bucket; cnt is entities/frame
        // (== entities-per-step * steps_pf). Prints the top types by ms this window.
        {
          static const char* const ENT_TYPE_NAMES[32] = {
            "tile","destination","teletransporter","pickable","destructible","chest",
            "jumper","enemy","npc","block","dynamic_tile","switch","wall","sensor",
            "crystal","crystal_block","shop_treasure","stream","door","stairs",
            "separator","custom","camera","hero","carried_object","boomerang",
            "explosion","arrow","bomb","fire","hookshot","?" };
          double et_ms[32]; double et_cnt[32]; double tot_cnt = 0;
          for (int i = 0; i < 32; ++i) {
            long long ns = g_me_ent_type_ns[i], cn = g_me_ent_type_cnt[i];
            et_ms[i]  = (double)(ns - d->t_enttype_ns_prev[i]) / N / 1e6;
            et_cnt[i] = (double)(cn - d->t_enttype_cnt_prev[i]) / N;
            d->t_enttype_ns_prev[i] = ns; d->t_enttype_cnt_prev[i] = cn;
            tot_cnt += et_cnt[i];
          }
          char line[512]; int off = 0;
          off += std::snprintf(line + off, sizeof line - off,
                               "[blitter enttype] /60fr: n=%.0f/fr |", tot_cnt);
          bool used[32] = {false};
          for (int rank = 0; rank < 6; ++rank) {
            int best = -1;
            for (int i = 0; i < 32; ++i)
              if (!used[i] && et_ms[i] > 0.05 && (best < 0 || et_ms[i] > et_ms[best])) best = i;
            if (best < 0) break;
            off += std::snprintf(line + off, sizeof line - off, " %s=%.1fms(%.0f)",
                                 ENT_TYPE_NAMES[best], et_ms[best], et_cnt[best]);
            used[best] = true;
          }
          std::fprintf(stderr, "%s\n", line);

          // [enemy SIMD-vs-throttle] Split the enemy bucket (et_ms[7]) into the AI
          // Lua callback (single-lua_State-bound -> can only be THROTTLED) vs the
          // rest (built-in state machine + movement + collision-on-move -> the only
          // part that could be SIMD'd/parallelized). Answers whether the ~7-8ms
          // enemy cost is worth a SIMD collision effort or just AI-tick throttling.
          {
            long long el = g_me_enemy_lua_ns;
            double enemy_lua_ms = (double)(el - d->t_enemy_lua_prev) / N / 1e6;
            d->t_enemy_lua_prev = el;
            double enemy_tot_ms = et_ms[7];              // 7 == EntityType::ENEMY
            double enemy_nonlua_ms = enemy_tot_ms - enemy_lua_ms;
            std::fprintf(stderr,
              "[blitter entphase] /60fr: enemy=%.1fms = ai_lua=%.1f (throttle-only) "
              "+ nonlua=%.1f (state/move/collision -> SIMD-candidate)\n",
              enemy_tot_ms, enemy_lua_ms, enemy_nonlua_ms);

            // [entsplit] Drill the enemy nonlua cost into the Entity::update phases
            // (sprite/anim, movement integration, state machine incl. stream) so
            // STEP-2 picks the right lever. collision is the *nested* subset of the
            // sprite+move phases (Map::check_collision_with_detectors: quadtree query
            // + per-detector overlap -> pointer-chasing, a PRUNING candidate not SIMD).
            // sprite+move+state ~= nonlua (the tiny enemy date-check block is unbucketed).
            {
              long long sp = g_me_ent_sprite_ns, mv = g_me_ent_move_ns;
              long long st = g_me_ent_state_ns,  co = g_me_ent_coll_ns;
              long long ob = g_me_ent_obst_ns;
              double sp_ms = (double)(sp - d->t_ent_sprite_prev) / N / 1e6;
              double mv_ms = (double)(mv - d->t_ent_move_prev)   / N / 1e6;
              double st_ms = (double)(st - d->t_ent_state_prev)  / N / 1e6;
              double co_ms = (double)(co - d->t_ent_coll_prev)   / N / 1e6;
              double ob_ms = (double)(ob - d->t_ent_obst_prev)   / N / 1e6;
              double integ_ms = mv_ms - ob_ms;   // move phase minus terrain-obstacle test
              long long qt = g_me_ent_qtree_ns, gr = g_me_ent_ground_ns;
              double qt_ms = (double)(qt - d->t_ent_qtree_prev)  / N / 1e6;
              double gr_ms = (double)(gr - d->t_ent_ground_prev) / N / 1e6;
              // integ = math+setpos+notify + qtree + ground + detector(nested). Rest =
              // integ - qtree - ground - detector -> the raw math/set_position/notify tail.
              double rest_ms = integ_ms - qt_ms - gr_ms - co_ms;
              d->t_ent_sprite_prev = sp; d->t_ent_move_prev = mv;
              d->t_ent_state_prev  = st; d->t_ent_coll_prev = co;
              d->t_ent_obst_prev   = ob;
              d->t_ent_qtree_prev  = qt; d->t_ent_ground_prev = gr;
              std::fprintf(stderr,
                "[blitter entsplit] /60fr enemy nonlua: sprite=%.1fms "
                "move=%.1fms (integ=%.1f + obstacle=%.1f) state=%.1fms | "
                "detector_coll=%.1fms (quadtree, prune-candidate)\n",
                sp_ms, mv_ms, integ_ms, ob_ms, st_ms, co_ms);
              std::fprintf(stderr,
                "[blitter movedrill] /60fr enemy per-move bookkeeping: "
                "qtree_reinsert=%.1fms ground_requery=%.1fms detector=%.1fms "
                "math+setpos+notify=%.1fms\n",
                qt_ms, gr_ms, co_ms, rest_ms);
            }
          }

          // [SOLARUS_DRAWCACHE diagnostic] entities_to_draw lazy-rebuild hit/miss:
          // hit = draw() reused the cached z-sorted list (nothing dirtied it since
          // the last rebuild); miss = a full get_entities_in_rectangle_z_sorted +
          // sort/dedup ran this tick. Standing still with the cache on should climb
          // toward ~60/60 hit per window once the camera settles (Task 4).
          {
            long long dch = g_me_drawcache_hit, dcm = g_me_drawcache_miss;
            double hit_pf  = (dch - d->t_dch_prev) / N;
            double miss_pf = (dcm - d->t_dcm_prev) / N;
            d->t_dch_prev = dch; d->t_dcm_prev = dcm;
            std::fprintf(stderr,
              "[blitter drawcache] /60fr hit=%.0f miss=%.0f\n",
              hit_pf, miss_pf);
          }

          // [SOLARUS_IDLESKIP diagnostic] definitive skip ratio: of the destructible
          // updates seen this window, how many were provably-idle and skipped. A high
          // ratio with a matching drop in the enttype destructible bucket = the lever
          // works; a low ratio = these quests' destructibles animate / aren't idle
          // (the sprite-may-change veto fires) so the skip is correctly a no-op.
          {
            long long ds = g_me_destr_seen, dk = g_me_destr_skipped;
            double seen = (double)(ds - d->t_destr_seen_prev) / N;
            double skip = (double)(dk - d->t_destr_skip_prev) / N;
            d->t_destr_seen_prev = ds; d->t_destr_skip_prev = dk;
            if (seen > 0.5) {
              std::fprintf(stderr,
                "[blitter idleskip] /60fr: destr_seen=%.0f/fr skipped=%.0f/fr (%.0f%%)\n",
                seen, skip, 100.0 * skip / seen);
            }
          }
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
    if (d->fps_overlay_enabled()) d->emit_fps_overlay_fills();
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
    if (!d->single_buf) d->target_buf ^= 1;

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
