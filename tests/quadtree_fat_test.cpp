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

int main() {
  test_baseline_margin0();
  test_skip_within_margin();
  if (failures == 0) std::printf("quadtree_fat: all tests passed\n");
  return failures == 0 ? 0 : 1;
}
