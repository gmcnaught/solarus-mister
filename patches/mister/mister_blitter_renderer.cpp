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
#include "blitter/blt_wire.h"         // [PAL8] blt_pal_color(pal_id, base_off) header packing
#include "palette_atlas.h"      // [PAL8 v1] pal_extract/pal_pack (Tasks 2.1/2.2)
#include "scroll_alias.h"       // [Stage 3a] camera-alias scroll-offset rule (shared w/ tests)
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
#include <solarus/core/ResourceProvider.h>   // [#84 Tier-2] shared tileset surfaces
#include <solarus/entities/Tileset.h>          // [#84 Tier-2] Tileset::get_tiles_image
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

// [Stage 1] The ROOT surface, published by MainLoop as engine truth. Mirrors
// mister_tag_camera_surface. Without this, is_fpga_target locks onto the FIRST
// 320x240 texture-backed surface ever drawn to -- a transient render texture can
// steal the lock and send every real root draw down the case-3 fallthrough,
// where it is rendered by SDL but never presented.
static const SurfaceImpl* g_tagged_root = nullptr;
void mister_tag_root_surface(const SurfaceImpl* s) { g_tagged_root = s; }

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

// The tileset's map-wide background color (Game::draw publishes it each frame,
// same site as the fill_with_color(background_color) call it mirrors -- see
// patches/series camera-tag patch). [Task 6] The only consumer of this state
// was the now-deleted per-layer background-plane bake; the setter and its
// storage are left in place because the engine-side hook (patches/series)
// still calls mister_set_background_color() every frame, but nothing in this
// TU currently reads it back. Raw components (not pre-converted to RGB565) so
// this stays independent of to_rgb565's definition order in this TU.
static uint8_t g_bg_color_r = 0, g_bg_color_g = 0, g_bg_color_b = 0;
void mister_set_background_color(uint8_t r, uint8_t g, uint8_t b) {
  g_bg_color_r = r; g_bg_color_g = g; g_bg_color_b = b;
}

// [MiSTer #24] Map-to-map transition tracking (set each frame from Game::draw).
// TransitionScrolling blits the OLD (previous_map_surface) and NEW (camera surface)
// maps onto the root at animating scroll offsets. Our alias optimization composites
// the new map's content straight into DDR at (0,0), leaving the camera SURFACE's own
// pixels empty -- so with the alias on, the new map has nothing to scroll in (only the
// old map scrolls away). Disabling the alias for the duration is the bandaid: it
// forces the whole map to re-composite in SOFTWARE through SDL, and routes both root
// blits into the Stage 1 overlay channel.
//
// [2026-07-19] A SECOND justification used to live here -- "the two maps' atlases
// co-resident overflow the heap (black flicker)", i.e. #123 -- describing a per-edge
// heap reset. That reset was DELETED in commit 4f91c1b ("drop scene_too_big +
// heap-reset/transition-reclaim"); the deletion was pre-planned in
// docs/superpowers/plans/2026-07-06-sdram-asset-residency.md:631, which also said to
// remove "their explanatory comment block". The code went, the comment did not, and
// two stages of planning then treated a dead constraint as live. Removed here. There is no
// heap_reset_pending / was_in_transition / did_reset_last in this file. The premise is
// independently gone too: tileset atlases resolve to PERM SDRAM (see res_bucket_params
// / upload()), and the DDR heap grew 4 -> 16 MiB (#14).
//
// [const-alpha fill / transition scope] The alias-disable is needed ONLY for SCROLLING
// -- the one transition with two maps co-resident and a non-(0,0) blit. FADE and
// IMMEDIATE draw a SINGLE map at its normal (0,0) position, so the alias is valid for
// them; disabling it forced a software re-composite for the fade's duration for no
// benefit. So gate on g_transition_scroll (= active && needs_previous_surface()), true
// only for TransitionScrolling.
//
// [Stage 3a / SOLARUS_SCROLLFAB] The bandaid is being removed: with the flag ON we
// publish the scroll offsets from engine truth (mister_set_transition below) and
// composite BOTH maps on the fabric at their offsets. g_transition_scroll stays as the
// flag-OFF baseline so the two paths can be A/B'd on hardware; delete it once that
// validates.
static bool g_transition_scroll = false;  // scrolling transition (alias-disable)
// [Stage 3a] Scroll offsets, published from ENGINE TRUTH before the map draws.
// Deriving them from the promote blit is impossible: it arrives AFTER the camera's
// own draws in the same frame, so we would be a frame late.
static int g_scroll_new_dx = 0, g_scroll_new_dy = 0;
static int g_scroll_old_dx = 0, g_scroll_old_dy = 0;
static const SurfaceImpl* g_tagged_prev_map = nullptr;

void mister_set_transition(bool active, bool needs_prev,
                           int new_dx, int new_dy, int old_dx, int old_dy) {
  g_transition_scroll = active && needs_prev;   // only TransitionScrolling needs_previous_surface()
  g_scroll_new_dx = new_dx; g_scroll_new_dy = new_dy;
  g_scroll_old_dx = old_dx; g_scroll_old_dy = old_dy;
}
void mister_tag_prev_map_surface(const SurfaceImpl* s) { g_tagged_prev_map = s; }

// ---- DDR layout for the blitter region.
// MUST MATCH the fabric's fpga/rtl/blitter_defs.vh. Framebuffers + video control
// word stay in the proven 1 MiB f2h region at 0x3A000000 (drop-in producer). The
// blitter COMMAND region (ctrl/ring + source heap) lives in a dedicated 4 MiB
// region at 0x3B000000 so a full SCENE TRANSITION (two scenes co-resident, ~1 MiB)
// fits — the 1 MiB region's pre-audio gap only afforded 352 KiB (heavy scenes
// escaped on size). 0x3B000000..0x3B400000 HW-verified reserved-safe (64/64 pattern
// words survive Linux + engine + video/audio).
//   BLTCTRL 0x3B000000 | RING 0x3B000040..0x3B080000 | SRC heap 0x3B080000 | end 0x3C200000
//   ([Stage 3b Phase B1] end grew 0x3C000000 -> 0x3C200000 for the 2 MiB GRID_BUF; see
//   BLT_DDR_SIZE's doc comment for the HW-verification-window caveat on the extension)
namespace {
constexpr uint32_t BLT_DDR_PHYS = 0x3B000000u;
// 18 MiB: ctrl + ring + ~16 MiB heap + 2 MiB GRID_BUF (Stage 3b Phase B1 Task 3,
// below). Grown from 4 MiB (issue #14) to 16 MiB: with the DETERMINISTIC camera
// offload (issue #15) the whole map composite's sources upload to the heap, and
// heavy/transition scenes (2 maps co-resident) overflowed 4 MiB -> escape -> black.
// The kernel cmdline reserves DDR 0x1FF00000..0x40000000 (511..1024 MiB) for the
// core (`mem=511M memmap=513M$511M`), so 0x3B000000..0x3C200000 (944..962 MiB) is
// inside that reserved window. NO RBF change: cmd.src_off is uint32 and the fabric
// forms the address from it (the .vh MEM_QW is a sim guard, not a HW limit); f2h
// addresses all DDR.
// [Stage 3b Phase B1 HW-verification note] Only 0x3B000000..0x3C000000 (the 16 MiB
// sub-range) has actually been HW-verified reserved-safe (64/64 pattern words
// survive Linux + engine + video/audio, see the note below). The 2 MiB extension to
// 0x3C200000 for GRID_BUF is architecturally safe (inside the kernel's reserved
// window, well short of 0x40000000) but has NOT yet been HW pattern-verified on its
// own — this is a Phase B1 host-only task (no RTL FSM consumes GRID_BUF yet); a
// follow-up HW soak of the grown window is owed before B2/B3 ship GRID_BUF traffic.
constexpr size_t   BLT_DDR_SIZE = 0x01200000u;   // 18 MiB (16 MiB heap-side region + 2 MiB GRID_BUF)
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
// [#52 resident / Tier B] current-frame table (CFT). Placed ABOVE TL_BUF (ends
// 0x3BFC0000) and below the region end. MUST match the fabric CFT_BUF_QW=0x3BFC2000
// (blitter_defs.vh) and BLT_MAXP.
//
// The frame-rect table (FRT) used to sit immediately above TL_BUF at this same
// 0x3BFC0000 slot. Stage 3b B2 Task 1 widened BLT_MAXP 128->256, which doubled
// FRT_BUF_BYTES 8->16 KiB; the FRT..CFT span here was flush-packed with no slack,
// so FRT no longer fits and was RELOCATED to the top headroom above GRID_BUF (see
// OFF_FRTBUF's new definition further below, after GRID_BUF_BYTES). The old
// 0x3BFC0000..0x3BFC2000 slot is now a free 8 KiB hole; CFT itself did not move.
constexpr uint32_t OFF_CFTBUF    = 0x00FC2000u;                    // ddr-relative: 0x3BFC2000
constexpr uint32_t CFT_BUF_BYTES = (uint32_t)BLT_MAXP * 2u;        // u16 per pattern
static_assert(OFF_CFTBUF + CFT_BUF_BYTES <= BLT_DDR_SIZE,
              "[#52] CFT must fit inside the mapped DDR region");
// [PAL8 v1] CLUT (palette lookup table) upload DMA source region. Streamed by
// BLT_OP_CLUT_UPLOAD into the fabric's clut_bram, ONE 32-bit entry (high 32 = 0)
// per 64-bit qword, mirroring FRT_UPLOAD's wire packing. MUST match the fabric
// CLUT_BUF_QW=0x3BFC3000 (blitter_defs.vh) and comp_clut.vh's CLUT_BANKS/ENTRIES.
constexpr uint32_t OFF_CLUTBUF   = 0x00FC3000u;                    // ddr-relative: 0x3BFC3000
// [PAL8 v1.1] 32 banks (was 8): MoSDX has ~20 distinct ~256-colour tilesets, each
// consuming a full bank at whole-quest preload, so 8 banks exhausted before the
// title screen and ~85% of surfaces fell back to 16bpp on HW (no halving, #84 only
// delayed). 32 banks fits every tileset (20) plus common sprite/menu palettes. The
// wire pal_id field carries 5 bits (blt_pal_color, bits[12:8]); the fabric decodes
// c_pal_id[4:0] (comp_pipeline clut_rd_addr). CLUTBUF grows 16->64 KiB (asserted).
constexpr uint32_t CLUT_BANKS    = 32u;
constexpr uint32_t CLUT_ENTRIES  = 256u;
constexpr uint32_t CLUTBUF_BYTES = CLUT_BANKS * CLUT_ENTRIES * 8u;  // 8 B (one qword) per entry
static_assert(OFF_CLUTBUF >= OFF_CFTBUF + CFT_BUF_BYTES,
              "[PAL8 v1] CLUTBUF must not overlap CFT");
static_assert(OFF_CLUTBUF + CLUTBUF_BYTES <= BLT_DDR_SIZE,
              "[PAL8 v1] CLUTBUF must fit inside the mapped DDR region");
// [Task 3 / Stage 2] Sprite-entry buffer (BLT_OP_SPRITELIST): its OWN DDR region,
// deliberately NOT a share of TL_BUF -- the whole point of the sprite channel is
// a clean lane that holds no storage in common with the existing resident
// tile-list machinery (TL_BUF/FRT/CFT/CLUT above).
//
// [brief discrepancy] The task-3 brief specified OFF_SPBUF = 0x3BFC0000 (TL_BUF's
// end), assuming that address was free. At the time it was NOT: 0x3BFC0000 was
// OFF_FRTBUF's address (Task 7's resident frame-rect table, landed on this
// codebase before this task), and FRT_BUF/CFT_BUF/CLUTBUF occupied the whole span
// from 0x3BFC0000 up to OFF_CLUTBUF+CLUTBUF_BYTES = ddr-relative 0xFD3000. Placing
// SP_BUF there would have silently aliased FRT/CFT/CLUT. SP_BUF instead sits
// immediately above the REAL end of the occupied region (OFF_CLUTBUF +
// CLUTBUF_BYTES). (Stage 3b B2 Task 1 later relocated FRT away from 0x3BFC0000
// to the top headroom above GRID_BUF, but SP_BUF's placement rule is unaffected —
// CFT/CLUT still occupy the span this note describes.)
//
// The brief also asked for 256 KiB; the gap between the real end of the occupied
// region and BLT_DDR_SIZE (the actual mmap()'d length in map_ddr(), i.e. the end
// of the DDR3 aperture window) is only 0x1000000 - 0xFD3000 = 0x2D000 (180 KiB) --
// 256 KiB does not fit. SP_BUF is sized to 128 KiB (5461 sprites/frame @ 24 B/entry,
// still far above any plausible per-frame sprite count for a 320x240 2D quest),
// leaving headroom inside the remaining gap rather than running off the end of
// the mapped window.
constexpr uint32_t OFF_SPBUF    = OFF_CLUTBUF + CLUTBUF_BYTES;     // ddr-relative: 0x3BFD3000
constexpr size_t   SP_BUF_BYTES = 128u * 1024u;                    // 128 KiB (5461 sprites/frame @ 24 B)
// [code review] No no-overlap assert needed here: OFF_SPBUF is DEFINED as
// OFF_CLUTBUF + CLUTBUF_BYTES above, so "SP_BUF starts at/after the end of
// CLUTBUF (and FRT/CFT beneath it)" holds by construction, not by runtime
// check -- an assert of that relation could never fire and was reviewer-
// flagged as tautological. The one assert that IS load-bearing (catches a
// genuinely possible mistake, e.g. an oversized SP_BUF_BYTES) is kept below.
static_assert(OFF_SPBUF + SP_BUF_BYTES <= BLT_DDR_SIZE,
              "[Task 3] SP_BUF must fit inside the mapped DDR3 window (map_ddr()'s mmap length)");
// [Stage 3b Phase B1 Task 3] Per-layer 8px cell GRID buffer (BLT_OP_TILEMAP): its OWN
// DDR region, deliberately NOT a share of TL_BUF/SP_BUF -- the grid channel holds
// no storage in common with the tile-list or sprite machinery above.
//
// SP_BUF (immediately below) left only 0x1000000 - 0xFF3000 = 0xD000 (52 KiB) of
// headroom inside the OLD 16 MiB BLT_DDR_SIZE -- nowhere near the census-driven 2
// MiB GRID_BUF needs (largest map 382x282 cells x 3 layers x 4 bytes = 1.23 MiB;
// 2 MiB budgeted so two maps' worth of a scroll fit, matching the tile/sprite
// channels' double-scene headroom convention). So GRID_BUF cannot land in the old
// region's tail the way SP_BUF did: BLT_DDR_SIZE above was grown 16 -> 18 MiB
// (see its doc comment) specifically to make room, and GRID_BUF sits immediately
// above the REAL end of the occupied region (OFF_SPBUF + SP_BUF_BYTES), exactly
// the same "sits above the real end, not an assumed address" placement rule
// SP_BUF's brief-discrepancy note above already established.
// [wire cross-check] a PLAIN LITERAL (not a symbolic expression like OFF_SPBUF's
// `OFF_CLUTBUF + CLUTBUF_BYTES`) so scripts/tests/test_wire_constants.py can grab
// it with the same direct regex as OFF_TLBUF/OFF_FRTBUF/OFF_CFTBUF/OFF_CLUTBUF,
// rather than needing another bespoke recompute block. The "sits above the real
// end of the occupied region, not an assumed address" property is instead proven
// by the static_assert immediately below, which is exactly as load-bearing as
// SP_BUF's disjointness argument -- it just checks a literal against the formula
// instead of defining the constant AS the formula.
constexpr uint32_t OFF_GRIDBUF    = 0x00FF3000u;                   // ddr-relative: 0x3BFF3000
constexpr uint32_t GRID_BUF_BYTES = 0x00200000u;                   // 2 MiB = ~1.5x single worst-case map (382x282 cells x 3 layers x 4 B = 1.23 MiB). NOTE: does NOT hold two full worst-case maps co-resident (2x = 2.46 MiB). B2 decision: if scroll requires both outgoing+incoming fully gridded, GRID_BUF grows >=3 MiB + needs grid_used bounds check.
static_assert(OFF_GRIDBUF == OFF_SPBUF + SP_BUF_BYTES,
              "[Stage 3b Phase B1] GRID_BUF must sit immediately above SP_BUF (no overlap, no gap-by-mistake)");
static_assert(OFF_GRIDBUF + GRID_BUF_BYTES <= BLT_DDR_SIZE,
              "[Stage 3b Phase B1] GRID_BUF must fit inside the mapped DDR3 window (map_ddr()'s mmap length)");
// [Stage 3b Phase B2 Task 1] frame-rect table (FRT), RELOCATED here. FRT used to sit
// immediately above TL_BUF at ddr-relative 0x00FC0000 (abs 0x3BFC0000), flush-packed
// against CFT. Widening BLT_MAXP 128->256 doubled FRT_BUF_BYTES 8->16 KiB, which no
// longer fit that span, so FRT alone moves to the top headroom above GRID_BUF —
// CFT/CLUT/SP_BUF/GRID_BUF bases are all unchanged. MUST match the fabric
// FRT_BUF_QW=0x3C1F3000 (blitter_defs.vh) and BLT_MAXP/BLT_MAXF. The old
// 0x3BFC0000..0x3BFC2000 slot is now a free 8 KiB hole.
constexpr uint32_t OFF_FRTBUF    = OFF_GRIDBUF + GRID_BUF_BYTES;    // ddr-relative 0x011F3000 == abs 0x3C1F3000 (relocated above GRID_BUF; MAXP=256)
constexpr uint32_t FRT_BUF_BYTES = (uint32_t)BLT_MAXP * BLT_MAXF * 8u;  // 8 B per (pid,frame); 16 KiB @ MAXP=256
static_assert(OFF_FRTBUF >= OFF_GRIDBUF + GRID_BUF_BYTES, "FRT relocated above GRID region");
static_assert(OFF_FRTBUF + FRT_BUF_BYTES <= BLT_DDR_SIZE,  "FRT must fit under the region end");
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

  // [Stage 1] Overlay channel (SOLARUS_OVERLAY). When enabled, every root draw
  // that is not the camera promote-blit is rendered by stock base SDL into the
  // root surface and composited LAST as one ARGB4444 per-pixel-alpha blit.
  bool overlay_enabled = false;
  bool overlay_touched = false;   // root was painted this frame -> composite it
  long g_overlay_draws = 0;       // diag: draws routed to the overlay
  long g_overlay_blits = 0;       // diag: overlay composites emitted
  long g_overlay_esc   = 0;       // diag: composites dropped (upload failed)

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
    uint8_t pal_id, pal_base;                  // [PAL8] CLUT bank/base when fmt==BLT_FMT_PAL8
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
    uint8_t pal_id, pal_base;                   // [PAL8] CLUT bank/base when fmt==BLT_FMT_PAL8
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
  // [pot diag, DIAGNOSTIC ONLY] SOLARUS_POT_DIAG=1 traces small sprite/tile draws
  // (<=32x32 src region) through emit_draw, so a destructible's entities-image draw
  // can be told apart -- on HW, by source identity and resolved SDRAM offset -- from a
  // tiles-image draw (e.g. deep_water). Answers: is the pot's blit even emitted, and
  // does its source resolve to the entities atlas or somewhere else?
  // Zero cost when unset; separate flag so it can run standalone.
  bool pot_diag = false;
  // Dedup by (source surface, src rect) so each DISTINCT source-region logs exactly once
  // across the session -- a static destructible logs one line no matter how many frames it
  // survives, and the trace can't push the pot past a per-frame cap on a busy screen.
  std::unordered_set<uint64_t> pot_diag_seen;
  static constexpr size_t POT_DIAG_MAX_LINES = 512;   // total output guard
  long g_fills = 0, g_blits = 0, g_escapes = 0, g_offtarget_draw = 0;
  // [Task 1] g_alias_blits split into its two conflated units: individual camera-
  // surface blits (draw() case 2) vs batched tile entries.
  // The old name is kept as their sum (see the [blitter diag] log) so existing
  // log-scraping still works.
  long g_sprite_blits = 0;   /* individual camera-surface blits (draw() case 2) */
  long g_tile_blits   = 0;   /* batched tile entries                            */
  long g_scroll_oldmap_blits = 0;   // [Stage 3a] old-map blits routed to the fabric
  long g_scroll_oldmap_clipped = 0; // [Stage 3a] old-map draws fully off-screen (no blit)
  // [Task 4 / Stage 2 / SOLARUS_SPRITECH] Sprite channel: camera-surface draws are
  // buffered into SP_BUF and flushed as one BLT_OP_SPRITELIST per uniform run.
  bool spritech = false;               // gate (default OFF; see the parse below)
  // [Stage 3a / SOLARUS_SCROLLFAB] When ON, a scrolling transition composites on the
  // FABRIC at engine-published offsets instead of falling back to a software map
  // render. g_transition_scroll stays as the flag-OFF baseline so the two can be
  // A/B'd on hardware. Default OFF until that A/B lands (#122/#123).
  bool scrollfab = false;
  // The bandaid applies only when we are mid scroll AND the fabric path is off.
  bool scroll_bandaid_active() const { return g_transition_scroll && !scrollfab; }
  // [Stage 3a] Additive destination bias for the framebuffer-writing TILE channels
  // (res_emit_bucket_ / res_emit_static_bucket_). Those
  // two derive their destination from the camera / plane clip, NOT from
  // alias_target, so they never see alias_off_x/y the way fill() and draw() case 2
  // do -- without this the new map's background and static tiles would composite at
  // their FINAL position from the first transition frame while its sprites animate.
  //
  // Deliberately NOT just `alias_off_x`: the legacy looks_like_promote() heuristic
  // (see draw()) also parks a NON-ZERO alias offset there, with SOLARUS_SCROLLFAB
  // off. Gating on `scrollfab` makes the flag-OFF path return a literal 0 at every
  // call site, so `+ scroll_bias_x()` is provably byte-identical when the flag is
  // unset -- which is the acceptance requirement for this branch.
  int scroll_bias_x() const { return (scrollfab && g_transition_scroll) ? alias_off_x : 0; }
  int scroll_bias_y() const { return (scrollfab && g_transition_scroll) ? alias_off_y : 0; }
  blt_sprite_channel_t spr_ch{};       // bounded ordered accumulator (blitter lib)
  // Counted UNCONDITIONALLY, not under `diag`: spr_records/spr_runs is the collapse
  // ratio the hardware-validation record has to report, and gating it on the diag
  // flag made it unavailable on exactly the plain runs being validated. They are
  // three `long` increments on a path that already does a DDR write per entry.
  long g_spr_records = 0;              // entries actually buffered into SP_BUF
  long g_spr_runs    = 0;              // OP_SPRITELIST commands emitted
  long g_spr_dropped = 0;              // entries refused at the cap / frame budget
  // spr_rec / spr_runs is the MEASURED collapse ratio the validation record reports.
  // [Task 1 review fix] em.dropped is PER-FRAME (reset in blt_begin_frame), but the
  // [blitter diag] line below is a 60-frame WINDOW of every other counter. Printing
  // em.dropped directly there only reflects the 60th frame, hiding drops on frames
  // 1-59 of the window. Accumulate into this window counter once per frame (in
  // present(), after all of the frame's commands -- including the overlay/FPS
  // overlay composite -- have been emitted, and before the next frame's
  // blt_begin_frame() resets em.dropped back to 0) and print/reset THIS instead.
  long g_dropped_win = 0;
  // [Stage 3a] DDR heap HIGH-WATER. em.heap_used is instantaneous and the heap is
  // never reset per frame, so a transient spike (e.g. two maps' sources co-resident
  // across a scroll edge) is invisible in a 60-frame diag sample. This is the ONLY
  // signal that can confirm or refute #123's heap premise -- note the [blitter inter]
  // line reads the SDRAM INTER arena, a DIFFERENT region, and cannot.
  size_t heap_peak = 0;
  // [Stage 3a review fix] Tiny compare-and-store, shared by both present() sample
  // sites (see call sites for why there are two: allocations from
  // flush_sprites_before_other_op()/emit_overlay_composite()/the FPS overlay emit
  // happen AFTER the first sample, later in the same present() call, so a single
  // sample point could miss an intra-frame peak).
  void sample_heap_peak() { if (em.heap_used > heap_peak) heap_peak = em.heap_used; }
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

  // [PAL8 v1] Paletted composition (SOLARUS_PALETTE, default OFF). Immutable file
  // assets that pal_extract() can express in <=256 colours are staged as a TRUE
  // 8bpp index plane (1 B/px, stride=w bytes -- Task 3.2; halves the perm SDRAM
  // footprint vs the earlier 16bpp-storage v1, the #84 headroom win) plus a CLUT
  // bank entry, instead of RGB565/ARGB4444. A surface with no entry in pal_handles
  // (flag off, or pal_extract failed -- e.g. the >256-colour ts9 tileset, or any
  // non-preloaded/mutable surface) simply falls through to the existing dual-format
  // path in upload()/emit_draw() unchanged.
  bool palette_enabled = false;
  pal_bankset pal_banks{};
  bool pal_any_packed = false;   // true once >=1 surface packed -> a CLUT upload is owed
  // [PAL8 v1 diag — review I-1/I-2] objective HW-validation gates: whether the 8bpp
  // win actually landed vs quietly fell back, and whether tinted paletted draws
  // re-stage a colour copy at gameplay (a narrow #84-class perm-growth vector).
  long g_pal_packed    = 0;   // surfaces staged as 8bpp PAL8 (the halving win)
  long g_pal_packfail  = 0;   // pal_extract OK but CLUT banks full -> 16bpp fallback (I-2)
  long g_pal_truecolor = 0;   // >256 colours (e.g. ts9) -> 16bpp (expected, not a concern)
  long g_pal_tint_restage = 0;// distinct paletted surfaces re-staged colour under tint (I-1)
  std::unordered_set<const SurfaceImpl*> pal_tint_seen;
  struct PalHandle {
    blt_surface_ref_t ref{};   // index-plane handle (heap/perm), TRUE 8bpp (Task 3.2)
    uint8_t bank = 0, base = 0;
    // Explicit ctors: in-class member initializers make this a non-aggregate under
    // the C++ standard the Solarus build uses (< C++17), so `PalHandle{r,bank,base}`
    // aggregate-init fails on armhf gcc though clang -std=c++17 accepts it. A 3-arg
    // ctor makes the brace-init valid across standards; the default ctor is for the
    // pal_handles map's operator[].
    PalHandle() = default;
    PalHandle(const blt_surface_ref_t& r, uint8_t bk, uint8_t bs) : ref(r), bank(bk), base(bs) {}
  };
  std::unordered_map<const SurfaceImpl*, PalHandle> pal_handles;

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
    pal_handles.erase(p);   // [PAL8 v1] defensive; immutable pal8 assets are quest-lifetime
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
    // [Task 3 / Stage 2] Bind the sprite-entry buffer to its own fixed DDR base --
    // separate from TL_BUF (see OFF_SPBUF's doc comment above for why it is NOT
    // immediately after TL_BUF as the brief assumed).
    blt_sprite_list_init(&em, (void*)(ddr + OFF_SPBUF), SP_BUF_BYTES);
    // [Task 4] The host-side accumulator writes entries STRAIGHT into that same
    // SP_BUF region (no staging copy), so a flush only has to emit headers pointing
    // at offsets already resident in DDR. SP_BUF holds 5461 entries but the channel
    // caps at BLT_SPRITE_CHANNEL_MAX (4096) -- blt_sprite_channel_init clamps.
    blt_sprite_channel_init(&spr_ch, &em, BLT_SPRITE_CHANNEL_MAX);
    // [Stage 3b Phase B1 Task 3] Bind the GRID_BUF region for BLT_OP_TILEMAP. Unlike
    // blt_tile_list_init/blt_sprite_list_init this takes the DDR-region-relative BYTE
    // OFFSET, not a host pointer: grid cells are written directly into this region by
    // the (future) grid-build call site, and blt_grid_list's cells_off argument packs
    // straight into the header -- see blt_grid_list_init's doc comment in blt_emitter.h.
    blt_grid_list_init(&em, OFF_GRIDBUF, GRID_BUF_BYTES);
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
    // [Stage 1] Engine truth beats the first-wins lottery. When MainLoop has
    // tagged the root, ONLY that surface is the target -- a transient 320x240
    // render texture can no longer steal the lock. Untagged (older engine, or
    // the tag not yet published at first draw) falls back to first-wins.
    // fpga_target is still assigned on this path (not just returned) so the
    // target_locked diagnostic stays meaningful.
    if (g_tagged_root) { if (&dst == g_tagged_root) fpga_target = &dst; return &dst == g_tagged_root; }
    if (!fpga_target) fpga_target = &dst;       // first wins
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
      // PERSISTENCE MODEL (the title/intro flashing fix). NOTE: MainLoop::draw()
      // (work/solarus/src/core/MainLoop.cpp) now calls root_surface->clear()
      // UNCONDITIONALLY every frame, not only when it wants a fresh frame as this
      // comment used to claim -- so for the root/camera surfaces that reach this
      // renderer's clear() as their backed path, clear_requested is set true and
      // the real-hardware-clear branch below runs every frame. The CARRY FORWARD
      // path described next still exists for any blitter-backed target whose
      // ensure_frame() is opened by a non-clear draw op (fill()/draw()/blit()) with
      // no clear() for that target this frame, and it is what protected the old
      // title/intro screen from flashing back when Solarus's clear was conditional:
      // the title screen composited its cloud background ONCE (during the
      // transition) then each frame redrew only the animated foreground (logo +
      // "press space") on top, relying on the previous frame's pixels surviving.
      // The old code unconditionally hardware-cleared the DDR buffer AND alternated
      // two buffers each frame, so a committed buffer only ever held THIS frame's
      // incremental draws on black: background present on the rare full-repaint
      // frame, gone (a bare logo on black) on every incremental frame -> the
      // flashing.
      //
      // To mirror that scenario on the fabric WITHOUT either flashing OR
      // single-buffer tearing, we keep the double buffer but CARRY FORWARD: on a
      // frame that reaches ensure_frame() without clear_requested set, copy the
      // previously-committed buffer's pixels into this frame's target buffer, then
      // let the fabric composite the incremental draws (clear=0) on top. Every
      // committed buffer therefore always holds the full, current image. When
      // clear_requested IS set (as it now always is on the path driven by root's
      // unconditional per-frame clear), we skip the copy and hardware-clear
      // instead (a genuine fresh frame).
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

  // [residency] Publish the current command batch and block until the fabric finishes
  // it. Used by the preload driver to drain a staging batch before reusing the DDR3
  // bounce heap. Mirrors present()'s doorbell (control-block writes + fence + C_SUBMIT)
  // and ensure_frame()'s C_DONE handshake.
  void submit_and_drain() {
    flush_sprites_before_other_op();   // [Task 4] never strand buffered sprites
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
    flush_sprites_before_other_op();   // [Task 4] FPS digits paint OVER the sprites
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

  // [Stage 1] Composite the overlay LAST: one full-screen ARGB4444 per-pixel-alpha
  // blit of the root surface over the finished fabric frame. The ring executes in
  // order, so "last" is purely a matter of emitting this immediately before
  // blt_end_frame().
  //
  // Composited EVERY frame the root was painted, NOT only when dirty: the DDR
  // framebuffer is hardware-cleared each frame (clear_requested), so a dirty-gated
  // composite would make a static HUD vanish on the first frame it wasn't redrawn.
  // Re-upload is already dirty-driven inside upload(), which refreshes in place
  // only when mark_src_dirty() flagged the pointer -- no extra tracking needed.
  // [coupling] Only reached from present()'s `if (d->frame_active)` block, and the
  // overlay draw path in draw() deliberately does NOT call ensure_frame() itself --
  // so this composite only ever lands in the ring because something ELSE already
  // opened the fabric frame. Today that is guaranteed by MainLoop::draw()'s
  // unconditional root_surface->clear(), which takes the backed branch in clear()
  // and sets clear_requested (which opens the frame). If the root clear ever stops
  // being backed (e.g. gets skip-if-clean'd), UI frames would silently never submit
  // -- no crash, no log, just a missing overlay. Do not "fix" this by adding
  // ensure_frame() here without re-auditing that coupling first.
  void emit_overlay_composite() {
    if (!overlay_enabled || !overlay_touched) return;
    flush_sprites_before_other_op();   // [Task 4] overlay composites LAST, over sprites
    const SurfaceImpl* root = g_tagged_root ? g_tagged_root : fpga_target;
    if (!root) return;
    // [size-guard] g_tagged_root is set by mister_tag_root_surface() and reaches
    // here WITHOUT going through is_fpga_target()'s 320x240 enforcement. Guard
    // explicitly so a differently-sized tagged root can never over-read into the
    // FB_W x FB_H blit below instead of just failing loud.
    if (root->get_width() != FB_W || root->get_height() != FB_H) return;
    blt_surface_ref_t ref = upload(*root, BLT_FMT_ARGB4444);
    if (!ref.valid) {           // heap/stage failure: counted (g_overlay_esc, reported
                                 // in the [blitter overlay] diag banner) and bounded,
                                 // not logged -- diag-gated counters are this file's
                                 // convention, not fprintf on the hot path.
      if (diag) g_overlay_esc++;
      return;
    }
    blt_blit(&em, ref, 0, 0, FB_W, FB_H, 0, 0, BLT_BLEND_PALPHA, 0, 255, 0);
    if (diag) g_overlay_blits++;
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
  void preload_quest_assets(Solarus::ResourceProvider* rp) {
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

        // [#84 Tier-2] For a TILESET tiles image (tilesets/<id>.tiles.png), stage the
        // ResourceProvider's SHARED Tileset surface — the exact SurfaceImpl* gameplay
        // draws (Map::load -> resource_provider.get_tileset(id) -> get_tiles_image()).
        // Registering THAT pointer (not a fresh Surface::create copy) makes gameplay's
        // pal_handles/immutable_set lookup HIT, so tiles use the preloaded PALETTED
        // perm copy instead of re-staging their own 16bpp into the tiny INTER region
        // (the #84 overflow). Falls back to Surface::create if rp is null or the id
        // fails to load. `get_tileset` force-loads + caches (persistent), so this also
        // primes the cache before the first map.
        Solarus::SurfacePtr surf;
        {
          static const std::string TS_PRE = "tilesets/", TS_SUF = ".tiles.png";
          if (rp && path.size() > TS_PRE.size() + TS_SUF.size() &&
              path.compare(0, TS_PRE.size(), TS_PRE) == 0 &&
              path.compare(path.size() - TS_SUF.size(), TS_SUF.size(), TS_SUF) == 0) {
            const std::string id =
                path.substr(TS_PRE.size(), path.size() - TS_PRE.size() - TS_SUF.size());
            try {
              surf = rp->get_tileset(id).get_tiles_image();   // shared with gameplay
            } catch (...) { surf = nullptr; }                 // bad/undecodable tileset -> skip
          }
          if (!surf)
            surf = Solarus::Surface::create(path, Solarus::Surface::DIR_DATA);
        }
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
        // [PAL8 v1] When enabled, try the paletted path FIRST: pal_extract fails
        // (returns false) for anything with >256 distinct colours (e.g. the ts9
        // truecolor tileset) or a null surface, in which case did_pal stays false
        // and we fall through to the EXISTING dual-format guess below, unchanged.
        // When the flag is off, palette_enabled is false and this block is not
        // entered at all -- a pure no-op vs. the pre-#PAL8 code.
        bool did_pal = false;
        if (palette_enabled && pss) {
          pal_surface ps;
          if (pal_extract(pss, &ps)) {
            did_pal = preload_stage_pal8(impl, ps);
            std::free(ps.index);
            if (did_pal) ++g_pal_packed;      // 8bpp win
            else         ++g_pal_packfail;    // [I-2] CLUT banks full -> 16bpp fallback
          } else {
            ++g_pal_truecolor;                // >256 colours -> 16bpp (expected)
          }
        }
        if (!did_pal) {
          uint8_t pfmt = (pss && pss->format && SDL_ISPIXELFORMAT_ALPHA(pss->format->format))
                       ? BLT_FMT_ARGB4444 : BLT_FMT_RGB565;
          preload_stage_one(impl, pfmt);
        }
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
    // [PAL8 v1] Every immutable asset's palette was packed first-fit as the walk above
    // ran, so the whole CLUT bankset is stable and complete exactly once here, after
    // the last asset. One DMA upload for the whole quest -- nothing repacks a bank
    // after this point in v1 (only preload assets participate in PAL8 packing).
    if (palette_enabled && pal_any_packed) {
      std::vector<uint8_t> clut_bytes(CLUTBUF_BYTES);
      pal_bankset_bytes(&pal_banks, clut_bytes.data());
      for (uint32_t i = 0; i < CLUTBUF_BYTES; ++i) ddr[OFF_CLUTBUF + i] = clut_bytes[i];
      blt_begin_frame(&em, target_buf, /*clear=*/0, /*clear_color=*/0x0000);
      blt_emit_clut_upload(&em, OFF_CLUTBUF, CLUT_BANKS * CLUT_ENTRIES);
      submit_and_drain();
      std::fprintf(stderr, "[MiSTer blitter] PAL8: CLUT bankset uploaded (%u banks touched)\n",
          [&]{ unsigned n = 0; for (auto u : pal_banks.used) if (u) ++n; return n; }());
    }
    // [PAL8 v1 diag — review I-2] report the paletted-vs-fallback census so HW
    // validation can confirm the halving actually landed (not just "no overflow").
    // The perm-used figure below is the objective halving evidence vs the 16bpp
    // baseline; CLUT-overflow near 0 means (almost) every surface got the 8bpp win.
    if (palette_enabled)
      std::fprintf(stderr,
          "[MiSTer blitter] PAL8 residency: %ld surfaces 8bpp-paletted, "
          "%ld CLUT-overflow->16bpp, %ld truecolor->16bpp\n",
          g_pal_packed, g_pal_packfail, g_pal_truecolor);
    // [footprint] report perm high-water so we can size the SDRAM region / die-fit.
    uint32_t used = blt_alloc_used(&em.sdram_perm);
    std::fprintf(stderr,
        "[MiSTer blitter] preload complete: perm used %u bytes (%.2f MiB), "
        "base 0x%08x end 0x%08x (die boundary 0x04000000)\n",
        used, used / (1024.0 * 1024.0), SDRAM_PERM_BASE, SDRAM_PERM_BASE + used);
  }

  // [Task 3.2] Raw 1-byte/pixel upload of an index plane into the DDR3 bounce
  // heap (em.alloc), mirroring blt_emitter.c's upload16() exactly but at true
  // 8bpp instead of 16bpp -- blt_upload()/blt_upload_argb4444() both hard-code
  // 2 bytes/pixel (stride = w*2) so neither can stage a byte-per-pixel plane;
  // there is no engine-agnostic upload entry point for 8bpp in the vendored
  // emitter, so this stays local to the renderer (raw blt_alloc + memcpy, same
  // free-list heap, same handle shape). Comp_pipeline's PAL8 gpix math (Task
  // 3.1, comp_pipeline.sv `is_pal8`) reads source at 1 B/px and expects
  // c_src_stride == width in BYTES, so `r.stride`/`r.size` here MUST reflect
  // w*h bytes (not w*h*2) -- blt_blit_pal8 forwards s.stride/s.off verbatim
  // into the command, so getting this handle's geometry right is the whole fix.
  blt_surface_ref_t upload_pal8_raw(const uint8_t* indices, int w, int h) {
    blt_surface_ref_t r{};
    if (w < 0 || h < 0 || (size_t)w > 0xFFFFu || (size_t)h > 0xFFFFu) {
      em.overflow = 1;
      return r;
    }
    const size_t stride = (size_t)w;          // 1 B/px -- matches Task 3.1's gpix>>0
    const size_t need = (size_t)h * stride;
    uint32_t off = blt_alloc(&em.alloc, (uint32_t)need);
    if (off == BLT_ALLOC_FAIL) { em.overflow = 1; return r; }
    // ps.index is already tight-packed row-major with stride == w (palette_atlas.h
    // contract), so this is a single flat memcpy -- no per-row loop needed.
    std::memcpy(em.heap + (size_t)off, indices, need);
    em.heap_used = blt_alloc_used(&em.alloc);
    r.off = off; r.stride = (uint16_t)stride;
    r.w = (uint16_t)w; r.h = (uint16_t)h; r.format = BLT_FMT_PAL8; r.valid = 1;
    r.size = (uint32_t)need;
    r.sdram_off = BLT_ALLOC_FAIL;   // unstaged until blt_stage_surface_perm
    return r;
  }

  // [PAL8 v1] Stage one PAL8-eligible immutable surface: pack its CLUT into the
  // renderer's bankset (first-fit across the PAL_CLUT_BANKS fabric banks) and stage
  // its index plane into the PERMANENT SDRAM region at TRUE 8bpp (1 B/px, stride=w
  // bytes -- Task 3.2; halves the footprint vs the prior 16bpp-storage v1), mirroring
  // preload_stage_one's bounce-drain/perm-exhaustion handling exactly. Returns false
  // only on CLUT-bank exhaustion (pal_pack failed) so the caller falls back to the
  // existing RGB565/ARGB4444 path for this one surface; dies loudly on perm
  // exhaustion, same contract as preload_stage_one (no silent fallback for a
  // footprint problem).
  bool preload_stage_pal8(const SurfaceImpl& impl, const pal_surface& ps) {
    uint8_t bank, base;
    if (!pal_pack(&pal_banks, &ps, &bank, &base)) {
      std::fprintf(stderr,
          "[MiSTer blitter] PAL8: CLUT banks exhausted (surface has %d colours); "
          "falling back to RGB565/ARGB4444 for this surface\n", ps.ncolors);
      return false;
    }
    pal_any_packed = true;

    em.overflow = 0;
    blt_surface_ref_t r = upload_pal8_raw(ps.index, ps.w, ps.h);
    if (r.valid) blt_stage_surface_perm(&em, &r);
    if (em.perm_overflow) {
      Solarus::Debug::die("[residency] permanent SDRAM region exhausted during "
                          "PAL8 preload; quest asset footprint exceeds the region cap");
    }
    if (em.overflow) {
      // DDR3 bounce full: drain this batch, reset the bounce, retry this asset once
      // (same recovery sequence as preload_stage_one).
      em.overflow = 0;
      emit_loadbar_fills();
      submit_and_drain();
      blt_heap_reset(&em);
      blt_begin_frame(&em, target_buf, /*clear=*/0, /*clear_color=*/0x0000);
      r = upload_pal8_raw(ps.index, ps.w, ps.h);
      if (r.valid) blt_stage_surface_perm(&em, &r);
      if (em.perm_overflow)
        Solarus::Debug::die("[residency] permanent SDRAM region exhausted during PAL8 preload");
      if (em.overflow)
        Solarus::Debug::die("[residency] single PAL8 asset exceeds the DDR3 bounce heap");
    }
    if (!r.valid) return false;   // defensive: unexpected upload failure other than overflow

    pal_handles[&impl] = PalHandle{ r, bank, base };
    return true;
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
  bool to_argb4444(SDL_Surface* s, std::vector<uint16_t>& out,
                   bool unpremultiply = false) {
    out.resize((size_t)s->w * s->h);
    // [#52] fast path: NEON/scalar pack straight from the source's 32-bit pixels,
    // bypassing SDL_ConvertSurfaceFormat's per-pixel SDL_Blit_Slow.
    // [Stage 1] A premultiplied source (render targets: Surface::create defaults
    // premultiplied=true) must have alpha divided back out first, or the fabric's
    // straight-alpha PALPHA multiplies by alpha a second time.
    if (unpremultiply) {
      if (mpix::to_argb4444_unpremultiplied(s, out.data())) return true;
    } else {
      if (mpix::to_argb4444(s, out.data())) return true;
    }
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
        // No a==0/a==255 short-circuit here: mpix::unpremul_channel already handles
        // both (0 -> 0, 255 -> identity). Guarding them out would make this fallback
        // pack the source's RGB nibbles at a==0 while the fast path emits 0x0000 --
        // a fast-path/fallback divergence, which is exactly the bug class this
        // un-premultiply work exists to remove.
        if (unpremultiply) {
          r = mpix::unpremul_channel(r, a);
          g = mpix::unpremul_channel(g, a);
          b = mpix::unpremul_channel(b, a);
        }
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
      if (!to_argb4444(s, px, src.is_premultiplied())) return false;
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
      if (!to_argb4444(s, px, src.is_premultiplied())) return r;
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
                         uint8_t& fl, uint8_t& fmt, uint8_t& pal_id, uint8_t& pal_base) {
    Rectangle ti_region; Point ti_dst, ti_origin(0, 0); Scale ti_scale(1.f);
    DrawInfos ti(ti_region, ti_dst, ti_origin, blend, /*opacity=*/255,
                 /*rotation=*/0.0, ti_scale, null_proxy);
    uint8_t cr, cg, cb; int why = 0;
    if (!map_blend(tsimg, ti, bl, key, fl, fmt, why, cr, cg, cb)) return false;
    if (fl & BLT_F_COLORMOD) return false;        // tiles are white; never hit
    pal_id = 0; pal_base = 0;
    // [PAL8 tile-list, #84] If this tileset was staged paletted (index plane +
    // CLUT bank), render its tiles PAL8 too: report fmt=BLT_FMT_PAL8 + the bank/base
    // so the emit path points BLT_OP_TILELIST at the 8bpp index atlas and packs
    // pal_id/base into the header colour field. The CLUT carries per-index alpha, so
    // a paletted tileset covers BOTH its opaque and translucent tiles (map_blend's
    // RGB565/ARGB4444 choice is overridden). Truecolor tilesets (no pal_handle) keep
    // the 16bpp path unchanged. Only when the flag is on (pal_handles is else empty).
    auto pit = pal_handles.find(&tsimg);
    if (pit != pal_handles.end()) {
      fmt = BLT_FMT_PAL8;
      pal_id = pit->second.bank; pal_base = pit->second.base;
      tex = pit->second.ref;
      return tex.valid;
    }
    // [#84 ROOT-CAUSE FIX] This tileset is NOT in pal_handles/immutable_set. The
    // whole-quest preload keys residency by its OWN Surface::create() objects, but
    // gameplay draws the *Tileset*'s surface — a different SurfaceImpl* — so the
    // lookup always misses. upload() then routes this surface to the 4 MiB INTER
    // (mutable) region, where ~0.9 MiB/tileset overflows past the region ceiling at
    // the ~6th distinct tileset -> garbage source (the real #84). A tileset is a
    // quest-lifetime IMMUTABLE asset, so mark it immutable HERE: upload() stages it
    // to the 64 MiB PERM region instead (holds all of MoSDX's ~20 tilesets), and it
    // stays resident for the rest of the session. (16bpp; paletting these on-demand
    // is a separate optimization — it would double-count CLUT banks vs the dead
    // preload copies. See [[solarus-120-paletted-hw-validation-fail]].)
    if (!is_immutable(&tsimg)) immutable_set.insert(&tsimg);
    tex = upload(tsimg, fmt);
    return tex.valid;
  }

  // [PAL8 tile-list] Resolve a recorded tile bucket's source ref + wire colour field
  // at emit time. Paletted buckets (fmt==PAL8) point at the SDRAM-resident 8bpp index
  // atlas and carry pal_id/base_off in the colour field; all others take the 16bpp
  // upload path with colour 0. Shared by both tile-list emit sites (resident
  // static, resident RES).
  blt_surface_ref_t res_bucket_emit_tex(const SurfaceImpl* tsimg, uint8_t fmt,
                                        uint8_t pal_id, uint8_t pal_base, uint16_t& color) {
    color = 0;
    if (fmt == BLT_FMT_PAL8) {
      auto pit = pal_handles.find(tsimg);
      if (pit == pal_handles.end()) return blt_surface_ref_t{};   // defensive: lost handle -> skip
      color = blt_pal_color(pal_id, pal_base);
      return pit->second.ref;
    }
    return upload(*tsimg, fmt);
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
        "blend=%d fmt=%d key=%04x sdram_off=0x%08x valid=%d onscreen=%d\n",
        stage, (const void*)&src, src.get_width(), src.get_height(),
        r.get_x(), r.get_y(), r.get_width(), r.get_height(), dst_x, dst_y,
        blend, fmt, (unsigned)key, h ? (unsigned)h->sdram_off : 0u,
        h ? (int)h->valid : 0, onscreen);
  }

  // `out_clipped` (optional) reports WHICH of the two `true` outcomes happened:
  // false = a blit was actually emitted, true = the draw was fully off-screen and
  // nothing was emitted. Defaulted to nullptr so every existing caller is unaffected;
  // it is only written on the return-true paths.
  bool emit_draw(const SurfaceImpl& src, const DrawInfos& infos,
                 int off_x, int off_y, bool* out_clipped = nullptr) {
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
    // [PAL8 v1] A preloaded paletted surface takes the forced-format PAL8 path
    // instead of upload()'s RGB565/ARGB4444 pick -- SAME blend/key/flags from
    // map_blend above (has_alpha still selects BLEND_PALPHA; the fabric sources
    // per-pixel alpha from the CLUT's A4 for PAL8 instead of the ARGB4444 pixel
    // bits, see comp_pipeline.sv s3_skip_eff). Colour-mod is NOT supported for
    // PAL8 in v1 (comp_pipeline bypasses it for PAL8), so a tinted draw of a
    // paletted surface still falls through to the existing direct-colour path.
    // When palette_enabled is false, `pal8` is always nullptr and every line
    // below this comment is dead code -- the pre-existing upload()/blt_blit(_mod)
    // path runs unchanged.
    const PalHandle* pal8 = nullptr;
    if (palette_enabled && !(flags & BLT_F_COLORMOD)) {
      auto pit = pal_handles.find(&src);
      if (pit != pal_handles.end()) pal8 = &pit->second;
    }
    // [PAL8 v1 diag — review I-1] a tinted draw of a paletted surface can't use the
    // fabric PAL8 path (comp_pipeline bypasses colour-mod for PAL8 in v1), so it
    // falls to upload() -> a one-time colour re-stage into perm (bounded + cached;
    // NOT the unbounded per-tileset #84 mechanism). Count the DISTINCT surfaces this
    // hits so HW validation can confirm the perm growth is negligible; if it isn't,
    // the follow-up is to route this fallback off the permanent region.
    if (diag && palette_enabled && (flags & BLT_F_COLORMOD)
        && pal_handles.count(&src) && pal_tint_seen.insert(&src).second)
      ++g_pal_tint_restage;
    blt_surface_ref_t h = pal8 ? pal8->ref : upload(src, want_fmt);
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
    if (!onscreen) { if (out_clipped) *out_clipped = true; return true; }
    // colormod rides alongside the clip (post-clip): blt_blit_mod when the flag is
    // set, plain blt_blit otherwise (hot path stays unchanged). [PAL8 v1] a paletted
    // source (pal8 != nullptr, colormod already excluded above) takes blt_blit_pal8
    // instead, carrying (bank,base) in the command's color field.
    if (pal8) {
      // [review M-4] INVARIANT: pal8->bank < CLUT_BANKS (32). pal_pack() only ever
      // returns a bank in [0,CLUT_BANKS); the fabric decodes pal_id[4:0] (5 bits) for
      // its 32 banks, so a bank>=32 would silently ALIAS onto banks 0-31. If CLUT_BANKS
      // is ever raised past 32, comp_pipeline's clut_rd_addr must widen the pal_id slice
      // (it takes c_pal_id[4:0]) and blt_pal_color must carry the extra bit(s).
      blt_blit_pal8(&em, h, sx, sy, bw, bh, bdx, bdy, blend, key, infos.opacity, flags,
                    pal8->bank, pal8->base);
    } else if (flags & BLT_F_COLORMOD) {
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

  // ─── [Task 4 / Stage 2] Sprite channel ──────────────────────────────────────
  //
  // Buffer a camera-surface draw as a 24-byte blt_sprite_entry_t in SP_BUF instead
  // of emitting its own OP_BLIT, so a whole run of compatible sprites collapses into
  // ONE OP_SPRITELIST command at flush time.
  //
  // Return value is THREE-valued, not the two-valued bool the plan sketched -- the
  // extra state is load-bearing for correctness, not convenience:
  //    1 = buffered
  //    0 = cap reached, entry dropped (counted)
  //   -1 = NOT batchable; the caller must flush the channel and then emit_draw()
  //        this draw normally.
  // [Task 4b] The entry now carries a per-entry palette word, so a PAL8 source IS
  // expressible (220/220 of the quest's sprite sheets are paletted -- without this the
  // channel would carry zero real sprites). A colour-modulated draw still cannot be:
  // the tint lives in the command's reserved bytes and has no per-entry slot. Escapes
  // (map_blend/upload failure) likewise have to go down emit_draw's existing escape
  // accounting. Folding those into "false" would have made them indistinguishable
  // from a cap drop and silently deleted them from the frame.
  int sprite_channel_push(const SurfaceImpl& src, const DrawInfos& infos,
                          int off_x, int off_y) {
    uint8_t blend, flags, want_fmt; uint16_t key; int why = 0;
    uint8_t cm_r, cm_g, cm_b;
    // Same source resolution as emit_draw: identical map_blend + upload() path.
    if (!map_blend(src, infos, blend, key, flags, want_fmt, why, cm_r, cm_g, cm_b))
      return -1;                       // escape: let emit_draw account for it
    if (flags & BLT_F_COLORMOD) return -1;              // needs blt_blit_mod
    // [Task 4b] PAL8 no longer escapes: the entry carries its OWN palette word, so a
    // paletted sprite batches like any other. Resolved EXACTLY as emit_draw does
    // (same pal_handles lookup, same colormod exclusion, same ref preference) -- a
    // second derivation here could drift from the shipping blit path.
    const PalHandle* pal8 = nullptr;
    if (palette_enabled) {
      auto pit = pal_handles.find(&src);
      if (pit != pal_handles.end()) pal8 = &pit->second;
    }
    blt_surface_ref_t h = pal8 ? pal8->ref : upload(src, want_fmt);
    if (!h.valid) return -1;           // escape: let emit_draw account for it
    ensure_frame();
    const Rectangle& r = infos.region;
    Rectangle dr = infos.dst_rectangle();
    int sx = r.get_x(), sy = r.get_y(), bw = r.get_width(), bh = r.get_height();
    int bdx = dr.get_x() + off_x, bdy = dr.get_y() + off_y;
    // SAME clip emit_draw applies. An UNCLIPPED entry would make the fabric read
    // outside the source surface -- the exact defect that produced the flashing
    // intro clouds (fixed by adding this host-side clip; see the clip_to_fb note).
    // The channel carries no per-batch bias (headers are emitted with bias 0,0), so
    // clipping here is in final framebuffer coordinates, exactly as in emit_draw.
    // Returns 1 (handled -- the caller must NOT fall through to emit_draw) but buffers
    // nothing, so it is deliberately NOT counted in g_spr_records: that counter is the
    // NUMERATOR of the reported collapse ratio and must mean "entries actually in
    // SP_BUF", or an off-screen-heavy scene inflates the ratio with sprites the fabric
    // never saw. Counting happens at the accepted push below, for the same reason.
    if (!clip_to_fb(sx, sy, bw, bh, bdx, bdy, flags)) return 1;  // fully off-screen:
                                                    // nothing to draw, NOT an escape
                                                    // (matches emit_draw's early-out)
    // Per-command SDRAM source select, resolved EXACTLY as blt_blit does. This must
    // ride in the run key: under global C_SRCSEL a staged and an un-staged source
    // cannot share one header, or the fabric would read a DDR3 offset out of SDRAM.
    uint8_t ent_flags = flags;
    uint32_t src_off  = h.off;
    if (em.sdram_src && h.sdram_off != BLT_ALLOC_FAIL) {
      src_off    = h.sdram_off;
      ent_flags |= BLT_F_SRC_SDRAM;
    }
    blt_sprite_run_key_t k;
    k.src_stride = h.stride;
    // blt_blit_pal8 FORCES the command format to BLT_FMT_PAL8 rather than taking it
    // from the handle; mirror that so a paletted handle can never emit a header
    // claiming a 16bpp source (the fabric reads PAL8 at 1 B/px).
    k.format     = pal8 ? (uint8_t)BLT_FMT_PAL8 : h.format;
    k.blend      = blend;
    k.alpha      = infos.opacity;
    k.colorkey   = key;
    k.flags      = ent_flags;
    blt_sprite_entry_t e;
    memset(&e, 0, sizeof e);       // reserved/padding bytes must be deterministic
    e.src_off = src_off;
    e.src_x = (uint16_t)sx; e.src_y = (uint16_t)sy;
    e.w     = (uint16_t)bw; e.h     = (uint16_t)bh;
    e.dst_x = (int16_t)bdx; e.dst_y = (int16_t)bdy;
    // [Task 4b] PER-ENTRY palette -- same (bank, base) blt_blit_pal8 receives in
    // emit_draw, packed by the same blt_pal_color(). The same CLUT-bank invariant
    // applies (bank < CLUT_BANKS == 32; see the [review M-4] note in emit_draw).
    e.color = pal8 ? blt_pal_color(pal8->bank, pal8->base) : (uint16_t)0;
    if (!blt_sprite_channel_push(&spr_ch, &k, &e)) return 0;    // cap reached
    g_spr_records++;               // ONE entry actually buffered (see the clip note)
    if (diag)
      ps_add((const void*)&src, r.get_x(), r.get_y(), r.get_width(), r.get_height(),
             dr.get_x() + off_x, dr.get_y() + off_y, src.get_width(), src.get_height());
    return 1;
  }

  // Emit the buffered sprites as one BLT_OP_SPRITELIST per maximal run of entries
  // whose run keys are equal, then reset the channel. Runs are walked in push order
  // and the fabric executes the ring strictly in order, so the emitted sequence
  // paints in exactly the order the draws arrived -- that IS the Z-order argument.
  //
  // `layer` is DIAGNOSTIC ONLY (the entries already carry final framebuffer
  // coordinates, and headers are emitted with bias 0,0); pass -1 when flushing for
  // a reason that isn't a layer boundary.
  void sprite_channel_flush(int layer) {
    (void)layer;
    if (spr_ch.count <= 0) return;
    ensure_frame();
    // Run-splitting + header emission lives in the blitter library so the host test
    // (test_spritelist.c) exercises the SHIPPING flush rather than a model of it.
    g_spr_runs += blt_sprite_channel_flush(&spr_ch, /*bias_x=*/0, /*bias_y=*/0);
    alias_drawn_this_frame = true;
  }

  // Ordering guard. The channel holds draws that have NOT reached the ring yet, so
  // ANY other command that writes the framebuffer must be preceded by a flush or it
  // would paint UNDER sprites that were issued before it. Called at the top of every
  // other framebuffer-writing emit path (tile lists, background-plane COPY, fills,
  // the overlay composite, end-of-frame) -- which makes correct ordering a property
  // of this renderer alone and independent of where the engine chooses to call
  // sprite_channel_flush() from.
  inline void flush_sprites_before_other_op() {
    if (spritech && spr_ch.count > 0) sprite_channel_flush(-1);
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
void mister_preload_quest_assets(Solarus::ResourceProvider* rp) {
  if (g_active_impl) g_active_impl->preload_quest_assets(rp);
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
  self->d->pot_diag     = (std::getenv("SOLARUS_POT_DIAG") != nullptr);      // [pot] small-draw source trace
  // [#52 resident, Task 7] Single gate — the resident fabric-resolved tile list is the
  // ONLY animated-tile path when the blitter is live (default OFF).
  self->d->res_enabled = mister_flag_default_on("SOLARUS_TILERESIDENT");  // HW-validated default ON (required for animated tiles)
  if (self->d->res_enabled)
    std::fprintf(stderr, "[MiSTer blitter] resident tile-list ENABLED (fabric TILELIST_RES)\n");
  // [Stage 1] Overlay channel. NEW and not yet HW-validated, so it ships OFF and
  // is opt-in; the default-on flip follows hardware validation (the earlier
  // background-plane-bake precedent, since removed in Stage 3b).
  // [HW-validated 2026-07-18] Flipped DEFAULT-ON. On-device A/B on MoSDX: 7-8 root
  // draws/frame reroute fabric->overlay (blits 420 -> 0), draws=480 composites=60
  // dropped=0, escape=0, overflow=0. Operator verified the intro screen (a case that
  // previously fell through to base SDL and vanished) and a parallax room.
  // KNOWN RESIDUAL (#124): translucent menus UNDER-dim the still-visible world, while
  // the pre-overlay path OVER-dims it. Operator judged overlay-ON the least-bad of the
  // two and chose to ship it.
  // NOTE the semantics change with this flip: the old opt-in form was PRESENCE-based
  // (getenv != nullptr), so SOLARUS_OVERLAY=0 still ENABLED it. mister_flag_default_on
  // treats a leading '0' as off, so "SOLARUS_OVERLAY=0" now correctly opts OUT.
  self->d->overlay_enabled = mister_flag_default_on("SOLARUS_OVERLAY");
  if (self->d->overlay_enabled)
    std::fprintf(stderr, "[MiSTer blitter] overlay channel ENABLED (SOLARUS_OVERLAY)\n");
  // [PAL8 v1] Paletted composition. DEFAULT-ON (Phase 5 flag-flip): HW-validated with
  // the 32-bank CLUT RBF (Solarus_20260713) — tiles + sprites decode via CLUT, the #84
  // tile corruption is resolved, and perm footprint ~halves. REQUIRES the PAL8-capable
  // fabric (32-bank RBF); the deploy ships engine + RBF together. Set SOLARUS_PALETTE=0
  // to force the pre-existing 16bpp dual-format path (e.g. on a pre-PAL8 core).
  // [Task 4 / Stage 2] Sprite channel. Ordered per-frame sprite list replacing the
  // alias_target replay.
  // [2026-07-20] Default flipped ON. HW-validated in the Stage 2 session (~16k
  // frames, 218k sprites, operator-confirmed) -- see
  // docs/superpowers/2026-07-19-stage2-hw-validation.md -- and it is additionally
  // the configuration every Stage 3a leg ran under (diag.env pins SPRITECH=1 for
  // both A/B legs). Leaving it OFF while SOLARUS_SCROLLFAB went ON would have
  // shipped an untested pairing: the Stage 3a old-map branch calls
  // flush_sprites_before_other_op(), which only orders anything when the sprite
  // channel is live. SOLARUS_SPRITECH=0 restores the direct emit_draw path.
  self->d->spritech = mister_flag_default_on("SOLARUS_SPRITECH");
  if (self->d->spritech)
    std::fprintf(stderr, "[MiSTer blitter] sprite channel ENABLED (SOLARUS_SPRITECH)\n");
  // [2026-07-20] Default flipped ON after HW validation: the fabric old-map branch
  // fires (scroll_oldmap nonzero), no old-map blit is ever fully clipped
  // (scroll_oldclip=0/116 windows), both axes are sign-correct including the
  // negative-dy destination-clip branch, overflow/dropped are 0, and the
  // alias-offset latch found during that session is fixed and regression-tested.
  // See docs/superpowers/2026-07-20-stage3a-hw-validation.md. SOLARUS_SCROLLFAB=0
  // restores the g_transition_scroll software path, which is deliberately retained
  // as the escape hatch and is NOT deleted by this change.
  self->d->scrollfab = mister_flag_default_on("SOLARUS_SCROLLFAB");
  if (self->d->scrollfab)
    std::fprintf(stderr, "[MiSTer blitter] scroll fabric path ENABLED (SOLARUS_SCROLLFAB)\n");
  self->d->palette_enabled = mister_flag_default_on("SOLARUS_PALETTE");
  if (self->d->palette_enabled) {
    pal_bankset_init(&self->d->pal_banks);
    std::fprintf(stderr, "[MiSTer blitter] paletted composition ENABLED (SOLARUS_PALETTE, "
                         "8bpp index storage)\n");
  }
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
  if (&surf == g_tagged_prev_map) g_tagged_prev_map = nullptr;  // drop the stale tag
  if (&surf == g_tagged_root) g_tagged_root = nullptr;   // drop the stale tag
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
                 (d->alias_target == &dst && dst.get_width() == FB_W && !d->scroll_bandaid_active()));
  if (backed) {
    // [Task 4] A hardware clear wipes the framebuffer, so sprites buffered for this
    // frame would paint over a surface they were never meant to survive into. Drop
    // them (do NOT flush: emitting them here would resurrect pre-clear content).
    if (d->spritech) blt_sprite_channel_reset(&d->spr_ch);
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
               dst.get_width() == FB_W && !d->scroll_bandaid_active();
  if (root || alias) {
    // [Task 4] A fill writes the same framebuffer, so buffered sprites must reach
    // the ring first or the fill would paint UNDER draws that preceded it.
    d->flush_sprites_before_other_op();
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
  {
    // [Stage 3a] Normally the full-screen camera composites at (0,0). During a
    // SCROLL with SOLARUS_SCROLLFAB on, the new map is drawn at an animating offset
    // published from engine truth this frame -- composite there instead. clip_to_fb
    // (emit_draw / sprite_channel_push) drops the half that is off-screen. The rule
    // (including clearing the offset the frame the scroll ENDS) lives in
    // mister_scroll_alias_update() so this site and resident_begin_frame() cannot
    // drift -- they did, and the latched offset misaligned entities from the
    // background by the last transition's direction.
    const bool cam_changed = d->camera_tag && g_tagged_camera &&
                             !d->scroll_bandaid_active() &&
                             d->alias_target != g_tagged_camera;
    if (cam_changed) d->alias_target = g_tagged_camera;
    mister_scroll_alias_update(d->alias_off_x, d->alias_off_y,
                               d->scrollfab, g_transition_scroll, cam_changed,
                               d->alias_target == g_tagged_camera,
                               g_scroll_new_dx, g_scroll_new_dy);
    if (cam_changed && d->diag)
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
    if (&src == d->alias_target && d->alias_drawn_this_frame && !d->scroll_bandaid_active()) {
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
    if (!d->alias_target && !d->scroll_bandaid_active() && d->looks_like_promote(src, infos)) {
      d->alias_target = &src;
      Rectangle dr = infos.dst_rectangle();
      d->alias_off_x = dr.get_x();
      d->alias_off_y = dr.get_y();
      if (d->diag)
        std::fprintf(stderr,
          "[blitter alias] camera surface=%p aliased -> DDR fb at offset (%d,%d)\n",
          (const void*)&src, d->alias_off_x, d->alias_off_y);
    }
    // [Stage 3a / SOLARUS_SCROLLFAB] The OLD map during a scrolling transition.
    // TransitionScrolling blits previous_map_surface onto the root at an animating
    // offset; without this it would fall into the overlay channel and be re-composited
    // in software every frame. Its pixels do NOT change during the scroll, so the
    // handles cache keeps the uploaded source resident: one upload for the whole
    // transition, then a fabric blit per frame at the engine-published offset.
    // TRAP -- pass (0,0), NOT g_scroll_old_dx/dy. emit_draw's off_x/off_y are an
    // ADDITIVE translation (bdx = dr.get_x() + off_x), not a position override, and
    // infos.dst_position ALREADY IS the scroll offset: TransitionScrolling::draw
    // issues this blit at `previous_map_dst_position - current_scrolling_position`,
    // which is the very expression get_mister_scroll_offsets publishes into
    // g_scroll_old_dx/dy. Passing them again doubles the offset (the old map slides
    // at 2x and then vanishes entirely once |off| reaches the fb extent along the
    // scroll AXIS -- FB_W for a horizontal transition, FB_H for a vertical one --
    // because the doubled position clips fully off-screen and emit_draw returns true). The
    // g_scroll_old_dx/dy globals remain the diagnostic/consistency record only.
    // Same-frame consistency needs no override anyway: mister_set_transition is
    // published at the top of Game::draw before any map draw, and
    // TransitionScrolling::draw uses that same current_scrolling_position.
    // The g_tagged_prev_map null check is load-bearing: a Direction::CLOSING scrolling
    // transition sets g_transition_scroll but never calls set_previous_surface(), so
    // the tag stays null with all offsets 0 -- do not "simplify" it away.
    if (d->scrollfab && g_transition_scroll && g_tagged_prev_map && &src == g_tagged_prev_map) {
      // [Task 6] This branch writes the framebuffer, so the buffered camera sprites
      // must reach the ring FIRST -- the ring executes in order, so "emitted later"
      // means "composited on top". Restores the invariant that every FB-writing path
      // flushes the sprite channel before it emits (same convention as the root-blit
      // path below). It sits INSIDE the guard so non-scroll frames, where the branch
      // does not emit, are unaffected.
      //
      // Note this puts the OLD map ABOVE the new map's tiles on the fabric, which is
      // the INVERSE of the engine's own paint order: TransitionScrolling::draw draws
      // the old map FIRST and the new map SECOND, so by that order new-map content
      // belongs on top. It is safe here for one reason only, and it is a load-bearing
      // invariant rather than a happy accident: previous_map_dst_position and
      // current_map_dst_position are ADJACENT, DISJOINT, camera-sized rectangles that
      // together tile the scroll, so the two maps never cover the same pixel and the
      // relative order of their blits is unobservable. If a future transition ever
      // overlaps them (a cross-fade, an over-scroll, a scaled scroll), this flush
      // becomes insufficient and the old map must instead be emitted BEFORE the new
      // map's tile channels rather than after them.
      d->flush_sprites_before_other_op();
      bool clipped = false;
      if (d->emit_draw(src, infos, 0, 0, &clipped)) {
        // Separate the two success outcomes so the HW banner can tell "old map
        // correctly scrolled off-screen" from "old map wrongly vanished".
        if (d->diag) { if (clipped) d->g_scroll_oldmap_clipped++;
                       else          d->g_scroll_oldmap_blits++; }
        return;
      }
      // Not expressible on the fabric (upload failure / escape): fall through to the
      // overlay so the old map is still PRESENT, just composited in software. Logged
      // by the existing escape counters.
    }
    // [Stage 1 / SOLARUS_OVERLAY] Overlay channel. Every root draw that is NOT
    // the camera promote-blit (skipped above) is screen-space content: HUD,
    // dialog, menu, title, Lua main_on_draw -- and, because g_transition_scroll
    // disables the camera alias, the scroll-transition map blits too. Render it
    // with stock base SDL into the root surface and mark it dirty; present()
    // uploads the root once as ARGB4444 and composites it LAST with per-pixel
    // alpha. SDLRenderer::clear() zeroes the root to a fully TRANSPARENT
    // (0,0,0,0) ARGB buffer every frame (SDLRenderer.cpp:147), so untouched
    // pixels have alpha 0 and the fabric's mixer skips their writes entirely.
    // Nothing is emitted on this path, so an op the emitter could not express
    // can no longer silently vanish -- it is simply drawn in software.
    if (d->overlay_enabled) {
      SDLRenderer::draw(dst, src, infos);
      d->mark_src_dirty(&dst);      // root pixels changed -> refresh its upload
      d->overlay_touched = true;
      if (d->diag) d->g_overlay_draws++;
      return;
    }
    // [Task 4] A root-surface blit writes the same framebuffer, so buffered camera
    // sprites must reach the ring first to stay UNDER this screen-space content.
    // (Only reachable with the overlay channel off; the overlay path above returns.)
    d->flush_sprites_before_other_op();
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
  if (dst.get_width() == FB_W && d->alias_target == &dst && !d->scroll_bandaid_active()) {
    d->alias_drawn_this_frame = true;   // the aliased surface is live this frame
    // [Task 4 / SOLARUS_SPRITECH] Buffer the draw instead of emitting its own
    // OP_BLIT; the run flushes as OP_SPRITELIST commands at the next layer
    // boundary (or before any other framebuffer write). With the gate OFF this
    // whole block is skipped and the path below is byte-for-byte the old one.
    if (d->spritech) {
      int rc = d->sprite_channel_push(src, infos, d->alias_off_x, d->alias_off_y);
      // g_spr_records is incremented INSIDE sprite_channel_push, on the accepted
      // push only -- a fully-clipped draw also returns 1 but buffers nothing.
      if (rc == 1) { return; }
      if (rc == 0) { d->g_spr_dropped++; return; }               // cap: drop the TAIL
      // rc == -1: not expressible as a list entry (PAL8 / colour-mod / escape).
      // Flush what is buffered FIRST so this draw still composites on top of the
      // sprites that preceded it, then fall through to the normal single blit.
      d->sprite_channel_flush(-1);
    }
    bool emitted = d->emit_draw(src, infos, d->alias_off_x, d->alias_off_y);
    if (emitted && d->diag) d->g_sprite_blits++;
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
  // [Stage 3b] min_layer is intentionally unused for now -- the bgplane bake that
  // used to consume it was deleted in Phase A, but the parameter is deliberately
  // kept on the signature for the Phase B tilemap channel, which needs it. Suppress
  // -Wunused-parameter until then.
  (void)min_layer;
  // Adopt the camera alias every frame (idempotent), mirroring the animated-tile batch, so the
  // animated-tile batch composites onto the same aliased camera surface.
  {
    // [Stage 3a] See the matching block in draw(): during a SCROLL with
    // SOLARUS_SCROLLFAB on, adopt at the engine-published offset, not (0,0), and
    // clear it when the scroll ends. Shared rule -> mister_scroll_alias_update().
    const bool cam_changed = d->camera_tag && g_tagged_camera &&
                             !d->scroll_bandaid_active() &&
                             d->alias_target != g_tagged_camera;
    if (cam_changed) d->alias_target = g_tagged_camera;
    mister_scroll_alias_update(d->alias_off_x, d->alias_off_y,
                               d->scrollfab, g_transition_scroll, cam_changed,
                               d->alias_target == g_tagged_camera,
                               g_scroll_new_dx, g_scroll_new_dy);
  }
  if (d->res_decided_epoch == d->res_epoch) return d->res_mode;   // memoized this frame
  d->res_decided_epoch = d->res_epoch;
  // 0 = disabled (SOLARUS_TILERESIDENT unset, fabric off, or mid transition-scroll) —
  // the engine's caller treats mode 0 as "nothing to do" (no legacy walk exists anymore).
  if (!d->res_enabled || d->blitter_off() || d->scroll_bandaid_active()) {
    d->res_building = false; d->res_mode = 0; return 0;
  }
  const bool sig = d->res_valid && d->res_map == map_id && d->res_tileset == tileset_id;
  if (sig) {
    d->res_building = false;
    d->res_mode = 2;                              // [Task 7] fast — no escape-to-legacy gate
    if (d->diag) d->res_noops++;
    return d->res_mode;
  }
  // New / changed signature: rebuild the resident list THIS frame.
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
  blt_surface_ref_t tex; uint8_t bl, fl, fmt, pal_id, pal_base; uint16_t key;
  if (!d->res_bucket_params(tileset_image, blend, tex, bl, key, fl, fmt, pal_id, pal_base)) {
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
  Impl::ResBucket bk{ &tileset_image, bl, fl, fmt, key, pal_id, pal_base, layer, scroll_ratio,
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
  if (d->diag) d->g_tile_blits += (long)entries.size();
}

// [static tile-list] Record one non-animated bucket for the direct BLT_OP_TILELIST path
// (12-byte entries, no FRT/pattern indirection). Parallel to resident_record_batch.
void MisterBlitterRenderer::resident_record_static(int layer, int scroll_ratio,
        const SurfaceImpl& tileset_image, BlendMode blend,
        const std::vector<TileBatchEntry>& entries) {
  d->mark_render();
  if (!d->res_building || entries.empty()) return;
  blt_surface_ref_t tex; uint8_t bl, fl, fmt, pal_id, pal_base; uint16_t key;
  if (!d->res_bucket_params(tileset_image, blend, tex, bl, key, fl, fmt, pal_id, pal_base)) {
    d->res_fatal = true;
    std::fprintf(stderr,
        "[blitter resident] FATAL: unbatchable STATIC bucket (blend/tex) layer=%d n=%zu\n",
        layer, entries.size());
    return;
  }
  d->ensure_frame();
  Impl::StaticBucket bk{ &tileset_image, bl, fl, fmt, key, pal_id, pal_base,
                         layer, scroll_ratio, 0u, 0, {} };
  bk.ent.reserve(entries.size());
  for (const auto& e : entries)
    bk.ent.push_back({ (uint16_t)e.src.get_x(), (uint16_t)e.src.get_y(),
                       (uint16_t)e.src.get_width(), (uint16_t)e.src.get_height(),
                       (int16_t)e.dst.x, (int16_t)e.dst.y });
  d->res_static_buckets.push_back(std::move(bk));
  d->res_static_ops.push_back({(uint32_t)(d->res_static_buckets.size() - 1), layer});
  d->alias_drawn_this_frame = true;
  if (d->diag) d->g_tile_blits += (long)entries.size();
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
  d->res_armed = true;
}

// Emit ONE recorded bucket via the fabric-resolved 8-byte TILELIST_RES (FRT/CFT fabric
// resolution). The stored entry dsts are MAP coords; this applies the bucket's per-frame
// camera bias so the fabric shifts them to screen coords (blitter_top: c_dst = res_dx +
// res_bias). Per-scene arm/FRT_UPLOAD happen lazily on the first bucket emitted (guarded +
// idempotent). ensure_frame/mark_render are idempotent. [Task 7] this is now the ONLY
// resident emit path — no Tier A / no res_hw gate.
void MisterBlitterRenderer::res_emit_bucket_(size_t idx) {
  d->flush_sprites_before_other_op();   // [Task 4] keep buffered sprites UNDER this op
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
  uint16_t pal_color;   // [PAL8] header colour field (pal_id/base_off) for paletted tilesets
  blt_surface_ref_t tex = d->res_bucket_emit_tex(b.tsimg, b.fmt, b.pal_id, b.pal_base, pal_color);
  if (!tex.valid) return;
  // [#52 camera-independent] per-bucket signed dst bias from the LIVE camera + scroll ratio.
  //   normal (ratio<=1): screen = map - camera            -> bias = -camera
  //   parallax (ratio>1): screen = map - camera + cam/r    -> bias = cam/r - camera
  // (upstream parallax draws at dst_position + viewport/ratio, dst_position = map - camera;
  //  storing map coords + this bias reproduces it exactly, camera-independently.)
  const int cx = mister_camera_x(), cy = mister_camera_y();
  // [Stage 3a] + the scroll bias (0 unless SOLARUS_SCROLLFAB is on and we are mid
  // scroll) so the new map's tiles animate in with its sprites. Computed in `int`
  // and cast ONCE at the end: the bias is up to a full screen dimension and is
  // negative for half the transition, so folding it in after an intermediate
  // int16_t cast could truncate a value that the widened sum represents fine.
  const int obx = d->scroll_bias_x(), oby = d->scroll_bias_y();
  int16_t bx, by;
  if (b.scroll_ratio <= 1) { bx = (int16_t)(-cx + obx); by = (int16_t)(-cy + oby); }
  else { bx = (int16_t)(cx / b.scroll_ratio - cx + obx);
         by = (int16_t)(cy / b.scroll_ratio - cy + oby); }
  blt_tile_list_res(&d->em, tex, b.blend, b.key, /*alpha=*/255, b.flags,
                    b.hw_off, b.hw_count, bx, by, pal_color);
  d->alias_drawn_this_frame = true;
  if (d->diag) d->g_tile_blits += b.hw_count;
}

// [static tile-list] Emit one recorded static bucket via direct BLT_OP_TILELIST (no FRT/CFT
// indirection — entries carry their own src). Parallel to res_emit_bucket_.
void MisterBlitterRenderer::res_emit_static_bucket_(size_t idx) {
  d->flush_sprites_before_other_op();   // [Task 4] keep buffered sprites UNDER this op
  if (idx >= d->res_static_buckets.size()) return;
  d->mark_render();
  d->ensure_frame();
  if (!d->res_armed) res_arm_();
  if (d->res_fatal) return;
  const Impl::StaticBucket& b = d->res_static_buckets[idx];
  if (b.hw_count == 0) return;
  uint16_t pal_color;   // [PAL8] header colour field (pal_id/base_off) for paletted tilesets
  blt_surface_ref_t tex = d->res_bucket_emit_tex(b.tsimg, b.fmt, b.pal_id, b.pal_base, pal_color);
  if (!tex.valid) return;
  const int cx = mister_camera_x(), cy = mister_camera_y();
  // [Stage 3a] see res_emit_bucket_ -- same additive scroll bias, same widen-then-
  // cast-once rule. 0 when SOLARUS_SCROLLFAB is off.
  const int obx = d->scroll_bias_x(), oby = d->scroll_bias_y();
  int16_t bx, by;
  if (b.scroll_ratio <= 1) { bx = (int16_t)(-cx + obx); by = (int16_t)(-cy + oby); }
  else { bx = (int16_t)(cx / b.scroll_ratio - cx + obx);
         by = (int16_t)(cy / b.scroll_ratio - cy + oby); }
  blt_tile_list_static(&d->em, tex, b.blend, b.key, /*alpha=*/255, b.flags,
                       b.hw_off, b.hw_count, bx, by, pal_color);
  d->alias_drawn_this_frame = true;
  if (d->diag) d->g_tile_blits += b.hw_count;
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

// [Stage 3b, Task 6] This layer's static tiles always replay per-bucket
// (res_emit_static_bucket_ per op). A per-layer baked-plane fast path used to
// live here as an alternative to this replay; it was HW-confirmed to cause
// three defects (#122, #123, #127) and has been deleted outright, along with
// all of its state (Task 5/6).
void MisterBlitterRenderer::resident_emit_static_layer(int layer) {
  d->flush_sprites_before_other_op();   // keep buffered sprites UNDER this op
  // [Stage 3b] Static tiles replay per-bucket. The camera/parallax bias and the
  // Stage-3a scroll bias both live in res_emit_static_bucket_. Phase B replaces
  // this body with the tilemap grid op at this same seam.
  for (size_t i = 0; i < d->res_static_ops.size(); ++i)
    if (d->res_static_ops[i].layer == layer)
      res_emit_static_bucket_(d->res_static_ops[i].bk);
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

  // [Stage 3a] Sample the DDR heap high-water mark unconditionally (not under
  // if (d->diag)) so the peak is correct even if diag is enabled partway through
  // a session -- it is a single compare-and-store. NOTE: this is the EARLY sample;
  // flush_sprites_before_other_op()/emit_overlay_composite()/the FPS overlay emit
  // further down this function can still raise em.heap_used, so a second sample
  // runs after those (see below) to catch that intra-frame peak too.
  d->sample_heap_peak();

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
      // [Task 1] g_alias_blits is retired as a stored counter but kept as this
      // computed sum so existing log-scraping of "alias_blits=" still works.
      const long g_alias_blits = d->g_sprite_blits + d->g_tile_blits;
      std::fprintf(stderr,
        "[blitter diag] /60fr: emit=%ld escape=%ld | fills=%ld blits=%ld "
        "alias_blits=%ld uploads=%ld reup=%ld offtarget=%ld | hwclear=%ld carryfwd=%ld | "
        "esc: rot=%ld scale=%ld "
        "tint=%ld alpha=%ld mode=%ld upload=%ld ovf=%ld toobig=%ld | "
        "pal_tint_restage=%ld cmdcnt=%d "
        "heap=%zu/%zu heap_peak=%zu overflow=%d target_locked=%d alias_locked=%d "
        "sprite_blits=%ld tile_blits=%ld dropped=%ld"
        " spr_rec=%ld spr_runs=%ld spr_drop=%ld scroll_oldmap=%ld scroll_oldclip=%ld"
        " scroll_off=(%d,%d)/(%d,%d)\n",
        d->g_frames_emit, d->g_frames_escape, d->g_fills, d->g_blits,
        g_alias_blits, d->g_uploads, d->g_reuploads, d->g_offtarget_draw,
        d->g_hwclear, d->g_carryfwd,
        d->g_esc_rot, d->g_esc_scale, d->g_esc_tint, d->g_esc_alpha,
        d->g_esc_mode, d->g_esc_upload, d->g_esc_overflow, d->g_esc_toobig,
        d->g_pal_tint_restage,
        d->em.cmd_count, d->em.heap_used, d->em.heap_cap, d->heap_peak, d->em.overflow,
        d->fpga_target ? 1 : 0, d->alias_target ? 1 : 0,
        d->g_sprite_blits, d->g_tile_blits, d->g_dropped_win,
        // [Task 4] spr_rec / spr_runs is the MEASURED sprite-list collapse ratio
        // (entries buffered per OP_SPRITELIST command emitted); spr_drop counts
        // entries refused at the channel cap. All three stay 0 with the gate off.
        d->g_spr_records, d->g_spr_runs, d->g_spr_dropped,
        // [Stage 3a] Old-map draws routed to the fabric; both 0 with SOLARUS_SCROLLFAB
        // off. scroll_oldclip counts the ones that were fully off-screen (nothing
        // emitted) -- expected to climb only at the very end of a transition.
        d->g_scroll_oldmap_blits, d->g_scroll_oldmap_clipped,
        // [Task 6] scroll_off = the engine-truth scroll offsets published by
        // mister_set_transition, as (new_dx,new_dy)/(old_dx,old_dy). These are
        // INSTANTANEOUS state, not windowed counters: they are deliberately NOT
        // reset in the /60fr reset block below -- do not "fix" that inconsistency.
        // Watching them animate across banners is direct evidence the engine hook
        // works; stuck at 0 localizes a failure to the engine seam, not the renderer.
        g_scroll_new_dx, g_scroll_new_dy, g_scroll_old_dx, g_scroll_old_dy);
      if (d->overlay_enabled)
        std::fprintf(stderr, "[blitter overlay] draws=%ld composites=%ld dropped=%ld\n",
                     d->g_overlay_draws, d->g_overlay_blits, d->g_overlay_esc);
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
      // [Task 5] INTER arena occupancy: the 4 MiB SDRAM_INTER_SIZE sizing rests on a
      // "~2 MiB working set (measured)" comment with no cited log line anywhere in the
      // repo, and blt_alloc_used was never called against the INTER region -- the only
      // existing INTER signal was failure-shaped (perm_overflow-style latches). Make it
      // observable so the 4 MiB figure can be re-derived from data. NOTE: despite the
      // region's name, there is no `sdram_inter` member -- blt_sdram_regions_init() (see
      // blt_emitter.c) inits INTER into the pre-existing `sdram_alloc` field (the SECOND,
      // recycled offset allocator; `sdram_perm` is the grow-only whole-quest one).
      {
        uint32_t inter_used = blt_alloc_used(&d->em.sdram_alloc);
        uint32_t inter_leaked = blt_alloc_leaked(&d->em.sdram_alloc);
        std::fprintf(stderr,
          "[blitter inter] /60fr: used=%u/%u bytes (%.2f/%.2f MiB) leaked=%u\n",
          inter_used, (unsigned)SDRAM_INTER_SIZE,
          inter_used / 1048576.0, SDRAM_INTER_SIZE / 1048576.0,
          inter_leaked);
      }
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
      d->g_fills = d->g_blits = 0;
      d->g_sprite_blits = d->g_tile_blits = 0;
      d->g_scroll_oldmap_blits = 0;   // [Stage 3a] the banner is a 60-frame WINDOW
      d->g_scroll_oldmap_clipped = 0;
      d->g_spr_records = d->g_spr_runs = d->g_spr_dropped = 0;   // [Task 4]
      d->spr_ch.dropped = 0;   // channel's own accumulator rides the same window
      d->g_dropped_win = 0;
      d->g_escapes = d->g_offtarget_draw = 0;
      d->g_uploads = d->g_reuploads = 0;
      d->g_upload_px = d->g_reup_px = d->g_upload_big = d->g_reup_big = 0;
      d->g_cvt_fallback = 0;   // [#52]
      d->g_hwclear = d->g_carryfwd = 0;
      d->g_fastpace_skips = 0;   // [lever-b]
      d->g_overlay_draws = d->g_overlay_blits = d->g_overlay_esc = 0;   // [Stage 1]
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
    // [Task 4] Nothing may stay buffered past the frame: flush any sprites the last
    // layer left pending BEFORE the overlay/FPS composites, so those still land on
    // top. (emit_overlay_composite guards itself too, but it early-outs when the
    // overlay is off or untouched -- this call is the unconditional one.)
    d->flush_sprites_before_other_op();
    d->emit_overlay_composite();                                  // [Stage 1] UI last
    if (d->fps_overlay_enabled()) d->emit_fps_overlay_fills();    // FPS on top of that
    // [Stage 3a review fix] LATE sample: flush_sprites_before_other_op()/
    // emit_overlay_composite()/the FPS overlay emit above are the last things in
    // present() that can allocate from the DDR heap (blt_end_frame() below only
    // appends an END command and bumps submit_seq -- no heap traffic). Sampling
    // again here, unconditionally, catches an intra-frame peak the early sample
    // (above, before this if (d->frame_active) block) would otherwise miss.
    d->sample_heap_peak();
    blt_end_frame(&d->em);
    // [Task 1 review fix] Fold this frame's drop count into the 60-frame window
    // accumulator here: every command this frame (including the overlay/FPS
    // overlay emits just above) has now been emitted, and the next blt_begin_frame()
    // (lazily, on the next frame's first draw op) is what resets d->em.dropped -- so
    // this is the last point at which d->em.dropped reflects exactly this frame.
    if (d->diag) d->g_dropped_win += d->em.dropped;
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
  d->overlay_touched = false;   // [Stage 1] re-armed by next frame's root draws

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
