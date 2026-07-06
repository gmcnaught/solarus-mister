/* Host unit test for Quadtree fat-AABB hysteresis (SOLARUS_QTREE_MARGIN).
 *
 * Compiles the REAL Quadtree<T> template (no engine runtime). See
 * tests/run_tests.sh for the exact build command; the Debug free-functions are
 * stubbed here so no SDL/Logger is linked.
 */
#include "solarus/containers/Quadtree.h"
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <algorithm>

// --- Debug stubs (avoid linking SDL/Logger) --------------------------------
namespace Solarus { namespace Debug {
  void check_assertion(bool a, const char* m)        { if (!a) { std::fprintf(stderr, "assert: %s\n", m); std::abort(); } }
  void check_assertion(bool a, const std::string& m) { if (!a) { std::fprintf(stderr, "assert: %s\n", m.c_str()); std::abort(); } }
  void error(const std::string& m)   { std::fprintf(stderr, "error: %s\n", m.c_str()); }
  void warning(const std::string& m) { std::fprintf(stderr, "warn: %s\n", m.c_str()); }
  void die(const std::string& m)     { std::fprintf(stderr, "die: %s\n", m.c_str()); std::abort(); }
}}

using namespace Solarus;
using ElementPtr = std::shared_ptr<int>;

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { std::printf("FAIL: %s (line %d)\n", msg, __LINE__); failures++; } \
} while (0)

// NOTE: construct each Quadtree in-place as a local. Do NOT return one by value
// or store it in a container: Quadtree::Node holds a `const Quadtree&` back-
// reference, so a moved/copied tree's root would dangle. A 256x256 space is
// used throughout.

static bool found(Quadtree<ElementPtr>& q, const Rectangle& region, const ElementPtr& e) {
  auto v = q.get_elements(region);
  return std::find(v.begin(), v.end(), e) != v.end();
}

// Baseline: margin 0 => reinsert on any change; element found at new position.
static void test_baseline_margin0() {
  Quadtree<ElementPtr> q(Rectangle(0, 0, 256, 256));
  CHECK(q.get_fat_margin() == 0, "default margin is 0");
  auto e = std::make_shared<int>(1);
  q.add(e, Rectangle(100, 100, 16, 16));
  long long before = q.get_move_reinsert_count();
  q.move(e, Rectangle(102, 100, 16, 16));
  CHECK(q.get_move_reinsert_count() == before + 1, "margin0: any move reinserts");
  CHECK(found(q, Rectangle(96, 96, 32, 32), e), "margin0: found at new pos");
  // No-op move (same box) does not reinsert.
  before = q.get_move_reinsert_count();
  q.move(e, Rectangle(102, 100, 16, 16));
  CHECK(q.get_move_reinsert_count() == before, "margin0: no-op move skips");
}

// With margin 8, a sub-margin move must NOT reinsert, yet stay findable.
static void test_skip_within_margin() {
  Quadtree<ElementPtr> q(Rectangle(0, 0, 256, 256));
  q.set_fat_margin(8);
  auto e = std::make_shared<int>(1);
  q.add(e, Rectangle(100, 100, 16, 16));
  // First move always reinserts (initial stored box is exact, not fat).
  q.move(e, Rectangle(101, 100, 16, 16));
  long long after_first = q.get_move_reinsert_count();
  // Subsequent small moves stay inside the fat box: no reinsert.
  q.move(e, Rectangle(102, 100, 16, 16));
  q.move(e, Rectangle(103, 100, 16, 16));
  CHECK(q.get_move_reinsert_count() == after_first, "margin8: sub-margin moves skip reinsert");
  CHECK(found(q, Rectangle(99, 99, 24, 24), e), "margin8: still found after skipped moves");
}

// A move beyond the fat box reinserts and drops the stale far-away membership.
static void test_reinsert_beyond_margin() {
  Quadtree<ElementPtr> q(Rectangle(0, 0, 256, 256));
  q.set_fat_margin(8);
  auto e = std::make_shared<int>(1);
  q.add(e, Rectangle(40, 40, 16, 16));
  q.move(e, Rectangle(41, 40, 16, 16));            // establishes the fat box
  long long before = q.get_move_reinsert_count();
  q.move(e, Rectangle(200, 200, 16, 16));          // far jump, beyond margin
  CHECK(q.get_move_reinsert_count() == before + 1, "beyond-margin move reinserts");
  CHECK(found(q, Rectangle(196, 196, 24, 24), e), "found at new far pos");
  CHECK(!found(q, Rectangle(0, 0, 80, 80), e), "not found at old pos after far move");
}

// Fuzz: after every move (mostly +/-1px steps, occasional jumps), a query that
// overlaps the true box must return the element. Deterministic seed.
static void test_no_miss_invariant() {
  Quadtree<ElementPtr> q(Rectangle(0, 0, 256, 256));
  q.set_fat_margin(8);
  auto e = std::make_shared<int>(1);
  int x = 128, y = 128;
  const int w = 16, h = 16;
  q.add(e, Rectangle(x, y, w, h));
  std::srand(12345);
  for (int step = 0; step < 5000; ++step) {
    if (step % 250 == 249) {
      // Occasional large jump (still inside the 256x256 space).
      x = 8 + std::rand() % (240 - w);
      y = 8 + std::rand() % (240 - h);
    } else {
      x += (std::rand() % 3) - 1;   // -1, 0, +1
      y += (std::rand() % 3) - 1;
      if (x < 8) x = 8; if (x > 240 - w) x = 240 - w;
      if (y < 8) y = 8; if (y > 240 - h) y = 240 - h;
    }
    Rectangle true_box(x, y, w, h);
    q.move(e, true_box);
    // Query exactly the true box: broad phase must never miss it.
    if (!found(q, true_box, e)) {
      std::printf("MISS at step %d box=(%d,%d,%d,%d)\n", step, x, y, w, h);
      CHECK(false, "no-miss invariant violated");
      return;
    }
  }
  // Sanity: hysteresis actually skipped a large fraction of moves.
  CHECK(q.get_move_reinsert_count() < 5000, "hysteresis skipped some reinserts");
}

// The env var seeds the default margin at construction; unset => 0 (exact).
static void test_env_default() {
  unsetenv("SOLARUS_QTREE_MARGIN");
  { Quadtree<ElementPtr> q(Rectangle(0, 0, 256, 256)); CHECK(q.get_fat_margin() == 0, "unset env => margin 0"); }

  setenv("SOLARUS_QTREE_MARGIN", "8", 1);
  { Quadtree<ElementPtr> q(Rectangle(0, 0, 256, 256)); CHECK(q.get_fat_margin() == 8, "env=8 => margin 8"); }

  // margin 0 parity: reinsert on every change (identical to baseline).
  setenv("SOLARUS_QTREE_MARGIN", "0", 1);
  { Quadtree<ElementPtr> q(Rectangle(0, 0, 256, 256));
    auto e = std::make_shared<int>(1);
    q.add(e, Rectangle(50, 50, 16, 16));
    long long before = q.get_move_reinsert_count();
    q.move(e, Rectangle(51, 50, 16, 16));
    CHECK(q.get_move_reinsert_count() == before + 1, "env=0 => reinsert on any change");
  }
  unsetenv("SOLARUS_QTREE_MARGIN");
}

// Boundary: walk positions that straddle the quadtree-space edge (negative and
// past-edge coords) but still OVERLAP the space. Fat inflation flips
// overlaps(space) false->true near the edge (adds false positives only), so the
// element must still be found at every overlapping step — never missed.
static void test_boundary_overlap() {
  Quadtree<ElementPtr> q(Rectangle(0, 0, 256, 256));
  q.set_fat_margin(8);
  auto e = std::make_shared<int>(1);
  const int w = 16, h = 16;
  q.add(e, Rectangle(4, 4, w, h));
  const int coords[][2] = {
    {2, 2}, {0, 0}, {-4, -4}, {-4, 120}, {2, 2},
    {244, 244}, {250, 250}, {250, 4}, {120, 120}
  };
  for (const auto& c : coords) {
    Rectangle box(c[0], c[1], w, h);   // each overlaps the 0..255 space
    q.move(e, box);
    CHECK(found(q, box, e), "boundary: found at each overlapping step");
  }
}

// Out-of-space and back: an element moved fully outside the space is tracked in
// elements_outside (get_elements does not return it there — by design); when it
// returns into the space it must be findable again.
static void test_out_of_space_and_back() {
  Quadtree<ElementPtr> q(Rectangle(0, 0, 256, 256));
  q.set_fat_margin(8);
  auto e = std::make_shared<int>(1);
  q.add(e, Rectangle(10, 10, 16, 16));
  q.move(e, Rectangle(-500, -500, 16, 16));   // fully outside
  q.move(e, Rectangle(40, 40, 16, 16));       // back inside
  CHECK(found(q, Rectangle(40, 40, 16, 16), e), "found again after out-and-back");
}

// Size changes: move() receives max_bounding_box, whose dimensions can change.
// A box growing past the fat box must reinsert and stay findable; a shrink too.
static void test_size_change() {
  Quadtree<ElementPtr> q(Rectangle(0, 0, 256, 256));
  q.set_fat_margin(8);
  auto e = std::make_shared<int>(1);
  q.add(e, Rectangle(100, 100, 16, 16));
  q.move(e, Rectangle(100, 100, 16, 16));         // establish fat box
  Rectangle big(100, 100, 64, 64);                // grow well beyond margin
  q.move(e, big);
  CHECK(found(q, big, e), "size-change: found after growth");
  CHECK(found(q, Rectangle(150, 150, 8, 8), e), "size-change: found at new far corner");
  Rectangle small(100, 100, 8, 8);                // shrink
  q.move(e, small);
  CHECK(found(q, small, e), "size-change: found after shrink");
}

int main() {
  test_baseline_margin0();
  test_skip_within_margin();
  test_reinsert_beyond_margin();
  test_no_miss_invariant();
  test_env_default();
  test_boundary_overlap();
  test_out_of_space_and_back();
  test_size_change();
  if (failures == 0) std::printf("quadtree_fat: all tests passed\n");
  return failures == 0 ? 0 : 1;
}
