# Idle-Destructible Parking (`SOLARUS_IDLEPARK`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Exclude idle destructibles from the per-tick entity update walk (keeping cut/regen/animated ones live), landing the HW-measured +57% as a correct, gated feature.

**Architecture:** Engine changes are python-injection blocks in `scripts/build_engine.sh` that patch the upstream Solarus checkout at `work/solarus/` at build time — the source is NOT edited directly. Pure, Solarus-independent logic is extracted to a header under `patches/mister/` and host-unit-tested (the `mister_idleskip.h` pattern). `Entities` walks a maintained `entities_to_update` list = `all_entities` minus parked destructibles; a small set of wake hooks + an incremental re-scan sweep move destructibles between parked/active.

**Tech Stack:** C++14 (Solarus 1.6.5), armhf cross-build in docker `solarus-armhf-build:bullseye`, host `cc` for unit tests, MiSTer DE10-Nano HW at 192.168.20.81.

## Global Constraints

- Engine-only. No ABI/RTL/fabric change; no change to `deploy.py`'s RBF. Deploy is `--no-rbf`.
- Env-gated: `SOLARUS_IDLEPARK` (default OFF → stock `all_entities` walk, bit-identical to today).
- Reuse the PR #57 predicate `solarus_destructible_skippable()` from `patches/mister/mister_idleskip.h` as the sleep oracle — do not duplicate it.
- Injection anchors must match the real `work/solarus` source exactly; every injection block ends with a python `assert` that fails the build loudly on anchor drift. Verify anchors against source before writing the replacement.
- All injections are idempotent (`grep -q` guard) — a re-run of `build_engine.sh` must not double-inject.
- Branch: `perf/idle-destructible-park` (already created off PR #57, has `mister_idleskip.h`).
- Spec: `docs/superpowers/specs/2026-07-03-idle-destructible-park-design.md`.

---

## File Structure

- **Create** `patches/mister/mister_idlepark.h` — pure, Solarus-independent sweep-range helper: `solarus_idlepark_sweep_range()`. Header-only, C/C++ safe.
- **Create** `tests/idlepark_test.c` — host unit test for the sweep-range coverage/wrap/resize invariants.
- **Modify** `tests/run_tests.sh` — build+run the idlepark test.
- **Modify** `scripts/build_engine.sh` — injection blocks into `work/solarus`:
  - `include/solarus/entities/Entities.h`: new members (`entities_to_update`, `destructibles`, `idlepark_cursor`) + method decls.
  - `src/entities/Entities.cpp`: gated update loop over `entities_to_update`; add/remove maintenance; the incremental sweep; `wake_destructible`/`park_destructible` helpers.
  - `include/solarus/entities/Destructible.h`: `parked` flag + `entities_to_update` iterator handle + friend/accessor.
  - `src/entities/Destructible.cpp`: wake hooks in `play_destroy_animation()` + `explode()`; post-update sleep check.

---

## Task 1: Pure incremental-sweep range helper (host-TDD)

The one piece of non-trivial arithmetic: given a persistent cursor over `n` destructibles and a period `P`, which contiguous slice do we scan this tick, and where does the cursor land next — such that every index is visited at least once per `P` ticks, with even load and correct wrap/resize behaviour.

**Files:**
- Create: `patches/mister/mister_idlepark.h`
- Test: `tests/idlepark_test.c`
- Modify: `tests/run_tests.sh`

**Interfaces:**
- Produces: `void solarus_idlepark_sweep_range(int cursor, int n, int period, int* out_start, int* out_count, int* out_next_cursor);`
  - `cursor` in `[0, n)` (caller clamps); `n >= 0`; `period >= 1`.
  - Scans `out_count = ceil(n / period)` entries (0 when `n==0`), starting at `out_start = (n==0)?0:cursor`. The slice is `[out_start, out_start+out_count)` indices taken **modulo n** by the caller (may wrap past the end). `out_next_cursor = (n==0)?0:(cursor + out_count) % n`.

- [ ] **Step 1: Write the failing test**

```c
/* Host unit test for the incremental re-scan sweep-range helper (SOLARUS_IDLEPARK).
 *
 * The backstop re-scan sweeps all destructibles over RESCAN_PERIOD ticks at an even
 * ~n/period per tick (no O(n) spike). This locks the arithmetic: per-tick count is
 * ceil(n/period), the cursor advances by that count mod n, and repeatedly stepping the
 * cursor covers every index at least once within `period` ticks. Edge cases: n==0,
 * n<period (count==1), a mid-sweep resize.
 *
 * Build+run (from repo root):
 *   cc -Wall -Wextra -O2 -I patches/mister tests/idlepark_test.c -o /tmp/idlepark_test \
 *     && /tmp/idlepark_test
 */
#include "mister_idlepark.h"
#include <stdio.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); failures++; } \
} while (0)

/* ceil(n/period) entries per tick; cursor wraps mod n. */
static void test_count_and_advance(void)
{
    int start, count, next;
    solarus_idlepark_sweep_range(0, 700, 30, &start, &count, &next);
    CHECK(count == 24, "ceil(700/30)=24 per tick");   /* 700/30 = 23.33 -> 24 */
    CHECK(start == 0, "start at cursor");
    CHECK(next == 24, "cursor advances by count");

    solarus_idlepark_sweep_range(690, 700, 30, &start, &count, &next);
    CHECK(count == 24, "count independent of cursor");
    CHECK(start == 690, "start at cursor near end");
    CHECK(next == (690 + 24) % 700, "cursor wraps mod n (=14)");
}

/* n==0: nothing to scan, cursor pinned at 0 (no div-by-zero). */
static void test_empty(void)
{
    int start, count, next;
    solarus_idlepark_sweep_range(0, 0, 30, &start, &count, &next);
    CHECK(count == 0, "n==0 -> count 0");
    CHECK(start == 0 && next == 0, "n==0 -> cursor pinned 0");
}

/* n<period: at least 1 per tick so small maps still fully covered. */
static void test_small_n(void)
{
    int start, count, next;
    solarus_idlepark_sweep_range(3, 5, 30, &start, &count, &next);
    CHECK(count == 1, "ceil(5/30)=1");
    CHECK(start == 3, "start at cursor");
    CHECK(next == 4, "advance by 1");
    solarus_idlepark_sweep_range(4, 5, 30, &start, &count, &next);
    CHECK(next == 0, "wrap from last index to 0");
}

/* Coverage: from any start, `period` successive ticks visit every index at least once. */
static void test_full_coverage_in_period(void)
{
    const int n = 700, period = 30;
    int seen[700] = {0};
    int cursor = 123;  /* arbitrary start */
    for (int t = 0; t < period; ++t) {
        int start, count, next;
        solarus_idlepark_sweep_range(cursor, n, period, &start, &count, &next);
        for (int k = 0; k < count; ++k) seen[(start + k) % n] = 1;
        cursor = next;
    }
    int covered = 1;
    for (int i = 0; i < n; ++i) if (!seen[i]) covered = 0;
    CHECK(covered == 1, "every index covered within `period` ticks");
}

int main(void)
{
    test_count_and_advance();
    test_empty();
    test_small_n();
    test_full_coverage_in_period();
    if (failures) { printf("idlepark: %d FAILED\n", failures); return 1; }
    printf("idlepark: all passed\n");
    return 0;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cc -Wall -Wextra -O2 -I patches/mister tests/idlepark_test.c -o /tmp/idlepark_test`
Expected: FAIL to compile — `fatal error: mister_idlepark.h: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

Create `patches/mister/mister_idlepark.h`:

```c
/*
 * [perf] Incremental re-scan sweep-range for SOLARUS_IDLEPARK.
 *
 * The idle-destructible parking backstop re-scans all destructibles over RESCAN_PERIOD
 * ticks, ~n/period per tick, to catch wakes with no C++ chokepoint (Lua-driven sprite
 * animation / movement). This computes, for a persistent cursor over n destructibles,
 * the contiguous slice to scan this tick and the next cursor position. Spreading the
 * scan avoids an O(n) spike every Nth tick (a jitter / deadline hazard).
 *
 * The slice is [start, start+count) taken modulo n by the caller (it may wrap past the
 * end of the array). Every index is visited at least once per `period` ticks.
 *
 * Header-only, zero deps, C and C++ safe (see tests/idlepark_test.c).
 */
#ifndef MISTER_IDLEPARK_H
#define MISTER_IDLEPARK_H

#ifdef __cplusplus
extern "C" {
#endif

static inline void solarus_idlepark_sweep_range(
    int cursor, int n, int period,
    int* out_start, int* out_count, int* out_next_cursor) {
  if (n <= 0) { *out_start = 0; *out_count = 0; *out_next_cursor = 0; return; }
  if (period < 1) period = 1;
  if (cursor < 0 || cursor >= n) cursor = 0;   /* defensive clamp */
  int count = (n + period - 1) / period;       /* ceil(n/period), >=1 for n>=1 */
  *out_start = cursor;
  *out_count = count;
  *out_next_cursor = (cursor + count) % n;
}

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* MISTER_IDLEPARK_H */
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cc -Wall -Wextra -O2 -I patches/mister tests/idlepark_test.c -o /tmp/idlepark_test && /tmp/idlepark_test`
Expected: `idlepark: all passed`

- [ ] **Step 5: Wire into the test runner**

In `tests/run_tests.sh`, after the `idleskip` block (search for `== idleskip`), add:

```sh
echo "== idlepark (perf: idle-destructible re-scan sweep-range) =="
$CC -Wall -Wextra -O2 -I patches/mister \
    tests/idlepark_test.c \
    -o /tmp/idlepark_test
/tmp/idlepark_test
```

- [ ] **Step 6: Run the full test suite**

Run: `sh tests/run_tests.sh`
Expected: existing tests still pass; new line `idlepark: all passed`.

- [ ] **Step 7: Commit**

```bash
git add patches/mister/mister_idlepark.h tests/idlepark_test.c tests/run_tests.sh
git commit -m "perf(engine): idlepark incremental sweep-range helper + host test"
```

---

## Task 2: `Entities` parking container + gated walk + maintenance (injection)

Add the maintained walk list, the destructibles cache, the cursor, and the wake/park helpers to `Entities`, and switch the update loop to the gated walk. Verified by a clean armhf build (the injection `assert`s catch anchor drift) + `strings` gate check. Not host-unit-tested — this is integration into upstream types; correctness is proven by the build plus the HW test in Task 4.

**Files:**
- Modify: `scripts/build_engine.sh` (new injection block for Entities.h; extend the existing Entities.cpp `upd_new` block + add maintenance injections)
- Injects into: `work/solarus/include/solarus/entities/Entities.h`, `work/solarus/src/entities/Entities.cpp`

**Interfaces:**
- Consumes: `solarus_destructible_skippable(...)` (Task from PR #57, `mister_idlepark.h` sibling `mister_idleskip.h`); `solarus_idlepark_sweep_range(...)` (Task 1).
- Produces (for Task 3): on `Entities`
  - `void wake_destructible(Destructible* d);`  — if `d->idlepark_parked`, re-link into `entities_to_update`, clear the flag.
  - `void park_destructible(Destructible* d);`  — if not parked, unlink from `entities_to_update`, set the flag.
  - member `bool idlepark_enabled` (env-cached once).

- [ ] **Step 1: Add `<cstdlib>`/header include + `Entities.h` members (idempotent injection)**

In `scripts/build_engine.sh`, add a new injection block (guarded by `grep -q "entities_to_update"`) that edits `include/solarus/entities/Entities.h`. Anchor on the existing private member `all_entities` declaration (verified present: `EntityList all_entities;`). Insert after it:

```python
ENTH="$SRC/include/solarus/entities/Entities.h"
if ! grep -q "entities_to_update" "$ENTH"; then
  python3 - "$ENTH" <<'PYENTH'
import sys
path = sys.argv[1]
s = open(path).read()
anchor = "EntityList all_entities;"
assert anchor in s, "Entities.h all_entities member anchor not found"
add = (
  "EntityList all_entities;\n\n"
  "    // [perf SOLARUS_IDLEPARK] Walk list = all_entities minus parked (idle)\n"
  "    // destructibles; the update loop iterates this instead of all_entities when\n"
  "    // the gate is on. `destructibles` caches all destructibles for the incremental\n"
  "    // re-scan; `idlepark_cursor` is that sweep's persistent position.\n"
  "  public:\n"
  "    void wake_destructible(Destructible* d);\n"
  "    void park_destructible(Destructible* d);\n"
  "    bool idlepark_enabled = false;\n"
  "  private:\n"
  "    EntityList entities_to_update;\n"
  "    std::vector<Destructible*> destructibles;\n"
  "    int idlepark_cursor = 0;"
)
s = s.replace(anchor, add, 1)
open(path, "w").write(s)
print("Entities.h SOLARUS_IDLEPARK members injected")
PYENTH
fi
```

Note: `Destructible` must be visible in `Entities.h`. It is used only as a pointer here; add a forward declaration if the build complains — anchor on the existing `class Quadtree;` forward-decl line and append `class Destructible;`. (Confirm by building; add only if the compiler reports an incomplete type.)

- [ ] **Step 2: Switch the update loop to the gated walk + park-after-update + sweep**

In `scripts/build_engine.sh`, extend the `upd_new` string (the `Entities::update()` replacement) so the dynamic-entity walk becomes gated. Replace the single `for (const EntityPtr& entity: all_entities)` walk with:

```cpp
  static const bool _idlepark = (std::getenv("SOLARUS_IDLEPARK") != nullptr);
  idlepark_enabled = _idlepark;
  EntityList& _walk = _idlepark ? entities_to_update : all_entities;
  for (const EntityPtr& entity: _walk) {

    if (
        !entity->is_being_removed() &&
        entity->get_type() != EntityType::CAMERA  // The camera is updated after.
    ) {
      entity->update();
    }
    if (g_mister_lua_diag) {
      long long _me_t = _me_now_ns();
      int _me_ty = (int)entity->get_type();
      if ((unsigned)_me_ty < 32u) {
        g_me_ent_type_ns[_me_ty]  += _me_t - _me_prev;
        g_me_ent_type_cnt[_me_ty] += 1;
      }
      _me_prev = _me_t;
    }
    // [IDLEPARK] Park a destructible that has returned to idle. Safe: entities_to_update
    // holds EntityPtr; unlink is O(1) via the cached iterator (see park_destructible).
    if (_idlepark && entity->get_type() == EntityType::DESTRUCTIBLE) {
      Destructible* _d = static_cast<Destructible*>(entity.get());
      if (destructible_is_idle(_d)) park_destructible(_d);
    }
  }
  // [IDLEPARK] Incremental backstop sweep: wake any parked destructible that is no
  // longer idle (Lua-driven animation/movement has no C++ wake hook). ~n/30 per tick.
  if (_idlepark && !destructibles.empty()) {
    int _s, _c, _next;
    solarus_idlepark_sweep_range(idlepark_cursor, (int)destructibles.size(), 30,
                                 &_s, &_c, &_next);
    for (int _k = 0; _k < _c; ++_k) {
      Destructible* _d = destructibles[(_s + _k) % (int)destructibles.size()];
      if (!destructible_is_idle(_d)) wake_destructible(_d);
    }
    idlepark_cursor = _next;
  }
```

Note the loop must NOT recompute `EntityList::iterator` invalidation hazards: `park_destructible` erases the *current* element from `entities_to_update` while we iterate `_walk` (which aliases it under the gate). Use the classic erase-safe pattern — change the `for` to an explicit iterator loop so `park_destructible` returns/advances the iterator. Implement `park_destructible` to erase and the loop to capture the next iterator BEFORE the erase. (Concretely: iterate with `for (auto it = _walk.begin(); it != _walk.end(); ) { EntityPtr entity = *it; auto next = std::next(it); ...body...; if (parked-this-one) {} it = next; }` and have `park_destructible` erase by the cached iterator.) Spell this out in the injected code so iteration stays valid.

Add the required includes to the Entities.cpp diag block (where `<time.h>` etc. are added): `#include <cstdlib>`, `#include <vector>`, `#include "mister_idlepark.h"`, `#include "mister_idleskip.h"`, and `#include "solarus/entities/Destructible.h"`. Add a small file-local helper:

```cpp
namespace { inline bool destructible_is_idle(Destructible* d) {
  const SpritePtr& sp = d->get_sprite();
  bool spr = sp && !sp->is_paused() && !sp->is_animation_finished() && sp->get_frame_delay() > 0;
  return solarus_destructible_skippable(
      d->is_suspended()?1:0, d->get_is_being_cut()?1:0,
      d->is_waiting_for_regeneration()?1:0, d->get_is_regenerating()?1:0,
      (d->get_movement()!=nullptr)?1:0, d->has_stream_action()?1:0, spr?1:0);
} }
```

`get_is_being_cut()`/`get_is_regenerating()` accessors are added in Task 3 (private fields). If simpler, make `Entities` a friend of `Destructible` (Task 3) and read the fields directly.

- [ ] **Step 3: Inject `wake_destructible` / `park_destructible` + maintenance in add/remove**

Add (idempotent, guarded) to `Entities.cpp` — the helper bodies and the add/remove maintenance:

```cpp
void Entities::park_destructible(Destructible* d) {
  if (d->idlepark_parked) return;
  d->idlepark_parked = true;
  entities_to_update.erase(d->idlepark_it);   // O(1); iterator cached at insert
}
void Entities::wake_destructible(Destructible* d) {
  if (!d->idlepark_parked) return;
  d->idlepark_parked = false;
  d->idlepark_it = entities_to_update.insert(entities_to_update.end(),
                       std::static_pointer_cast<Entity>(d->shared_from_this()));
}
```

In `Entities::add_entity` (anchor `void Entities::add_entity(const EntityPtr& entity) {`) — after the entity is added to `all_entities`, mirror into `entities_to_update` and, if a destructible, into `destructibles`:

```cpp
  // [IDLEPARK] mirror into the update-walk list; destructibles start active and park
  // on their first idle tick. Cache the list iterator for O(1) park/wake.
  {
    auto _it = entities_to_update.insert(entities_to_update.end(), entity);
    if (entity->get_type() == EntityType::DESTRUCTIBLE) {
      Destructible* _d = static_cast<Destructible*>(entity.get());
      _d->idlepark_it = _it;
      _d->idlepark_parked = false;
      destructibles.push_back(_d);
    }
  }
```

In the removal path (`Entities::remove_marked_entities`, where an entity is erased from `all_entities`) — remove from `entities_to_update` (if not already parked) and from `destructibles`:

```cpp
  // [IDLEPARK] keep the walk list + destructibles cache in sync on removal.
  if (entity->get_type() == EntityType::DESTRUCTIBLE) {
    Destructible* _d = static_cast<Destructible*>(entity.get());
    if (!_d->idlepark_parked) entities_to_update.erase(_d->idlepark_it);
    destructibles.erase(std::remove(destructibles.begin(), destructibles.end(), _d),
                        destructibles.end());
  } else {
    // non-destructibles are never parked; erase by value (rare, on removal only).
    entities_to_update.remove(entity);
  }
```

Confirm the exact erase site in `remove_marked_entities` against source; the maintenance must run for the same entities that leave `all_entities`.

- [ ] **Step 4: Build armhf and verify clean + gate present**

Run:
```bash
git -C work/solarus checkout -- . && git -C work/solarus clean -fdq
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh 2>&1 | tee /tmp/idlepark_build.log | tail -5
grep -c 'error:' /tmp/idlepark_build.log
strings build/armhf/libsolarus.so.1.6.5 | grep -c SOLARUS_IDLEPARK
```
Expected: injection print lines for each block (`Entities.h SOLARUS_IDLEPARK members injected`, etc.), `error:` count 0, `SOLARUS_IDLEPARK` count `>=1`. If an `assert` fires (anchor drift) or the compile errors, fix the anchor/include and rebuild — do not proceed.

- [ ] **Step 5: Commit**

```bash
git add scripts/build_engine.sh
git commit -m "perf(engine): Entities idlepark walk list + maintenance + gated update loop"
```

---

## Task 3: `Destructible` wake hooks + fields (injection)

Add the `idlepark_parked` flag + iterator handle + accessors to `Destructible`, and the wake hooks so a cut/lift/explode instantly re-activates a parked bush. Verified by clean armhf build.

**Files:**
- Modify: `scripts/build_engine.sh` (new injection blocks for Destructible.h + Destructible.cpp)
- Injects into: `work/solarus/include/solarus/entities/Destructible.h`, `work/solarus/src/entities/Destructible.cpp`

**Interfaces:**
- Consumes: `Entities::wake_destructible` (Task 2).
- Produces: on `Destructible` — `bool idlepark_parked = false;`, `EntityList::iterator idlepark_it;`, accessors `bool get_is_being_cut() const { return is_being_cut; }`, `bool get_is_regenerating() const { return is_regenerating; }`. (Or `friend class Entities;` — pick one and use it consistently with Task 2 Step 2's helper.)

- [ ] **Step 1: Inject fields + accessors into Destructible.h**

Idempotent block (`grep -q idlepark_parked`) anchoring on the private field `bool is_regenerating;` (verified at Destructible.h:127). Insert after it:

```python
DESTRH="$SRC/include/solarus/entities/Destructible.h"
if ! grep -q "idlepark_parked" "$DESTRH"; then
  python3 - "$DESTRH" <<'PYDESTRH'
import sys
path = sys.argv[1]
s = open(path).read()
anchor = "bool is_regenerating;"
assert anchor in s, "Destructible.h is_regenerating field anchor not found"
# keep the original line, append the trailing comment already present by matching the field only
add = (anchor +
  "                /**< Whether this object is currently regenerating. */\n"
  "    // [perf SOLARUS_IDLEPARK] parking bookkeeping.\n"
  "  public:\n"
  "    bool get_is_being_cut() const { return is_being_cut; }\n"
  "    bool get_is_regenerating() const { return is_regenerating; }\n"
  "    bool idlepark_parked = false;\n"
  "    std::list<std::shared_ptr<Entity>>::iterator idlepark_it;\n")
# replace only the bare field declaration line (avoid double comment); match the line up to the newline
import re
s = re.sub(r"bool is_regenerating;[^\n]*\n", add + "  private:\n", s, count=1)
open(path, "w").write(s)
print("Destructible.h SOLARUS_IDLEPARK fields injected")
PYDESTRH
fi
```
Confirm `#include <list>`/`<memory>` visibility in Destructible.h (EntityPtr is already used; add includes only if the compiler reports missing types).

- [ ] **Step 2: Inject wake hooks into Destructible.cpp**

Idempotent block (`grep -q "get_entities().wake_destructible"` or similar guard). Two hook sites:

At the top of `Destructible::play_destroy_animation()` (anchor `void Destructible::play_destroy_animation() {`), insert:
```cpp
  // [IDLEPARK] a cut/lift/destroy re-activates a parked destructible immediately.
  get_entities().wake_destructible(this);
```
At the top of `Destructible::explode()` (anchor `void Destructible::explode() {`), insert the same wake line.

`get_entities()` is the standard `Entity` accessor returning the owning `Entities&`. Verify its exact name/const-ness in `Entity.h` (`Entities& get_entities();`); adapt the call if it is `get_entities()` vs `get_map().get_entities()`.

- [ ] **Step 3: Guard the wake hooks behind the gate**

Wake is cheap and idempotent, but keep it a no-op when the feature is off to guarantee bit-identical stock behaviour. Wrap each injected wake:
```cpp
  if (get_entities().idlepark_enabled) get_entities().wake_destructible(this);
```

- [ ] **Step 4: Build armhf, verify clean**

Run:
```bash
git -C work/solarus checkout -- . && git -C work/solarus clean -fdq
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh 2>&1 | tee /tmp/idlepark_build.log | tail -5
grep -c 'error:' /tmp/idlepark_build.log
grep -E 'idlepark|IDLEPARK' /tmp/idlepark_build.log
```
Expected: 0 errors; all idlepark injection print lines present.

- [ ] **Step 5: Run host test suite (regression)**

Run: `sh tests/run_tests.sh`
Expected: `idleskip: all passed` and `idlepark: all passed` both present, no failures.

- [ ] **Step 6: Commit**

```bash
git add scripts/build_engine.sh
git commit -m "perf(engine): Destructible idlepark wake hooks (play_destroy_animation/explode) + fields"
```

---

## Task 4: Deploy + HW validation (standing win + cutting/regen correctness)

The correctness case the probe could not do. Prove: standing fps ≈ probe ceiling; cutting grass animates + drops treasure + regrows after ~10 s; no garbage; A/B vs gate-off.

**Files:** none (uses `deploy.py`, on-device `diag.env`).

- [ ] **Step 1: Refresh deploy artifacts + deploy engine-only**

```bash
cp build/armhf/solarus-run deploy/solarus-run
cp build/armhf/libsolarus.so.1.6.5 deploy/libs/libsolarus.so.1.6.5
strings deploy/libs/libsolarus.so.1.6.5 | grep -c SOLARUS_IDLEPARK   # expect >=1
./deploy.py --no-rbf
```
Expected: `sha1 ok for all 28 libs`, `Done`.

- [ ] **Step 2: Set the probe arm flag + relaunch**

On device, set `diag.env` to the parking arm (remove `SOLARUS_IDLELIST`/`SOLARUS_IDLESKIP`, add `SOLARUS_IDLEPARK=1`), keep `SOLARUS_TILERESIDENT=1 SOLARUS_FASTPACE=1 SOLARUS_AUDIO_THREAD=1 SOLARUS_BLITTER_DIAG=1`. Load the Solarus core (`load_core` via `/dev/MiSTer_cmd`), wait for `quest_manager`, write a fresh `/media/fat/config/Solarus.s0` = the MoSDX `.sol` path, wait for `pidof solarus-run`. (Full recipe in memory `solarus-heavy-area-profile-and-offloads`.)

- [ ] **Step 3: Drive to the heavy overworld spot + measure standing**

Hammer Action (`busybox devmem 0x3A000008 32 0x20` / `0x00`, ~300×) to load the save. Let it settle; read banners:
```bash
ssh root@192.168.20.81 'L=/media/fat/logs/Solarus/Solarus.diag.log; \
  grep "blitter timing" $L | tail -6; grep "blitter engcpp" $L | tail -4; \
  grep "blitter enttype" $L | tail -3'
```
Expected: fps ~22–23 (near the IDLELIST probe), `enttype` destructible bucket ~absent or tiny, `steps/fr` ~4.3, no fatal.

- [ ] **Step 4: Cutting-grass correctness (the key gate)**

Drive the hero into/over cuttable bushes and swing the sword (map the sword/lift button via the joypad register; sword is a separate bit — confirm from the control map). Observe via screenshots (`echo screenshot > /dev/MiSTer_cmd`, pull with scp): a struck bush must play its cut animation, disappear/drop its item, and — for regenerating bushes — reappear after ~10 s. Confirm no frozen bush and no visual garbage. Take before/after screenshots.

- [ ] **Step 5: A/B vs gate-off + record**

Toggle `SOLARUS_IDLEPARK` off in `diag.env`, relaunch, same spot, capture fps (expect ~15 baseline). Confirm the delta matches the probe (~+50%). Record the standing A/B + cutting-correctness result to memory `solarus-idleskip-hw-validated` (or a new `solarus-idlepark-hw` note): fps off/on, destructible bucket, steps/fr, and the cut+regen confirmation.

- [ ] **Step 6: Restore a safe device config**

Leave `diag.env` with `SOLARUS_IDLEPARK=1` (validated safe) OR revert to `SOLARUS_IDLESKIP=1` per user preference; relaunch so the device is in a playable state.

---

## Self-Review

**Spec coverage:**
- Gate `SOLARUS_IDLEPARK`, default off → Task 2 Step 2 (`std::getenv`, `_walk` alias), Task 3 Step 3 (guarded hooks). ✓
- Walk = all_entities minus parked → Task 2 Steps 1–3. ✓
- Reuse PR#57 predicate as sleep oracle → Task 2 Step 2 `destructible_is_idle`. ✓
- Wake hooks at play_destroy_animation + explode → Task 3 Step 2. ✓
- Incremental staggered re-scan (n/30/tick, cursor) → Task 1 (helper+test) + Task 2 Step 2 (sweep). ✓
- Regen lifecycle stays active until idle-again → Task 2 Step 2 park-after-update uses the predicate (is_being_cut/regen/waiting all veto). ✓
- Suspend independent of walk → no code needed (verified Entities.cpp:1144); noted in spec. ✓
- Draw/collision unaffected → all_entities untouched; no task changes them. ✓
- Membership maintenance at add/remove → Task 2 Step 3. ✓
- Testing: host (Task 1) + HW standing + cutting + regen (Task 4). ✓

**Placeholder scan:** iterator-invalidation handling in Task 2 Step 2 is described in prose with the exact erase-safe pattern spelled out — the implementer must render it as explicit iterator code; flagged, not left vague. Sword-button bit in Task 4 Step 4 says "confirm from the control map" (a genuine lookup, not a code placeholder).

**Type consistency:** `idlepark_parked` (bool), `idlepark_it` (`EntityList::iterator` == `std::list<EntityPtr>::iterator`), `wake_destructible`/`park_destructible`, `idlepark_enabled`, `destructible_is_idle`, `solarus_idlepark_sweep_range` — names/signatures consistent across Tasks 1–3. `EntityList` == `std::list<EntityPtr>` == `std::list<std::shared_ptr<Entity>>` (Entities.h:50). ✓

**Known implementation risk (call out to executor):** the erase-during-iteration in Task 2 Step 2 is the sharp edge — `park_destructible` erases the current node of the same list being walked. Must use the capture-next-then-erase pattern; a fresh subagent should treat that step's prose as a hard requirement and write explicit safe-iteration code, then confirm on the armhf build (and ideally a targeted stress: cut several bushes while standing).
