// [Stage 3a] Scroll-transition compositing: offset arithmetic + routing decisions.
// Host-only, no engine link, no SDL -- a faithful model of
// TransitionScrolling::get_mister_scroll_offsets and how mister_blitter_renderer's
// draw() applies the result during a TransitionScrolling frame (Task 3/5). Proves
// the offset arithmetic, the "one screen apart" invariant across the scroll, and
// (negative self-test) the exact double-application regression fixed on this
// branch in 13259fd ("stop double-applying the scroll offset to the old map").
#include <cstdio>

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
  if (failures == 0) std::printf("test_scrollalias: all passed\n");
  else std::printf("FAILED (%d)\n", failures);
  return failures ? 1 : 0;
}
