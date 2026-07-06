# Fat-AABB Quadtree Hysteresis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut per-move quadtree churn (the `g_me_ent_qtree_ns` bucket of enemy move-bookkeeping) by storing an inflated ("fat") box in the quadtree and skipping the `remove`+`add` reinsert while an entity's true box stays inside that fat box.

**Architecture:** Broad-phase fat-AABB (the Box2D trick). `Quadtree::move` skips the tree reinsert when `stored_fat.contains(new_true_box)`; otherwise it reinserts with `new_true_box` inflated by `fat_margin` on all sides. Correct by the broad/narrow-phase split: the stored box always ⊇ the true box, so `get_elements` never misses; extra false positives are re-tested by every consumer's `overlaps()`. Env-gated (`SOLARUS_QTREE_MARGIN`), default 0 = byte-identical to today.

**Tech Stack:** C++17, Solarus `Quadtree<T>` template (`include/solarus/containers/Quadtree.{h,inl}`), `Rectangle` geometry. Host-side standalone C++ test compiled with `g++` against the real template (no engine/SDL runtime, no Docker), wired into `tests/run_tests.sh`.

## Global Constraints

- **Persistence of engine-source edits (CORRECTION, 2026-07-05).** `work/solarus/`
  is **gitignored** and is a fresh `git clone` of pristine upstream in CI, so
  edits to upstream files (`Quadtree.{h,inl}`) are **not** tracked and would be
  lost on a clean build. This repo injects upstream edits through
  `scripts/build_engine.sh` after the clone. Crucially, `build_engine.sh`
  already has a Quadtree block that **reverts** `Quadtree.{h,inl}` to pristine
  (`git checkout --`) and then re-applies the "#26 vector+sort" edit via python
  string-replace — so a separate patch file would be wiped by that revert and,
  if diffed against pristine, would bundle the #26 change and conflict.
  Therefore the fat-AABB edit lives in a shared, idempotent applier
  **`scripts/patch_quadtree_fat.py`** (tracked): it string-replaces the
  includes / `move()` / member additions (disjoint from `get_elements`, so it
  never conflicts with #26). `build_engine.sh` calls it right **after** the #26
  block; `tests/run_tests.sh` calls it before the host `quadtree_fat` compile so
  the test sees the patched header. The tracked, reviewable artifacts are
  `scripts/patch_quadtree_fat.py` + the tests; **nothing under `work/` is
  committed** and `.gitignore` is **not** modified.
- Engine is **Solarus 1.6.5**, cross-built armhf; source lives under `work/solarus/`.
- **No behavior change when disabled.** `SOLARUS_QTREE_MARGIN` unset or `0` MUST keep the exact original `move()` path (equality short-circuit, reinsert on any change).
- Feature-flag pattern matches the project: default off → HW A/B via `SOLARUS_QTREE_MARGIN=8` → bake default on later. **UPDATE 2026-07-05: HW A/B done** (qtree_reinsert 0.8→0.24 ms/60fr, −70%, rendering correct) → default **baked to 8** (`read_fat_margin_env` returns 8 when unset; `SOLARUS_QTREE_MARGIN=0` opts out). Matches the project's other HW-validated flags (default-ON, `=0` opt-out).
- Correctness invariant (load-bearing): **the box stored in the quadtree always contains the entity's true box.** Every task must preserve it.
- Scope is `Quadtree.{h,inl}` + the standalone test + `run_tests.sh` only. **No** entity/movement/`Map`/call-site changes.
- Commit messages end with the repo's trailer:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_015tcQg6rpvBn1daNKnS5GXr
  ```
- Branch: `perf/quadtree-fat-aabb` (already checked out).

## Test harness recipe (validated — used by every test task)

The standalone test compiles the **real** `Quadtree` template with a stub `config.h` and vendored glm/SDL headers, linking only the geometry `.cpp` files and stubbing the `Debug` free-functions. Validated command (run from repo root):

```bash
g++ -std=c++17 \
  -I work/solarus/include \
  -I tests/qtree_test_include \
  -I work/solarus/libraries/win32/mingw32/include \
  -I work/SDL2-2.28.5/include \
  tests/quadtree_fat_test.cpp \
  work/solarus/src/core/Rectangle.cpp \
  work/solarus/src/core/Point.cpp \
  work/solarus/src/core/Size.cpp \
  -o /tmp/quadtree_fat_test && /tmp/quadtree_fat_test
```

- `tests/qtree_test_include/solarus/core/config.h` is a tiny stub (Task 1) supplying only the version macros `Common.h` needs.
- The `Debug::check_assertion/error/warning/die` free-functions are **defined in the test TU** so no SDL/Logger is linked.
- `work/SDL2-2.28.5/include` and `work/solarus/libraries/win32/mingw32/include` (glm) are vendored in the tree; both are needed only to *parse* `Quadtree.h`'s transitive includes (`SurfacePtr.h`→SDL, `Size.h`→glm), never at runtime.

---

### Task 1: Standalone test harness + reinsert counter + margin plumbing

Brings up the host test against the real template, and adds the observable the optimization is tested through: a `move()` reinsert counter, plus the `fat_margin` member/setter and env read. `move()` LOGIC is unchanged in this task (still original behavior) except for incrementing the counter on reinsert. The baseline test asserts today's behavior.

**Files:**
- Create: `tests/qtree_test_include/solarus/core/config.h`
- Create: `tests/quadtree_fat_test.cpp`
- Modify: `work/solarus/include/solarus/containers/Quadtree.h` (add members/getters/setter; add `<cstdlib>`)
- Modify: `work/solarus/include/solarus/containers/Quadtree.inl` (increment counter on reinsert; ctor env read)
- Modify: `tests/run_tests.sh` (add C++ test block)

**Interfaces:**
- Produces (on `Quadtree<T, Comparator>`):
  - `void set_fat_margin(int margin);` — override the margin (tests; also engine if ever needed).
  - `int get_fat_margin() const;`
  - `long long get_move_reinsert_count() const;` — number of `move()` calls that performed an actual `remove`+`add`.
  - private `int fat_margin` (default from `SOLARUS_QTREE_MARGIN`, else 0), `long long move_reinsert_count = 0`.
  - private static `static int read_fat_margin_env();` — reads `SOLARUS_QTREE_MARGIN` via `std::getenv`/`std::atoi` each call (no caching, so tests using `setenv` see fresh values).

- [ ] **Step 1: Create the stub `config.h`**

Create `tests/qtree_test_include/solarus/core/config.h`:

```c
/* Minimal stub of the CMake-generated config.h, for host-side container tests.
 * Supplies only the version macros solarus/core/Common.h expands. */
#define SOLARUS_MAJOR_VERSION 1
#define SOLARUS_MINOR_VERSION 6
#define SOLARUS_PATCH_VERSION 5
#define SOLARUS_GIT_REVISION "test"
```

- [ ] **Step 2: Add members, setter, getters, and env reader to `Quadtree.h`**

In `work/solarus/include/solarus/containers/Quadtree.h`:

Add `#include <cstdlib>` near the other includes (after `#include <memory>`).

In the `public:` section, after `bool move(...)` (line ~60), add:

```cpp
    void set_fat_margin(int margin);
    int get_fat_margin() const;
    long long get_move_reinsert_count() const;
```

In the `private:` section, alongside the data members (after `Node root;`, line ~150), add:

```cpp
    static int read_fat_margin_env();

    int fat_margin = read_fat_margin_env();   /**< Broad-phase inflation in px.
                                               * 0 disables (exact behavior). */
    long long move_reinsert_count = 0;         /**< move() calls that did an
                                               * actual remove+add. */
```

- [ ] **Step 3: Implement the accessors and env reader in `Quadtree.inl`**

At the top of `work/solarus/include/solarus/containers/Quadtree.inl` (after the existing includes / before the first method), add:

```cpp
template<typename T, typename Comparator>
int Quadtree<T, Comparator>::read_fat_margin_env() {
  const char* e = std::getenv("SOLARUS_QTREE_MARGIN");
  return e != nullptr ? std::atoi(e) : 0;
}

template<typename T, typename Comparator>
void Quadtree<T, Comparator>::set_fat_margin(int margin) {
  fat_margin = margin;
}

template<typename T, typename Comparator>
int Quadtree<T, Comparator>::get_fat_margin() const {
  return fat_margin;
}

template<typename T, typename Comparator>
long long Quadtree<T, Comparator>::get_move_reinsert_count() const {
  return move_reinsert_count;
}
```

- [ ] **Step 4: Count reinserts in `move()` (logic otherwise unchanged)**

In `work/solarus/include/solarus/containers/Quadtree.inl`, in `move()`, add the counter increment on the successful `add` path. Change:

```cpp
  if (!add(element, bounding_box)) {
    // Failed to add.
    return false;
  }
  return true;
```

to:

```cpp
  if (!add(element, bounding_box)) {
    // Failed to add.
    return false;
  }
  ++move_reinsert_count;
  return true;
```

- [ ] **Step 5: Write the baseline test**

Create `tests/quadtree_fat_test.cpp`:

```cpp
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

int main() {
  test_baseline_margin0();
  if (failures == 0) std::printf("quadtree_fat: all tests passed\n");
  return failures == 0 ? 0 : 1;
}
```

- [ ] **Step 6: Wire the test into `run_tests.sh`**

In `tests/run_tests.sh`, before the final `echo "All host tests passed."` (line 74), add:

```bash
echo "== quadtree_fat (perf: fat-AABB hysteresis in Quadtree::move) =="
CXX="${CXX:-g++}"
$CXX -std=c++17 -Wall \
    -I work/solarus/include \
    -I tests/qtree_test_include \
    -I work/solarus/libraries/win32/mingw32/include \
    -I work/SDL2-2.28.5/include \
    tests/quadtree_fat_test.cpp \
    work/solarus/src/core/Rectangle.cpp \
    work/solarus/src/core/Point.cpp \
    work/solarus/src/core/Size.cpp \
    -o /tmp/quadtree_fat_test
/tmp/quadtree_fat_test
```

- [ ] **Step 7: Run the test — expect PASS (harness bring-up)**

Run: `bash tests/run_tests.sh 2>&1 | tail -20`
Expected: ends with `quadtree_fat: all tests passed` then `All host tests passed.`

- [ ] **Step 8: Commit**

```bash
git add tests/qtree_test_include tests/quadtree_fat_test.cpp tests/run_tests.sh \
        work/solarus/include/solarus/containers/Quadtree.h \
        work/solarus/include/solarus/containers/Quadtree.inl
git commit -m "test(quadtree): host harness + move reinsert counter + margin plumbing

Standalone C++ test against the real Quadtree template (stub config.h + Debug
stubs, no SDL runtime). Adds fat_margin member/setter, SOLARUS_QTREE_MARGIN env
read, and a move() reinsert counter to make the upcoming hysteresis observable.
move() logic unchanged; margin defaults to 0.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015tcQg6rpvBn1daNKnS5GXr"
```

---

### Task 2: Skip the reinsert within margin (the optimization)

**Files:**
- Modify: `work/solarus/include/solarus/containers/Quadtree.inl` (`move()` fat path)
- Modify: `tests/quadtree_fat_test.cpp` (failing test first)

**Interfaces:**
- Consumes: `set_fat_margin`, `get_move_reinsert_count`, `Rectangle::contains(const Rectangle&)`, `Rectangle::add_xy/add_width/add_height` (all existing).
- Produces: no new symbols; `move()` gains the hysteresis behavior.

- [ ] **Step 1: Write the failing test**

Add to `tests/quadtree_fat_test.cpp` (before `main`), and call it from `main` after `test_baseline_margin0();`:

```cpp
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
```

- [ ] **Step 2: Run the test — verify it FAILS**

Run: `bash tests/run_tests.sh 2>&1 | grep -A2 quadtree_fat`
Expected: `FAIL: margin8: sub-margin moves skip reinsert` (current `move` reinserts every change, so the counter advances).

- [ ] **Step 3: Implement the fat-AABB path in `move()`**

In `work/solarus/include/solarus/containers/Quadtree.inl`, replace the body of `move()` from the `find` down to the final `return true;` with:

```cpp
  const auto& it = elements.find(element);
  if (it == elements.end()) {
    // Not in the quadtree: error.
    return false;
  }

  const Rectangle stored_box = it->second.bounding_box;  // copy: remove() erases it

  if (fat_margin <= 0) {
    // Feature disabled: original exact behavior.
    if (stored_box == bounding_box) {
      // Already in the quadtree and no change.
      return true;
    }
  }
  else {
    // Fat-AABB hysteresis: skip the reinsert while the true box stays inside
    // the stored (inflated) box. Correct because the stored box always
    // contains the true box, so get_elements still returns this element for
    // any query overlapping the true box; consumers re-test precisely.
    if (stored_box.contains(bounding_box)) {
      return true;
    }
  }

  if (!remove(element)) {
    // Failed to remove.
    return false;
  }

  Rectangle new_box = bounding_box;
  if (fat_margin > 0) {
    new_box.add_xy(-fat_margin, -fat_margin);
    new_box.add_width(2 * fat_margin);
    new_box.add_height(2 * fat_margin);
  }

  if (!add(element, new_box)) {
    // Failed to add.
    return false;
  }
  ++move_reinsert_count;
  return true;
```

Note: `stored_box` is copied (not a reference) because `remove()` erases the map entry, invalidating `it`.

- [ ] **Step 4: Run the test — verify it PASSES**

Run: `bash tests/run_tests.sh 2>&1 | grep -A2 quadtree_fat`
Expected: `quadtree_fat: all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add work/solarus/include/solarus/containers/Quadtree.inl tests/quadtree_fat_test.cpp
git commit -m "perf(quadtree): fat-AABB hysteresis skips reinsert within margin

move() stores an inflated box and skips remove+add while the true box stays
inside it (SOLARUS_QTREE_MARGIN px). margin 0 keeps the exact original path.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015tcQg6rpvBn1daNKnS5GXr"
```

---

### Task 3: Reinsert when the true box leaves the fat box

Guards against over-inflation / stale membership: a move beyond the margin must reinsert and the element must no longer be reported far from its new position.

**Files:**
- Modify: `tests/quadtree_fat_test.cpp`

**Interfaces:** consumes Task 2 behavior; no new symbols.

- [ ] **Step 1: Write the test**

Add to `tests/quadtree_fat_test.cpp` and call from `main`:

```cpp
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
```

- [ ] **Step 2: Run — expect PASS**

Run: `bash tests/run_tests.sh 2>&1 | grep -A2 quadtree_fat`
Expected: `quadtree_fat: all tests passed`.

- [ ] **Step 3: Commit**

```bash
git add tests/quadtree_fat_test.cpp
git commit -m "test(quadtree): reinsert + drop stale membership beyond fat box

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015tcQg6rpvBn1daNKnS5GXr"
```

---

### Task 4: No-miss invariant fuzz (the load-bearing correctness test)

Random-walks an element for many steps at margin 8; after every step the element MUST be returned by a query overlapping its true box. This is the property the whole design rests on.

**Files:**
- Modify: `tests/quadtree_fat_test.cpp`

**Interfaces:** consumes Task 2 behavior; no new symbols.

- [ ] **Step 1: Write the fuzz test**

Add to `tests/quadtree_fat_test.cpp` and call from `main`:

```cpp
// Fuzz: after every move (mostly ±1px steps, occasional jumps), a query that
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
```

- [ ] **Step 2: Run — expect PASS**

Run: `bash tests/run_tests.sh 2>&1 | grep -A3 quadtree_fat`
Expected: `quadtree_fat: all tests passed` (no `MISS` line).

- [ ] **Step 3: Commit**

```bash
git add tests/quadtree_fat_test.cpp
git commit -m "test(quadtree): no-miss invariant fuzz for fat-AABB hysteresis

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015tcQg6rpvBn1daNKnS5GXr"
```

---

### Task 5: Env-default parity test

Confirms `SOLARUS_QTREE_MARGIN` drives the default margin and that unset/0 is exact-behavior parity (the production gate).

**Files:**
- Modify: `tests/quadtree_fat_test.cpp`

**Interfaces:** consumes `read_fat_margin_env` (via constructor default) and `get_fat_margin`.

- [ ] **Step 1: Write the test**

Add to `tests/quadtree_fat_test.cpp` and call from `main`. Include `<cstdlib>` is already present; use `setenv`:

```cpp
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
```

- [ ] **Step 2: Run — expect PASS**

Run: `bash tests/run_tests.sh 2>&1 | grep -A2 quadtree_fat`
Expected: `quadtree_fat: all tests passed`.

- [ ] **Step 3: Commit**

```bash
git add tests/quadtree_fat_test.cpp
git commit -m "test(quadtree): SOLARUS_QTREE_MARGIN env-default + margin-0 parity

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_015tcQg6rpvBn1daNKnS5GXr"
```

---

### Task 6: Cross-build the engine + full host-test gate

Proves the header change compiles in the real armhf engine build (the template is instantiated by the engine's entity quadtree) and that all host tests are green. No engine call-site changes are needed — `Entities` constructs `Quadtree` and the env read wires the feature automatically.

**Files:** none (verification only).

- [ ] **Step 1: Run the full host test suite**

Run: `bash tests/run_tests.sh 2>&1 | tail -5`
Expected: `quadtree_fat: all tests passed` and final `All host tests passed.`

- [ ] **Step 2: Cross-build the armhf engine**

Run (matches the project's build path; requires the `solarus-armhf-build:bullseye` image):

```bash
docker run --rm -v "$PWD:/src" -w /src solarus-armhf-build:bullseye \
  scripts/build_engine.sh; echo "BUILD_EXIT=$?"
```

Expected: `BUILD_EXIT=0`, and `build/armhf/libsolarus.so.1.6.5` + `build/armhf/solarus-run` refreshed.

If Docker is unavailable in this environment, the `run_tests.sh` `quadtree_fat` step already compiles the modified `Quadtree.{h,inl}` against the real template, so a green host suite is the minimum gate. Additionally confirm the header parses cleanly on its own:

```bash
printf '#include "solarus/containers/Quadtree.h"\nint main(){return 0;}\n' > /tmp/qt_syntax.cpp
g++ -std=c++17 -I work/solarus/include -I tests/qtree_test_include \
    -I work/solarus/libraries/win32/mingw32/include -I work/SDL2-2.28.5/include \
    -fsyntax-only /tmp/qt_syntax.cpp; echo "SYNTAX_EXIT=$?"
```
Expected: `SYNTAX_EXIT=0`.

- [ ] **Step 3: Commit any build-artifact refresh notes (if applicable) and update the spec status**

No source changes expected here. If the engine was rebuilt, note the HW A/B recipe in the PR description rather than committing binaries (binaries are gitignored).

- [ ] **Step 4: Final verification summary**

Confirm before opening the PR:
- `bash tests/run_tests.sh` → all green (incl. `quadtree_fat`).
- Engine cross-build `BUILD_EXIT=0` (or Entities.cpp syntax check exit 0).
- Disabled parity: `SOLARUS_QTREE_MARGIN` unset behaves exactly as before (covered by Task 5 + baseline).

---

## HW validation (post-merge-readiness, done by the human on device)

Not a plan task, but the acceptance path: deploy the rebuilt engine, launch the heavy overworld, and A/B `SOLARUS_QTREE_MARGIN` unset vs `=8`. Read the win from the existing `g_me_ent_qtree_ns` banner (enemy quadtree bookkeeping ns/frame) and overall fps. Once validated, a follow-up bakes the default margin to 8 (out of scope here).

## Self-review notes

- **Spec coverage:** fat-AABB skip (Task 2), reinsert-beyond (Task 3), no-miss fuzz (Task 4), margin-0 parity + env gate (Tasks 1/5), quadtree-only scope (no call-site tasks — verified in Task 6), rollout default-0 (Global Constraints). All spec sections mapped.
- **Type consistency:** `set_fat_margin`/`get_fat_margin`/`get_move_reinsert_count`/`read_fat_margin_env`/`fat_margin`/`move_reinsert_count` used identically across Tasks 1–5.
- **No placeholders:** every code and command step is concrete and was validated against the real tree during planning.
