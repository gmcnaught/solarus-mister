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
// two maps' atlases co-resident overflow the heap (black flicker). While in a
// transition we DISABLE the alias so the new map composites onto its surface (real
// pixels) and both surfaces blit at their offsets; the bg-cache is forced to LEARN.
// Gated everywhere by !g_in_transition so normal gameplay is byte-identical.
static bool g_in_transition = false;
void mister_set_transition(bool t) { g_in_transition = t; }

// ---- DDR layout for the blitter region.
// MUST MATCH the fabric's fpga/rtl/blitter_defs.vh. Framebuffers + video control
// word stay in the proven 1 MiB f2h region at 0x3A000000 (drop-in producer). The
// blitter COMMAND region (ctrl/ring + source heap) lives in a dedicated 4 MiB
// region at 0x3B000000 so a full SCENE TRANSITION (two scenes co-resident, ~1 MiB)
// fits — the 1 MiB region's pre-audio gap only afforded 352 KiB (heavy scenes
// escaped on size). 0x3B000000..0x3B400000 HW-verified reserved-safe (64/64 pattern
// words survive Linux + engine + video/audio).
//   BLTCTRL 0x3B000000 | RING 0x3B000040 | SRC heap 0x3B008000 | end 0x3B400000
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
constexpr uint32_t RING_CAP      = 0x00007FC0u;  // ring spans 0x40..0x8000 (~32 KiB)
constexpr uint32_t OFF_HEAP      = 0x00008000u;  // heap @ 0x3B008000 (~4 MiB to end)
// BACKGROUND CACHE (SOLARUS_BGCACHE): the composited static map background lives at a
// FIXED DDR location 0x3BF00000 (= BLT_DDR_PHYS + 0xF00000) — MUST MATCH the fabric's
// `CACHE_QW` in blitter_defs.vh. The fabric composes the static layers INTO it via the
// off-screen pass (C_TARGET=2, no display flip), and reads it as a heap SOURCE for the
// per-frame cache->fb blit. The bump heap is capped below it (never overwrites it).
constexpr uint32_t OFF_BGCACHE   = 0x00F00000u;                    // ddr-relative: 0x3BF00000
constexpr uint32_t BGCACHE_HEAP_OFF = OFF_BGCACHE - OFF_HEAP;      // heap-relative src_off
constexpr uint32_t HEAP_CAP_BG   = OFF_BGCACHE - OFF_HEAP;         // bump heap cap (reserves bg)
// control-block byte offsets — QWORD-spaced (fabric reads qword fields), low 32 used
constexpr uint32_t C_SUBMIT = 0x00, C_CMDCOUNT = 0x08, C_TARGET = 0x10,
                   C_CLEAR  = 0x18, C_FLAGS    = 0x20, C_DONE = 0x28,
                   C_SRCSEL = 0x38;   // [MiSTer #19] source mux: 0=DDR3, 1=SDRAM

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

inline uint16_t to_rgb565(uint8_t r, uint8_t g, uint8_t b) {
  return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}
}  // namespace

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
  bool was_in_transition  = false;   // [MiSTer #24] track g_in_transition for edge-reset
  bool scene_too_big      = false;   // a reset did NOT clear overflow -> one frame's
                                     // working set genuinely exceeds the heap; stop
                                     // resetting (avoid per-frame re-upload thrash)
                                     // until the scene changes (see invalidate()).

  // env-gated diagnostics (SOLARUS_BLITTER_DIAG=1): per-window tallies.
  bool diag = false;
  long g_fills = 0, g_blits = 0, g_alias_blits = 0, g_escapes = 0, g_offtarget_draw = 0;
  long g_frames_emit = 0, g_frames_escape = 0, g_uploads = 0, g_reuploads = 0;
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
  bool bgcache_enabled = false;          // SOLARUS_BGCACHE
  bool stage_enabled   = false;          // [MiSTer #19] SOLARUS_SDRAM_SRC: emit STAGE + set C_SRCSEL=1
  enum { BG_LEARN = 0, BG_SNAPSHOT = 1, BG_ACTIVE = 2 };
  int  bg_state = BG_LEARN;
  unsigned long long bg_hash = 0;        // this frame's static-set param hash (accum in draws)
  unsigned long long bg_last_hash = 0;   // previous frame's static hash (stability watch)
  unsigned long long bg_cache_hash = 0;  // hash the snapshot was taken at
  int  bg_stable_run = 0;                // consecutive frames bg_hash unchanged
  int  bg_snap_buf = 0;                  // buffer the SNAPSHOT pass rendered into
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
      // [MiSTer #24] On entering OR leaving a map transition, reclaim the heap. Across
      // the transition boundary the two scenes' atlases are co-resident (the old map's
      // linger while the new map uploads) and overflow the heap -> one black frame.
      // Resetting on each edge makes each scene upload into a clean heap.
      if (g_in_transition != was_in_transition) {
        heap_reset_pending = true;
        was_in_transition = g_in_transition;
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
      if (em.submit_seq != 0) {
        struct timespec ts{0, 200000};                 // 0.2 ms between polls
        struct timespec fa, fb; int spin = 0;
        if (diag) clock_gettime(CLOCK_MONOTONIC, &fa);
        for (; spin < 5000 && ddr_r32(C_DONE) != em.submit_seq; ++spin)
          nanosleep(&ts, nullptr);                      // up to ~1 s
        if (diag) {
          clock_gettime(CLOCK_MONOTONIC, &fb);
          t_fab_ns += ns_diff(fb, fa);                  // ~= fabric compute time
          t_fab_iters += spin;
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
      const bool bg_active = bgcache_enabled && bg_state == BG_ACTIVE && bg_handle.w != 0;
      if (bg_active) {
        // The bg copy below establishes the full static background as the frame base
        // (no carry-forward — that would smear the previous frame's hero; no hwclear —
        // the opaque copy overwrites everything). Dynamic blits composite on top.
        // SCROLL-AWARE: blit the cached bg SHIFTED by the camera delta so the overlap
        // stays valid; the uncovered edge strip is then filled by the live edge cells
        // (composited in branch-2 when in_uncovered_margin). cur_dx/dy are read there.
        if (scroll_cache) { cur_dx = g_cam_x - snap_cam_x; cur_dy = g_cam_y - snap_cam_y; }
        else              { cur_dx = 0; cur_dy = 0; }
        blt_begin_frame(&em, target_buf, /*clear=*/0, /*clear_color=*/0x0000);
        blt_blit_copy(&em, bg_handle, -cur_dx, -cur_dy);
        if (diag) bg_copies++;
      } else if (bgcache_enabled && bg_state == BG_SNAPSHOT) {
        // CACHE_BUILD: compose the STATIC layers into the OFF-SCREEN cache region via
        // C_TARGET=2 (the fabric routes the dst to CACHE_QW and does NOT flip the
        // display). The previous complete frame stays on screen this frame -> NO
        // static-only frame is ever displayed (the old in-buffer snapshot caused the
        // entity-dropout/flicker). clear=1 starts the cache fresh. Dynamic skipped.
        blt_begin_frame(&em, /*target=*/2, /*clear=*/1, /*clear_color=*/0x0000);
      } else {
        if (vid && !clear_requested && em.submit_seq != 0) {
          const uint32_t cur_off  = target_buf ? 0x00040040u : 0x00000040u;
          const uint32_t prev_off = target_buf ? 0x00000040u : 0x00040040u;
          std::memcpy((void*)(vid + cur_off), (const void*)(vid + prev_off),
                      (size_t)FB_W * FB_H * 2u);
          if (diag) g_carryfwd++;
        } else if (diag && clear_requested) {
          g_hwclear++;
        }
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
  static bool to_argb4444(SDL_Surface* s, std::vector<uint16_t>& out) {
    SDL_Surface* c = SDL_ConvertSurfaceFormat(s, SDL_PIXELFORMAT_ARGB8888, 0);
    if (!c) return false;
    out.resize((size_t)c->w * c->h);
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
      SDL_Surface* c = SDL_ConvertSurfaceFormat(s, SDL_PIXELFORMAT_RGB565, 0);
      if (!c) return false;
      const uint8_t* base = static_cast<const uint8_t*>(c->pixels);
      for (int y = 0; y < c->h; ++y)
        std::memcpy((void*)(em.heap + h.off + (size_t)y * h.stride),
                    base + (size_t)y * c->pitch, (size_t)h.w * 2u);
      SDL_FreeSurface(c);
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
          if (diag) g_reuploads++;
          // [MiSTer #19] Re-stage: pixels just refreshed in heap; queue STAGE so
          // the fabric fetches the new bytes into SDRAM before the blit that follows.
          if (stage_enabled) blt_stage(&em, it->second.off, it->second.size);
        } else {
          // Dims changed (rare) — free the old block + drop the cache entry and fall
          // through to a fresh allocation below ([MiSTer #14]: was a leak).
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
    if (diag) g_uploads++;
    if (fmt == BLT_FMT_ARGB4444) {
      std::vector<uint16_t> px;
      if (!to_argb4444(s, px)) return r;
      r = blt_upload_argb4444(&em, px.data(), s->w, s->h, s->w * 2);
    } else {
      SDL_Surface* c = SDL_ConvertSurfaceFormat(s, SDL_PIXELFORMAT_RGB565, 0);
      if (!c) return r;
      r = blt_upload(&em, static_cast<const uint16_t*>(c->pixels),
                     c->w, c->h, c->pitch);
      SDL_FreeSurface(c);
    }
    if (r.valid) {
      handles[kkey] = r;
      // [MiSTer #19] Queue a STAGE command so the fabric copies this source surface
      // from DDR3 into SDRAM before the blits that use it.  Ordered here (after the
      // heap write, before the blit that consumes the handle) so the fabric sees
      // STAGE before BLT_OP_BLIT in the same ring.  No-op when staging is disabled.
      if (stage_enabled) blt_stage(&em, r.off, r.size);
    }
    return r;
  }

  // Map Solarus blend/opacity/colorkey -> blitter blend. Returns false (caller
  // escapes) if the op can't be expressed by the v1 blitter. `why` (diag) names
  // the first unsupported feature.
  // `want_fmt` (out): the source heap format the chosen blend needs —
  // BLT_FMT_RGB565 for opaque/colorkey/const-alpha, BLT_FMT_ARGB4444 for the
  // per-pixel-alpha (BLEND_PALPHA) path.
  bool map_blend(const SurfaceImpl& src, const DrawInfos& infos,
                 uint8_t& blend, uint16_t& key, uint8_t& flags, uint8_t& want_fmt,
                 int& why) {
    flags = 0; why = 0; want_fmt = BLT_FMT_RGB565;
    if (std::fabs(infos.rotation) > 1e-3) { why = 1; return false; }     // rotation
    if (std::fabs(std::fabs(infos.scale.x) - 1.f) > 1e-3 ||
        std::fabs(std::fabs(infos.scale.y) - 1.f) > 1e-3) { why = 2; return false; } // zoom
    uint8_t cr, cg, cb, ca; infos.color.get_components(cr, cg, cb, ca);
    if (cr != 255 || cg != 255 || cb != 255) { why = 3; return false; }  // tint
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
      case BlendMode::MULTIPLY:
      default: why = 5; return false;                                    // not in v1
    }
    return true;
  }

  // Express one draw (src -> dst at dst+offset) as a blitter command. Returns
  // true if emitted, false if the op had to ESCAPE (caller has already set
  // frame_escaped via escape() and tallied the reason). `off_x/off_y` shift the
  // destination so an alias surface (the camera) composites at its screen offset
  // in the DDR framebuffer. Shared by the fpga_target and alias_target paths.
  bool emit_draw(const SurfaceImpl& src, const DrawInfos& infos,
                 int off_x, int off_y) {
    uint8_t blend, flags, want_fmt; uint16_t key; int why = 0;
    if (!map_blend(src, infos, blend, key, flags, want_fmt, why)) {
      escape();
      if (diag) {
        g_escapes++;
        switch (why) { case 1: g_esc_rot++; break; case 2: g_esc_scale++; break;
          case 3: g_esc_tint++; break; case 4: g_esc_alpha++; break;
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
    blt_blit(&em, h, r.get_x(), r.get_y(), r.get_width(), r.get_height(),
             dr.get_x() + off_x, dr.get_y() + off_y, blend, key,
             infos.opacity, flags);
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
    if (!map_blend(src, infos, blend, key, flags, want_fmt, why)) return false;
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
    blt_blit(&em, h, r.get_x() + (nx0 - dx0), r.get_y() + (ny0 - dy0),
             nx1 - nx0, ny1 - ny0, nx0, ny0, blend, key, infos.opacity, flags);
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
  self->d->verify = (std::getenv("SOLARUS_BLITTER_VERIFY") != nullptr);
  self->d->alias_allow_sw = (std::getenv("SOLARUS_ALIAS_SW") != nullptr);
  self->d->camera_tag = (std::getenv("SOLARUS_NO_CAMERA_TAG") == nullptr);
  self->d->vsync_pace = (std::getenv("SOLARUS_NO_VSYNC") == nullptr);
  self->d->bgcache_enabled = (std::getenv("SOLARUS_BGCACHE") != nullptr);
  self->d->scroll_cache = (std::getenv("SOLARUS_SCROLLCACHE") != nullptr);
  self->d->stage_enabled = (std::getenv("SOLARUS_SDRAM_SRC") != nullptr);  // [MiSTer #19]
  if (self->d->stage_enabled)
    std::fprintf(stderr, "[MiSTer blitter] SDRAM source staging ENABLED (C_SRCSEL=1)\n");
  if (self->d->bgcache_enabled)
    std::fprintf(stderr, "[MiSTer blitter] background-composite cache ENABLED\n");
  self->d->single_buf = (std::getenv("SOLARUS_BLITTER_SINGLEBUF") != nullptr);
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
      if (it->second.valid) blt_emitter_free(&d->em, it->second.off, it->second.size);
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
                 (d->alias_target == &dst && dst.get_width() == FB_W && !g_in_transition));
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
               dst.get_width() == FB_W && !g_in_transition;
  if (root || alias) {
    if (mode == BlendMode::ADD || mode == BlendMode::MULTIPLY) {
      // No SDL fallback anymore: the fabric is the sole renderer. ADD/MULTIPLY
      // fills are not in the v1 blitter, so this op simply CANNOT be expressed.
      // Tally it loudly (a real coverage gap to fix on the fabric); the frame
      // still commits without it rather than dropping to a software path.
      d->escape(); if (d->diag) { d->g_escapes++; d->g_esc_mode++; }
      return;
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
  if (d->camera_tag && g_tagged_camera && !g_in_transition && d->alias_target != g_tagged_camera) {
    d->alias_target = g_tagged_camera;
    d->alias_off_x = 0; d->alias_off_y = 0;   // full-screen camera composites at (0,0)
    if (d->diag)
      std::fprintf(stderr, "[blitter alias] camera TAGGED=%p (deterministic)\n",
                   (const void*)g_tagged_camera);
  }
  if (d->blitter_off()) {               // pass-through SDLRenderer (or scene too big)
    SDLRenderer::draw(dst, src, infos);
    if (d->diag) d->g_offtarget_draw++;
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
    if (&src == d->alias_target && d->alias_drawn_this_frame && !g_in_transition) {
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
    if (!d->alias_target && !g_in_transition && d->looks_like_promote(src, infos)) {
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
  if (dst.get_width() == FB_W && d->alias_target == &dst && !g_in_transition) {
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

void MisterBlitterRenderer::present(SDL_Window* window) {
  bool committed = (d->frame_active && !d->frame_escaped && !d->em.overflow);

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
      std::fprintf(stderr, "[blitter offtgt] alias_target=%p :", (const void*)d->alias_target);
      for (int i = 0; i < d->off_dst_n; i++)
        std::fprintf(stderr, " %p(%dx%d)x%ld", d->off_dst[i], d->off_dst_w[i],
                     d->off_dst_h[i], d->off_dst_cnt[i]);
      std::fprintf(stderr, "\n");
      d->off_dst_n = 0;
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
          "sleep=%.1fms | jitter=%.1fms spin_iters=%.0f | pipeline_ceiling=%.1ffps\n",
          fps, per_ms, fab_ms, a9_ms, slp_ms,
          (d->t_period_max - d->t_period_min) / 1e6, d->t_fab_iters / N, pipe_fps);
        // A9 breakdown (issue #26): is the A9 cost Lua game logic or blit emission?
        // present = A9 - lua - emit (submit/doorbell/input-poll/bgcache state machine).
        double lua_ms    = d->t_lua_ns / N / 1e6;
        double emit_ms   = (d->t_draw_ns - d->t_fab_ns - d->t_sleep_ns) / N / 1e6;
        double presov_ms = a9_ms - lua_ms - emit_ms;
        std::fprintf(stderr,
          "[blitter a9split] /60fr: A9=%.1fms = lua=%.1fms + emit=%.1fms + present=%.1fms\n",
          a9_ms, lua_ms, emit_ms, presov_ms);
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
      d->t_lua_ns = d->t_draw_ns = 0;   // A9-breakdown window reset
      d->t_fab_iters = 0; d->t_period_min = d->t_period_max = 0;
      d->g_frames_emit = d->g_frames_escape = 0;
      d->g_fills = d->g_blits = d->g_alias_blits = 0;
      d->g_escapes = d->g_offtarget_draw = 0;
      d->g_uploads = d->g_reuploads = 0;
      d->g_hwclear = d->g_carryfwd = 0;
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
    // [MiSTer #19] Engine-driven source mux: 0 = read from DDR3 heap (default,
    // shipping path unchanged); 1 = read from SDRAM (SOLARUS_SDRAM_SRC enabled).
    // Always written so DDR3 is selected even when staging has never been SET.
    d->ddr_w32(C_SRCSEL,   d->stage_enabled ? 1u : 0u);
    __sync_synchronize();                 // commit ring+ctrl before the doorbell
    d->ddr_w32(C_SUBMIT,   d->em.submit_seq);
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
          d->bg_cache_hash = d->bg_hash; d->bg_state = Impl::BG_ACTIVE; d->bg_snaps++;
          d->snap_cam_x = g_cam_x; d->snap_cam_y = g_cam_y;
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
