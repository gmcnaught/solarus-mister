// [Stage 3a] Scroll-transition compositing: offset arithmetic + routing decisions.
// Host-only, no engine link, no SDL -- a faithful model of
// TransitionScrolling::get_mister_scroll_offsets and how mister_blitter_renderer's
// draw() applies the result during a TransitionScrolling frame (Task 3/5). Proves
// the offset arithmetic, the "one screen apart" invariant across the scroll, and
// (negative self-test) the exact double-application regression fixed on this
// branch in 13259fd ("stop double-applying the scroll offset to the old map").
#include <cstdio>
#include "scroll_alias.h"   // the REAL rule the renderer uses (case 7 gates it)

static int failures = 0;
#define CHECK(c,m) do{ if(!(c)){ std::printf("FAIL: %s (line %d)\n", m, __LINE__); failures++; } }while(0)

// Mirrors TransitionScrolling::get_mister_scroll_offsets: the two offsets are
// (map_dst_position - current_scrolling_position), exactly as draw() computes them.
struct ScrollOffsets { int new_dx, new_dy, old_dx, old_dy; };
static ScrollOffsets scroll_offsets(int cur_dst_x, int cur_dst_y,
                                     int prev_dst_x, int prev_dst_y,
                                     int scroll_x, int scroll_y) {
  return ScrollOffsets{ cur_dst_x - scroll_x, cur_dst_y - scroll_y,
                         prev_dst_x - scroll_x, prev_dst_y - scroll_y };
}

// Mirrors Impl::emit_draw's blit-position arithmetic: off_x/off_y are an ADDITIVE
// translation on top of the draw's own destination position (bdx = dr.get_x() +
// off_x in the real code), never a position override.
static int emit_draw_dst_x(int dst_position_x, int off_x) { return dst_position_x + off_x; }

// Screen is 320x240. A RIGHT scroll puts the previous map at (0,0) and the current
// map at (320,0) on the both-maps surface, scrolling x from 0 -> 320.
int main() {
  // 1. At scroll start the OLD map fills the screen and the NEW map is fully right.
  {
    ScrollOffsets o = scroll_offsets(320, 0, 0, 0, 0, 0);
    CHECK(o.old_dx == 0   && o.old_dy == 0, "start: old map at origin");
    CHECK(o.new_dx == 320 && o.new_dy == 0, "start: new map fully off-screen right");
  }
  // 2. Mid-scroll the two maps are adjacent and always exactly 320 apart.
  {
    ScrollOffsets o = scroll_offsets(320, 0, 0, 0, 160, 0);
    CHECK(o.old_dx == -160, "mid: old map scrolled half off left");
    CHECK(o.new_dx ==  160, "mid: new map scrolled half on from right");
    CHECK(o.new_dx - o.old_dx == 320, "mid: maps stay exactly one screen apart");
  }
  // 3. At scroll end the NEW map is at the origin -- the steady-state alias offset.
  {
    ScrollOffsets o = scroll_offsets(320, 0, 0, 0, 320, 0);
    CHECK(o.new_dx == 0 && o.new_dy == 0, "end: new map at origin (steady state)");
    CHECK(o.old_dx == -320, "end: old map fully off-screen left");
  }
  // 4. A DOWN scroll moves y, not x.
  {
    ScrollOffsets o = scroll_offsets(0, 240, 0, 0, 0, 120);
    CHECK(o.new_dx == 0 && o.old_dx == 0, "down: x untouched");
    CHECK(o.new_dy == 120 && o.old_dy == -120, "down: y split about the seam");
    CHECK(o.new_dy - o.old_dy == 240, "down: maps stay one screen apart");
  }
  // 4b. The "one screen apart" invariant must hold at EVERY point across the scroll,
  //     not just the three snapshots above -- this is the shape of check that would
  //     have caught the Task 5 doubling bug (case 6 pins the bug itself directly;
  //     this pins the observable symptom across the whole sweep).
  {
    for (int s = 0; s <= 320; s += 17) {
      ScrollOffsets o = scroll_offsets(320, 0, 0, 0, s, 0);
      CHECK(o.new_dx - o.old_dx == 320, "sweep: maps stay one screen apart at every step");
    }
  }
  // 5. Regression guard for the bandaid's justification (1): with the alias offset
  //    pinned to 0 (the pre-Stage-3a behavior) the new map never moves, which is
  //    exactly "only the old map scrolls away".
  {
    ScrollOffsets o = scroll_offsets(320, 0, 0, 0, 160, 0);
    const int aliased_at_zero = 0;
    CHECK(aliased_at_zero != o.new_dx,
          "bandaid repro: alias at 0 does not track the scrolling new map");
  }
  // 6. NEGATIVE SELF-TEST: reproduces the exact bug fixed in 13259fd. The old-map
  //    draw's infos.dst_position (dr.get_x()) ALREADY equals old_dx/old_dy -- it is
  //    published at previous_map_dst_position - current_scrolling_position, the same
  //    expression scroll_offsets() computes above. emit_draw's off_x/off_y are
  //    ADDITIVE (see emit_draw_dst_x), so the correct call passes off_x=0 and lets
  //    dst_position alone carry the offset. The bug passed old_dx/old_dy AGAIN as
  //    off_x, doubling it -- the old map slid at 2x and, once the doubled offset
  //    exceeded the framebuffer width, clipped fully off-screen and vanished for the
  //    back half of every transition. If this check passes with the bug's call
  //    shape, the test is not actually gating the regression.
  {
    ScrollOffsets o = scroll_offsets(320, 0, 0, 0, 160, 0);
    int dst_position_x = o.old_dx;                       // infos.dst_position, already offset
    int correct_x = emit_draw_dst_x(dst_position_x, 0);          // fixed call: off_x=0
    int buggy_x   = emit_draw_dst_x(dst_position_x, o.old_dx);   // 13259fd bug: off_x=old_dx again
    CHECK(correct_x == o.old_dx, "13259fd: fixed call reproduces the single offset");
    CHECK(buggy_x == 2 * o.old_dx, "13259fd: buggy call doubles the offset");
    CHECK(buggy_x != correct_x, "13259fd: doubled call diverges from the correct position");
    // Concretely: at this scroll position the doubled offset already reaches a full
    // screen width in magnitude ("once |off| >= the fb width" per 13259fd's commit
    // message), which is the "vanishes entirely" symptom.
    CHECK(buggy_x <= -320, "13259fd: doubled offset reaches/overshoots a full screen width off-screen");
  }
  // 7. STALE ALIAS OFFSET after a scroll ends (the HW defect found by the Stage 3a
  //    A/B: entities offset from the background by the LAST transition's direction,
  //    constant magnitude, persisting indefinitely).
  //
  //    The renderer maintains alias_off_x/y at two mirrored sites -- draw()
  //    (:2775-2794) and resident_begin_frame() (:2997-3012). Both have the same
  //    shape: the reset-to-zero lives INSIDE the `alias_target != g_tagged_camera`
  //    adoption branch (fires only when the camera surface changes), while the
  //    per-frame refresh is gated on g_transition_scroll. When a scroll ends with
  //    the camera unchanged, NEITHER runs -- so the offset keeps its last in-scroll
  //    value forever.
  //
  //    It shows up as entities-vs-background misalignment specifically because the
  //    two consumers read it differently:
  //      background/tiles: scroll_bias_x() (:789) = (scrollfab && g_transition_scroll)
  //                        ? alias_off_x : 0   -- SELF-CLEARING when the scroll ends
  //      sprites/entities: d->alias_off_x read RAW (:2948 sprite_channel_push,
  //                        :2958 emit_draw)     -- keeps the stale value
  {
    struct AliasState { int off_x, off_y; };
    // Background consumer, exactly as the renderer reads it (scroll_bias_x, :789).
    // The sprite consumer is the raw field itself (a.off_x / a.off_y).
    auto bg_bias_x = [](const AliasState& a, bool sf, bool ts) {
      return (sf && ts) ? a.off_x : 0;
    };
    // The PRE-FIX shape, kept only as a negative self-test: reset lived solely in
    // the camera-change branch, refresh only while scrolling, no clear on end.
    auto alias_update_buggy = [](AliasState& a, bool sf, bool ts, bool cam_changed,
                                 int ndx, int ndy) {
      if (cam_changed) { if (sf && ts) { a.off_x = ndx; a.off_y = ndy; }
                         else          { a.off_x = 0;   a.off_y = 0;   } }
      if (sf && ts)    { a.off_x = ndx; a.off_y = ndy; }
    };
    // The FIXED path is NOT re-modelled here -- it calls the same inline function
    // the renderer calls, so this case genuinely gates the shipped logic.
    auto alias_update_fixed = [](AliasState& a, bool sf, bool ts, bool cam_changed,
                                 int ndx, int ndy) {
      mister_scroll_alias_update(a.off_x, a.off_y, sf, ts, cam_changed,
                                 /*alias_is_tagged_cam=*/true, ndx, ndy);
    };
    // A NORTH scroll: new map enters from above, new_dy sweeps -240 -> 0. The last
    // frame the renderer still sees g_transition_scroll==true carries a NONZERO
    // offset; the frame after, the flag drops with the camera unchanged.
    const int last_in_scroll_dy = -17;   // any nonzero mid-sweep value
    for (int variant = 0; variant < 2; ++variant) {
      const bool fixed = (variant == 1);
      AliasState a{0, 0};
      // adopt at the start of the scroll (camera changed at the map swap)
      if (fixed) alias_update_fixed(a, true, true, true, 0, -240);
      else       alias_update_buggy(a, true, true, true, 0, -240);
      // ... scroll animates ...
      if (fixed) alias_update_fixed(a, true, true, false, 0, last_in_scroll_dy);
      else       alias_update_buggy(a, true, true, false, 0, last_in_scroll_dy);
      CHECK(a.off_y == last_in_scroll_dy, "scroll: offset tracks engine truth mid-scroll");
      // transition ENDS: g_transition_scroll false, SAME camera surface.
      if (fixed) alias_update_fixed(a, true, false, false, 0, 0);
      else       alias_update_buggy(a, true, false, false, 0, 0);
      if (fixed) {
        CHECK(a.off_y == 0,
              "FIXED: alias offset returns to 0 when the scroll ends");
        CHECK(a.off_y == bg_bias_x(a, true, false),
              "FIXED: entities and background agree after the scroll (no misalignment)");
      } else {
        // Negative self-test: this IS the observed hardware defect. If these ever
        // stop holding, the buggy model no longer reproduces it and case 7 is not
        // gating the regression.
        CHECK(a.off_y == last_in_scroll_dy,
              "BUG repro: alias offset latches the last in-scroll value");
        CHECK(a.off_y != bg_bias_x(a, true, false),
              "BUG repro: entities diverge from the background (the visible symptom)");
      }
    }
    // Direction sign: the latch carries the direction of the LAST transition, which
    // is why north and south misalign opposite ways by the same magnitude.
    {
      AliasState north{0, 0}, south{0, 0};
      alias_update_buggy(north, true, true, false, 0, -17);
      alias_update_buggy(south, true, true, false, 0, +17);
      alias_update_buggy(north, true, false, false, 0, 0);
      alias_update_buggy(south, true, false, false, 0, 0);
      CHECK(north.off_y == -south.off_y,
            "BUG repro: north and south latch equal-magnitude opposite-signed offsets");
    }
    // The flag-OFF path must be untouched: scrollfab false never writes an offset.
    {
      AliasState a{0, 0};
      alias_update_fixed(a, false, true, false, 0, -17);
      CHECK(a.off_x == 0 && a.off_y == 0,
            "SOLARUS_SCROLLFAB=0: no offset is ever applied (shipping default safe)");
    }
  }
  if (failures == 0) std::printf("test_scrollalias: all passed\n");
  else std::printf("FAILED (%d)\n", failures);
  return failures ? 1 : 0;
}
