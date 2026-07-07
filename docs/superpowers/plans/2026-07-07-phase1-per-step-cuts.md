# Phase 1 — per-step cuts (60fps campaign) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut Solarus's per-logic-step A9 cost at the heavy village save spot from
~5.2 ms to ≤ 4.0 ms (stretch 3.5 ms), with **zero gameplay/semantic change**, by
landing the five levers the Phase 0 LD_PROFILE attribution surfaced
(`docs/superpowers/2026-07-07-gprof-attribution.md`): **1e** z-sorted-visible-list
cache, **1d** kill the Lua-console spin-thread, **1f** `userdata_has_field`
cache + assertion-call fast path, **1a** static-entity park, **1b** enemy
ground-cell cache.

**Architecture:** Every lever is a single, independently revertible change
behind a `SOLARUS_*` env flag (or, for 1d, a launch-script argument), following
the exact pattern already shipped for `SOLARUS_IDLEPARK`/`SOLARUS_IDLESKIP`/
`SOLARUS_CULL_MARGIN`/`SOLARUS_QTREE_MARGIN`: a pure, host-testable predicate
or cache-key computation where one naturally exists, wired into the live engine
path, gated **default OFF** until HW A/B confirms it, then baked to default-ON
in a follow-up commit (never in this plan — that's a separate decision after
HW validation per lever).

**Tech Stack:** C++17 (Solarus engine, `work/solarus`), the repo's git
patch-series build (`patches/series/*.patch` via `git am --3way` +
`patches/mister/**` whole-file copies, see `scripts/apply_patch_series.sh`),
host-compiled C predicate unit tests (`tests/*.c` + `tests/run_tests.sh`,
plain `cc`, no framework), the `solarus-armhf-build:bullseye` Docker cross
build, and HW A/B on the DE10-Nano at `192.168.20.81` using the existing
`[blitter timing|hwperf|engcpp|enttype|entphase|entsplit]` diag banners
(`SOLARUS_BLITTER_DIAG=1`).

## Global Constraints

- **No gameplay/semantic change.** This is the campaign's hard success
  criterion (`docs/superpowers/specs/2026-07-07-60fps-campaign-design.md`).
  Any lever whose correctness can't be reasoned about with confidence is
  descoped rather than shipped speculatively (this plan descopes the
  obstacle-test-funnel half of lever 1b for exactly this reason — see Task 9).
- **Every lever ships behind a flag, default OFF**, exactly like
  `SOLARUS_IDLESKIP`/`SOLARUS_IDLEPARK` started (`std::getenv("SOLARUS_X") !=
  nullptr` → ON). Do not flip any flag to default-ON in this plan — that only
  happens after the lever's own HW A/B task confirms it (mirrors the
  IDLESKIP → IDLEPARK → default-ON arc in memory
  `solarus-idleskip-hw-validated`).
- **Author all upstream-file edits inside `work/solarus`** (a live git clone,
  reset-and-reapplied by `scripts/apply_patch_series.sh`), commit there, then
  regenerate `patches/series/*.patch` with `scripts/export_patches.sh` from the
  repo root. **Author brand-new standalone files under `patches/mister/`**
  (source of truth; copied into `work/solarus` by
  `scripts/apply_mister_files.sh`, which needs a new `cp` line for any new
  file — see Task 7).
- **Verify with the Docker build**, not `g++ -fsyntax-only` (memory
  `solarus-sdram-asset-residency-pr66`: clang syntax-only has previously missed
  real armhf build breaks).
- **Commit inside `work/solarus` and run `scripts/export_patches.sh` BEFORE
  running the Docker build, never after.** `scripts/build_engine.sh` calls
  `scripts/apply_patch_series.sh` as its first step, which hard-resets
  `work/solarus` to pristine upstream and `git clean -fdx`s it, then
  reapplies only what's already captured in `patches/series/*.patch`. Any
  edit not yet committed-and-exported is silently destroyed by that reset —
  discovered the hard way during Task 2. Order for every task touching
  `work/solarus`: edit → `git commit` inside `work/solarus` →
  `scripts/export_patches.sh` from the repo root → *then* the Docker build →
  commit `patches/series/` in the outer repo. Where a task's numbered steps
  below show the Docker build before the commit step, treat this constraint
  as authoritative and do commit+export first.
- Same save-spot, same measurement protocol as Phase 0/the design spec: stand
  ≥ 60 s, ≥ 5 consecutive 60-frame diag windows, A/B same session, final
  acceptance with diag OFF (diag itself costs A9 time).

---

## File Structure

| File | Role |
|---|---|
| `games/Solarus/solarus_run.sh` | Launch script — lever 1d (`-lua-console` arg). |
| `work/solarus/include/solarus/core/Debug.h` | Lever 1f-a: inline fast path for `Debug::check_assertion`. |
| `work/solarus/include/solarus/lua/LuaContext.h`, `work/solarus/src/lua/LuaContext.cpp` | Lever 1f-b: `userdata_has_field` result cache. |
| `work/solarus/src/entities/Camera.cpp` | Lever 1e-a: stop the camera from unconditionally dirtying every tick. |
| `work/solarus/include/solarus/entities/Entities.h`, `work/solarus/src/entities/Entities.cpp` | Lever 1e-b: `entities_to_draw` dirty-flag cache. Lever 1a-b: static-park integration. |
| `work/solarus/src/graphics/sdlrenderer/mister_blitter_renderer.cpp` | Diag counters + banner line for 1e cache hit/miss (measurement). |
| `patches/mister/mister_staticpark.h` (new) | Lever 1a-a: pure idle predicate for Wall/Teletransporter/Destination, mirrors `mister_idleskip.h`. |
| `tests/staticpark_test.c` (new) | Host unit test for the new predicate. |
| `work/solarus/include/solarus/entities/Entity.h`, `work/solarus/src/entities/Entity.cpp` | Lever 1b: ground-cell cache on `update_ground_below()`. |
| `scripts/apply_mister_files.sh`, `tests/run_tests.sh` | Build/test wiring for the new file. |

---

## Task 1: Lever 1d — kill the Lua-console spin-thread

Report finding F1: the daemon launches the engine with stdin = `/dev/null`, so
the Lua-console `getline()` loop EOFs instantly and busy-polls
`MainLoop::is_exiting()` 173 M times/run (ranks #2–#3 in the raw profile),
burning a full A9 core that contends with the core-1 audio thread. The engine
already supports disabling it: `work/solarus/src/main/Main.cpp:70` documents
`-lua-console=yes|no` (default yes), consumed at
`work/solarus/src/core/MainLoop.cpp:206-210`. **No engine-code change is
needed** — this is a launch-script-only lever.

**Files:**
- Modify: `games/Solarus/solarus_run.sh:129,132`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: nothing consumed by later tasks (independent lever).

- [ ] **Step 1: Add the gated CLI arg**

Edit `games/Solarus/solarus_run.sh`, right before the diag-capture branch
(currently line 125, `if [ -n "$SOLARUS_BLITTER_DIAG" ]; then`), insert:

```bash
# [MiSTer #Phase1-1d] Lua-console stdin thread: the daemon launches with
# stdin=/dev/null, so the console's getline() loop EOFs instantly and
# busy-polls MainLoop::is_exiting() -- a whole A9 core spinning for nothing
# (Phase 0 LD_PROFILE: docs/superpowers/2026-07-07-gprof-attribution.md, F1).
# Lever default OFF (SOLARUS_LUACONSOLE unset -> -lua-console=yes, today's
# shipped behavior, unchanged) until HW A/B'd; set SOLARUS_LUACONSOLE=1 to
# apply the fix (kill the spin thread) for testing.
LUACONSOLE_ARG="-lua-console=yes"
if [ "${SOLARUS_LUACONSOLE:-0}" = "1" ]; then
    LUACONSOLE_ARG="-lua-console=no"
fi
echo "Solarus: lua-console=${SOLARUS_LUACONSOLE:-0} (arg: $LUACONSOLE_ARG)"
```

Then change the two `exec` lines to pass it:

```bash
    exec ./solarus-run -force-software-rendering "$LUACONSOLE_ARG" "$QUEST" >"$DIAGLOG" 2>&1
```

and

```bash
exec ./solarus-run -force-software-rendering "$LUACONSOLE_ARG" "$QUEST"
```

- [ ] **Step 2: Shellcheck / sanity**

Run: `bash -n games/Solarus/solarus_run.sh`
Expected: no output (syntax OK).

- [ ] **Step 3: Commit**

```bash
git add games/Solarus/solarus_run.sh
git commit -m "perf(launch): gate the Lua-console stdin thread, default off (SOLARUS_LUACONSOLE)"
```

- [ ] **Step 4: HW A/B (deploy + measure)**

Deploy, then with `SOLARUS_LUACONSOLE` unset (default, console thread still
spinning, today's shipped behavior) in `diag.env`, drive to the
village save spot, stand 60 s, capture
`[blitter timing|hwperf|engcpp]` (5 windows). Repeat with
`SOLARUS_LUACONSOLE=1` (the fix applied). Compare fps/A9-busy. Per the report, the frame-time
effect is **unknown until this A/B** (it's other-thread contention, not
main-thread ms) — record the delta either way; this is a real ship bug fix
regardless (frees a core from useless spinning), so it's worth landing even if
the fps delta is small. Note the result in the plan's tracking issue /
handoff, do not flip any default here.

---

## Task 2: Lever 1f-a — inline fast path for `Debug::check_assertion`

Report finding F2: `Debug::check_assertion` is 0.80 % of the whole-run profile
(5.8 M calls), described by the design spec as "assertions compiled into a
shipping build." Verify first: `work/solarus/include/solarus/core/Debug.h:23-27`
shows the `SOLARUS_ASSERT(...)` **macro** already compiles to nothing under
`NDEBUG` — so the cost is not that macro. It's from call sites that invoke
`Debug::check_assertion(...)` **directly** (bypassing the macro), e.g.
`Entities.cpp:1332` (`Debug::check_assertion(map.is_valid_layer(layer), "Invalid
layer");`) and the pixel-collision bounds check the profile flagged (F3). Those
calls are never gated by `NDEBUG` and, because `check_assertion` is
`SOLARUS_API` (exported, out-of-line), every one of the 5.8 M calls pays a
cross-DSO PLT hop even on the always-true fast path. Fix: make the bool-check
`inline` in the header so the assertion-holds path never leaves the
translation unit; keep `die()` (the rare, fatal, non-perf-sensitive path)
exported and out-of-line. This does not change `-DNDEBUG`/`SOLARUS_ASSERT`
behavior and does not touch any of the ~100+ call sites.

**Files:**
- Modify: `work/solarus/include/solarus/core/Debug.h:44-45`
- Modify: `work/solarus/src/core/Debug.cpp:92-114`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks (independent lever, always-on —
  see step 4, this one has no runtime flag because it's behavior-identical by
  construction, not a gameplay-affecting change).

- [ ] **Step 1: Confirm the direct-call hypothesis**

```bash
grep -rn "Debug::check_assertion(" work/solarus/src work/solarus/include | wc -l
grep -rn "SOLARUS_ASSERT(" work/solarus/src work/solarus/include | wc -l
```

Expected: a non-trivial count of direct `Debug::check_assertion(` calls
(these are the ones this fix reaches; `SOLARUS_ASSERT`-macro calls were
already free under `NDEBUG` and are untouched).

- [ ] **Step 2: Move the fast path into the header**

Edit `work/solarus/include/solarus/core/Debug.h`, replace lines 44-45:

```cpp
SOLARUS_API void check_assertion(bool assertion, const char* error_message);
SOLARUS_API void check_assertion(bool assertion, const std::string& error_message);
```

with:

```cpp
[[noreturn]] SOLARUS_API void die(const std::string& error_message);

// [MiSTer #Phase1-1f] check_assertion is called ~5.8M times/run in a shipping
// build (Phase 0 LD_PROFILE, finding F2) from call sites that bypass the
// NDEBUG-gated SOLARUS_ASSERT macro. It was an out-of-line SOLARUS_API
// (exported) function, so every call -- including the always-true fast path
// -- paid a cross-DSO PLT hop. Inlining the bool check keeps the hop only on
// the die() (fatal, rare) path; behavior is identical.
inline void check_assertion(bool assertion, const char* error_message) {
  if (!assertion) {
    die(error_message);
  }
}
inline void check_assertion(bool assertion, const std::string& error_message) {
  if (!assertion) {
    die(error_message);
  }
}
```

Note `die()`'s declaration moves above the two inline functions (it must be
declared before they call it); delete the old `die()` declaration further down
at the former line 46.

- [ ] **Step 3: Remove the now-redundant out-of-line definitions**

Edit `work/solarus/src/core/Debug.cpp`, delete the two out-of-line
`check_assertion` definitions (the `SOLARUS_API` overloads at former lines
96-114), keeping `die()`'s own definition (further down, unchanged).

- [ ] **Step 4: Commit inside work/solarus, then export**

Commit-and-export MUST happen before the Docker build, not after: `scripts/
build_engine.sh` resets `work/solarus` to pristine + reapplies only what's
already in `patches/series/`, silently destroying any uncommitted edit.

```bash
cd work/solarus
git add include/solarus/core/Debug.h src/core/Debug.cpp
git commit -m "perf(debug): inline check_assertion fast path, avoid PLT hop on the always-true path"
cd ../..
scripts/export_patches.sh
```

- [ ] **Step 5: Docker build sanity (link check)**

`SOLARUS_API` on a Windows/MSVC dllexport build would need `inline` to avoid a
duplicate-symbol/export mismatch; on the armhf ELF build (`SOLARUS_API` is a
no-op or `__attribute__((visibility("default")))`, standard ELF) plain
`inline` in a header is safe and normal. Build to confirm:

```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye \
  scripts/build_engine.sh
```

Expected: build succeeds, no duplicate-symbol or unresolved-`check_assertion`
link errors.

- [ ] **Step 6: Commit outer repo**

```bash
git add patches/series/
git commit -m "perf(debug): inline check_assertion fast path (F2)"
```

---

## Task 3: Lever 1f-b — `userdata_has_field` result cache

Report: `userdata_has_field` (×3 call shapes: `const char*`, `const
std::string&`, `userdata_has_metafield`) is ~2.0 % of the profile (~1.5
ms/frame est.), called every frame per entity/item/game callback probe
(`entity_on_pre_draw`/`entity_on_post_draw` alone are 128 K calls each per the
call-pair data) even when the quest script never defines the field.
`work/solarus/src/lua/LuaContext.cpp:559-617` shows each call redoes a
`luaL_getmetatable` + `lua_rawget` (Lua C-API round trip) **and** a
`userdata_fields` map/set lookup, every time, for every probe.

**Design:** cache the **combined boolean result** (metafield check + instance
field check) per `(userdata pointer, key)`, invalidated at the single
chokepoint where `userdata_fields` is mutated
(`LuaContext::userdata_meta_newindex_as_table`,
`work/solarus/src/lua/LuaContext.cpp:1451-1508`) plus the two places
`userdata_fields` entries are removed/cleared
(`notify_userdata_destroyed` line 1410, `userdata_close_lua` line 1432) — a
stale pointer surviving in the cache after the userdata is destroyed and the
address gets reused by the allocator would be a real, silent-corruption bug,
so both cleanup sites must also clear the cache.

**Files:**
- Modify: `work/solarus/include/solarus/lua/LuaContext.h:1681-1685` (add cache
  member near `userdata_fields`)
- Modify: `work/solarus/src/lua/LuaContext.cpp:559-617` (read/write the cache
  in both `userdata_has_field` overloads)
- Modify: `work/solarus/src/lua/LuaContext.cpp:1389-1412` (clear cache entry
  in `notify_userdata_destroyed`)
- Modify: `work/solarus/src/lua/LuaContext.cpp:1420-1432` (clear whole cache
  in `userdata_close_lua`)
- Modify: `work/solarus/src/lua/LuaContext.cpp:1451-1508`
  (`userdata_meta_newindex_as_table`: invalidate the touched entry)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks (independent lever).

- [ ] **Step 1: Add the cache member**

Edit `work/solarus/include/solarus/lua/LuaContext.h`, right after the
`userdata_fields` declaration (former lines 1681-1685):

```cpp
    std::map<const ExportableToLua*, std::set<std::string>>
        userdata_fields;               /**< Existing string keys created on each
                                        * userdata with our __newindex. This is
                                        * only for performance, to avoid Lua
                                        * lookups for callbacks like on_update. */
    // [MiSTer #Phase1-1f, SOLARUS_HASFIELDCACHE] Cached userdata_has_field()
    // result per (userdata, key). Combines the metatable check (static for
    // the process lifetime) and the userdata_fields instance check (mutated
    // only by userdata_meta_newindex_as_table, which invalidates the exact
    // entry it touches -- see there). Cleared per-userdata in
    // notify_userdata_destroyed and wholesale in userdata_close_lua so a
    // reused allocator address never inherits a stale entry. mutable: a
    // pure performance-only side table written from userdata_has_field(),
    // which must stay const (it's called from many const contexts) --
    // standard "mutable cache member" idiom, no const_cast needed.
    mutable std::map<const ExportableToLua*, std::map<std::string, bool>>
        userdata_has_field_cache;
```

- [ ] **Step 2: Route both `userdata_has_field` overloads through the cache**

Replace `work/solarus/src/lua/LuaContext.cpp:559-617` (both overloads) with:

```cpp
bool LuaContext::userdata_has_field(
    const ExportableToLua& userdata, const char* key) const {
  return userdata_has_field(userdata, std::string(key));
}

bool LuaContext::userdata_has_field(
    const ExportableToLua& userdata, const std::string& key) const {

  // [SOLARUS_HASFIELDCACHE] default OFF until HW A/B'd.
  static const bool _hasfieldcache =
      (std::getenv("SOLARUS_HASFIELDCACHE") != nullptr);

  if (_hasfieldcache) {
    const auto& outer = userdata_has_field_cache.find(&userdata);
    if (outer != userdata_has_field_cache.end()) {
      const auto& inner = outer->second.find(key);
      if (inner != outer->second.end()) {
        return inner->second;
      }
    }
  }

  bool result = false;
  if (userdata_has_metafield(userdata, key.c_str())) {
    result = true;
  }
  else if (userdata.is_with_lua_table()) {
    const auto& it = userdata_fields.find(&userdata);
    result = (it != userdata_fields.end()) &&
        (it->second.find(key) != it->second.end());
  }

  if (_hasfieldcache) {
    userdata_has_field_cache[&userdata][key] = result;
  }
  return result;
}
```

`userdata_has_field` is `const`; writing to `userdata_has_field_cache` from
it is legal because the member is declared `mutable` (Step 1) — the standard
C++ idiom for a performance-only cache that doesn't change the object's
observable state.

Add `#include <cstdlib>` near the top of `LuaContext.cpp` if not already
present (needed for `std::getenv`):

```bash
grep -n "#include <cstdlib>" work/solarus/src/lua/LuaContext.cpp || \
  sed -i '' '1a\
#include <cstdlib>
' work/solarus/src/lua/LuaContext.cpp
```

(Adjust with a normal editor insert if `sed -i ''` syntax doesn't match your
platform — the requirement is just that `<cstdlib>` is included once, before
first use.)

- [ ] **Step 3: Invalidate on mutation**

Edit `work/solarus/src/lua/LuaContext.cpp:1496-1505` inside
`userdata_meta_newindex_as_table`:

```cpp
  if (lua_isstring(l, 2)) {
    const std::string field_key = lua_tostring(l, 2);
    if (!lua_isnil(l, 3)) {
      // Add the key to the list of existing strings keys on this userdata.
      get().userdata_fields[userdata.get()].insert(field_key);
    }
    else {
      // Assigning nil: remove the key from the list.
      get().userdata_fields[userdata.get()].erase(field_key);
    }
    // [SOLARUS_HASFIELDCACHE] This is the only place userdata_fields is
    // mutated for an existing userdata: drop the cached result for exactly
    // this (userdata, key) so the next userdata_has_field() call recomputes.
    auto& cache = get().userdata_has_field_cache;
    const auto& outer = cache.find(userdata.get());
    if (outer != cache.end()) {
      outer->second.erase(field_key);
    }
  }
```

- [ ] **Step 4: Clear on destroy / close**

Edit `work/solarus/src/lua/LuaContext.cpp:1410`, right after
`get().userdata_fields.erase(&userdata);` inside `notify_userdata_destroyed`:

```cpp
    get().userdata_fields.erase(&userdata);
    get().userdata_has_field_cache.erase(&userdata);  // [SOLARUS_HASFIELDCACHE]
```

Edit `work/solarus/src/lua/LuaContext.cpp:1432`, right after
`userdata_fields.clear();` inside `userdata_close_lua`:

```cpp
  userdata_fields.clear();
  userdata_has_field_cache.clear();  // [SOLARUS_HASFIELDCACHE]
```

- [ ] **Step 5: Commit inside work/solarus, then export**

Commit-and-export MUST happen before the Docker build (see Global
Constraints — the build resets `work/solarus` and destroys uncommitted edits).

```bash
cd work/solarus
git add include/solarus/lua/LuaContext.h src/lua/LuaContext.cpp
git commit -m "perf(lua): cache userdata_has_field() results, default off (SOLARUS_HASFIELDCACHE)"
cd ../..
scripts/export_patches.sh
```

- [ ] **Step 6: Docker build**

```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye \
  scripts/build_engine.sh
```

Expected: clean build.

- [ ] **Step 7: Commit outer repo**

```bash
git add patches/series/
git commit -m "perf(lua): userdata_has_field() result cache (Phase 1 lever 1f)"
```

- [ ] **Step 8: HW A/B**

Deploy, `diag.env`: `SOLARUS_HASFIELDCACHE=0` then `=1`, same save spot, same
protocol as Task 1 Step 4. Confirm no behavior change: dialogues, item use,
and any custom `on_pre_draw`/`on_post_draw` quest scripts must still fire
identically (gameplay soak — walk through at least one dialogue and one item
use with the flag ON). Record fps/A9-busy delta.

---

## Task 4: Lever 1e-a — stop the camera from dirtying every tick unconditionally

This is a prerequisite bugfix for Task 5. `Camera`'s tracking state
(`work/solarus/src/entities/Camera.cpp:93-106`, `TrackingState::update()`)
recomputes the camera's target box every tick and calls
`camera.set_bounding_box(...)` + `camera.notify_bounding_box_changed()`
**unconditionally**, even when the hero (and thus the camera) hasn't actually
moved (standing still). `notify_bounding_box_changed()` →
`Entities::notify_entity_bounding_box_changed()` is the exact hook Task 5's
draw-list cache uses to invalidate itself — left as-is, the cache would
invalidate every single frame regardless of whether anything moved, which
defeats lever 1e's entire premise ("when standing still ... pure waste").

**Files:**
- Modify: `work/solarus/src/entities/Camera.cpp:93-106`

**Interfaces:**
- Consumes: nothing.
- Produces: makes `Entities::notify_entity_bounding_box_changed` fire for the
  camera **only on an actual position/size change** — Task 5 depends on this
  being true for the "standing still ⇒ zero rebuilds" claim to hold.

- [ ] **Step 1: Guard the normal-case branch on an actual change**

Edit `work/solarus/src/entities/Camera.cpp`, replace the normal-case body
(lines 96-106):

```cpp
  if (separator_next_scrolling_date == 0) {
    // Normal case: not traversing a separator.

    // First compute camera coordinates ignoring map limits and separators.
    Rectangle next = camera.get_bounding_box();
    next.set_center(tracked_entity->get_center_point());

    // Then apply constraints of both separators and map limits.
    camera.set_bounding_box(camera.apply_separators_and_map_bounds(next));
    camera.notify_bounding_box_changed();
  }
```

with:

```cpp
  if (separator_next_scrolling_date == 0) {
    // Normal case: not traversing a separator.

    // First compute camera coordinates ignoring map limits and separators.
    Rectangle next = camera.get_bounding_box();
    next.set_center(tracked_entity->get_center_point());
    next = camera.apply_separators_and_map_bounds(next);

    // [MiSTer #Phase1-1e] Standing still, next == the current box every tick:
    // don't call set_bounding_box()/notify_bounding_box_changed() for a
    // no-op change. This was previously unconditional and dirtied every
    // downstream cache keyed on camera movement once per frame regardless of
    // whether the camera actually moved.
    if (next != camera.get_bounding_box()) {
      camera.set_bounding_box(next);
      camera.notify_bounding_box_changed();
    }
  }
```

- [ ] **Step 2: Confirm `Rectangle` has `operator!=`**

```bash
grep -n "operator!=\|operator==" work/solarus/include/solarus/core/Rectangle.h
```

Expected: both declared (if only `operator==` exists, use
`!(next == camera.get_bounding_box())` instead).

- [ ] **Step 3: Commit inside work/solarus (no Docker build yet)**

Commit BEFORE any Docker build (see Global Constraints — the build resets
`work/solarus` and destroys uncommitted edits). This task's own build
verification is deferred to Task 5's Docker build, which covers both
commits together as one patch pair — do not build here.

```bash
cd work/solarus
git add src/entities/Camera.cpp
git commit -m "perf(camera): skip redundant bounding-box notify when tracking target hasn't moved"
cd ../..
```

Do not export/commit the outer repo yet if continuing directly into Task 5 in
the same sitting — export once at the end of Task 5 (after Task 5's own
commit) so the two land as one reviewable patch pair, and Task 5's Docker
build verifies both together. If Task 5 will NOT run in the same sitting,
run `scripts/export_patches.sh` and the Docker build now instead, so this
task's own change is verified before the session ends.

---

## Task 5: Lever 1e-b — `entities_to_draw` dirty-flag cache (the #1 lever)

Report: the quadtree `get_elements` + Z-order sort/unique/insert family is the
**single largest main-thread cost, ~6.6 ms/frame est.** Root cause, found by
reading the code: `Entities::update()`
(`work/solarus/src/entities/Entities.cpp:1278`) calls
`entities_to_draw.clear()` **unconditionally every tick**, and
`Entities::draw()` (line 1309) only rebuilds when `entities_to_draw.empty()`
— so the "lazy build" is defeated every single frame regardless of whether
the camera or any entity actually moved. While standing still, the full
`get_entities_in_rectangle_z_sorted` query + sort + dedup
(`Entities.cpp:1309-1353`) reruns for nothing.

**Design:** replace the unconditional clear with a dirty flag, set only by
the mutations that can actually change the visible/sorted set:
- `Entities::notify_entity_bounding_box_changed` (any entity — including the
  camera, now that Task 4 makes it fire only on real moves — moved or
  resized).
- `Entities::add_entity` (a new drawable entity exists).
- `Entities::remove_marked_entities` (an entity is gone).
- `Entities::set_entity_layer` (an entity's draw layer changed — the list is
  `ByLayer`, so this changes which sub-list an entity belongs to).

Enable/disable does **not** need a hook: `Entities::draw()`'s per-entity loop
(`Entities.cpp:1507-1514`) already checks `is_enabled()`/`is_visible()` live
at draw time, and `Entity::set_enabled()` never touches the quadtree — so a
disabled entity stays in the cached list and is correctly skipped every
frame, same as today.

**Files:**
- Modify: `work/solarus/include/solarus/entities/Entities.h:265` (add the
  dirty-flag member)
- Modify: `work/solarus/src/entities/Entities.cpp:1278` (gate the clear)
- Modify: `work/solarus/src/entities/Entities.cpp:1309-1353` (reset the flag
  after a successful rebuild)
- Modify: `work/solarus/src/entities/Entities.cpp:968-1037` (`add_entity`)
- Modify: `work/solarus/src/entities/Entities.cpp:1131-1183`
  (`remove_marked_entities`)
- Modify: `work/solarus/src/entities/Entities.cpp:1528-1563`
  (`set_entity_layer`)
- Modify: `work/solarus/src/entities/Entities.cpp:1570-1578`
  (`notify_entity_bounding_box_changed`)
- Modify: `work/solarus/src/graphics/sdlrenderer/mister_blitter_renderer.cpp`
  (diag counters, for the HW A/B measurement)

**Interfaces:**
- Consumes: Task 4's fixed `TrackingState::update()` (camera only dirties on
  real movement).
- Produces: nothing consumed by later tasks (independent lever from 1a/1b).

- [ ] **Step 1: Add the dirty-flag member**

Edit `work/solarus/include/solarus/entities/Entities.h`, right after the
`entities_to_draw` declaration (former line 265):

```cpp
    ByLayer<EntitiesToDraw> entities_to_draw;       /**< For each layer, entities to be drawn at this cycle. */
    // [MiSTer #Phase1-1e, SOLARUS_DRAWCACHE] true when entities_to_draw must
    // be rebuilt: set by any mutation that can change the visible/sorted set
    // (entity add/remove/move/layer-change, camera move). Starts true so the
    // first frame always builds. Default-off flag: when off, update()
    // clears unconditionally every tick (today's stock behavior).
    bool entities_to_draw_dirty = true;
```

- [ ] **Step 2: Gate the clear in `update()`**

Edit `work/solarus/src/entities/Entities.cpp:1278`, replace:

```cpp
  entities_to_draw.clear();  // Invalidate entities to draw.
```

with:

```cpp
  // [SOLARUS_DRAWCACHE] Only clear (and thus force draw()'s lazy rebuild)
  // when something that can change the visible/sorted set actually happened
  // this tick. Default off: unconditional clear, identical to stock.
  static const bool _drawcache = (std::getenv("SOLARUS_DRAWCACHE") != nullptr);
  if (!_drawcache || entities_to_draw_dirty) {
    entities_to_draw.clear();
  }
```

Add `#include <cstdlib>` near the top of `Entities.cpp` if not already
present — it already is (line 20, `[SOLARUS_IDLEPARK] std::getenv`), so no
change needed here.

- [ ] **Step 3: Reset the flag after a rebuild**

Edit `work/solarus/src/entities/Entities.cpp`, at the end of the
`if (entities_to_draw.empty())` block in `draw()` (right after the closing
`}` of the `for (int layer ...)` sort/erase/unique loop, former line 1352):

```cpp
      std::sort(entities_to_draw[layer].begin(), entities_to_draw[layer].end(), DrawingOrderComparator());
      entities_to_draw[layer].erase(
            std::unique(entities_to_draw[layer].begin(), entities_to_draw[layer].end()),
            entities_to_draw[layer].end()
      );
    }

    entities_to_draw_dirty = false;  // [SOLARUS_DRAWCACHE] rebuild consumed.
  }
```

(The flag's value is harmless when `SOLARUS_DRAWCACHE` is off — it's only
read inside the Step 2 `_drawcache` branch.)

- [ ] **Step 4: Mark dirty on entity add**

Edit `work/solarus/src/entities/Entities.cpp` inside `add_entity`, right
after `quadtree->add(entity, entity->get_max_bounding_box());` (former line
982, inside the `if (type != EntityType::TILE)` block — tiles never go
through `entities_to_draw`, so they correctly don't need this):

```cpp
    // Update the quadtree.
    quadtree->add(entity, entity->get_max_bounding_box());
    entities_to_draw_dirty = true;  // [SOLARUS_DRAWCACHE]
```

- [ ] **Step 5: Mark dirty on entity removal**

Edit `work/solarus/src/entities/Entities.cpp`, at the top of
`remove_marked_entities()` (former line 1131), before the `for` loop:

```cpp
void Entities::remove_marked_entities() {

  if (!entities_to_remove.empty()) {
    entities_to_draw_dirty = true;  // [SOLARUS_DRAWCACHE]
  }

  // Remove the marked entities.
  for (const EntityPtr& entity: entities_to_remove) {
```

- [ ] **Step 6: Mark dirty on layer change**

Edit `work/solarus/src/entities/Entities.cpp` inside `set_entity_layer`,
right after the `if (layer != old_layer) {` opening brace (former line 1532):

```cpp
  if (layer != old_layer) {

    entities_to_draw_dirty = true;  // [SOLARUS_DRAWCACHE]

    const EntityPtr& shared_entity = std::static_pointer_cast<Entity>(entity.shared_from_this());
```

- [ ] **Step 7: Mark dirty on bounding-box change (covers all entity moves +
  the camera, per Task 4)**

Edit `work/solarus/src/entities/Entities.cpp` inside
`notify_entity_bounding_box_changed` (former lines 1570-1578):

```cpp
void Entities::notify_entity_bounding_box_changed(Entity& entity) {

  // Update the quadtree.

  // Note that if the entity is not in the quadtree
  // (i.e. not managed by MapEntities) this does nothing.
  EntityPtr shared_entity = std::static_pointer_cast<Entity>(entity.shared_from_this());
  quadtree->move(shared_entity, shared_entity->get_max_bounding_box());
  entities_to_draw_dirty = true;  // [SOLARUS_DRAWCACHE]
}
```

- [ ] **Step 8: Add HW measurement counters**

The existing diag-counter pattern
(`work/solarus/src/graphics/sdlrenderer/mister_blitter_renderer.cpp:27-36`,
`extern "C" { extern volatile long long g_me_draw_entities; ... }`) is how
Phase 0's banners are fed. Add two counters:

In `mister_blitter_renderer.cpp`, near the existing `g_me_draw_entities`
definition (former line 40):

```cpp
  volatile long long g_me_draw_entities   = 0;
  volatile long long g_me_drawcache_hit   = 0;  // [SOLARUS_DRAWCACHE]
  volatile long long g_me_drawcache_miss  = 0;  // [SOLARUS_DRAWCACHE]
```

In `Entities.cpp`, add to the `extern "C"` block near the top (former lines
27-36):

```cpp
  extern volatile long long  g_me_draw_entities;
  extern volatile long long  g_me_drawcache_hit;
  extern volatile long long  g_me_drawcache_miss;
```

Then in `draw()`, at the very top of the
`if (entities_to_draw.empty()) {` block (a miss — full rebuild happening) and
right before it in an `else` (a hit — reusing the cached list), increment the
matching counter when `g_mister_lua_diag` is set:

```cpp
  if (entities_to_draw.empty()) {
    if (g_mister_lua_diag) ++g_me_drawcache_miss;

    // Add entities in the camera,
    ...
```

and, right after the closing brace of that `if`:

```cpp
  }
  else if (g_mister_lua_diag) {
    ++g_me_drawcache_hit;
  }
```

Finally, print them in the existing per-60-frame banner block in
`mister_blitter_renderer.cpp` (find the `[blitter entsplit]` printf around
line 2404 and add a sibling banner right after it, following the same
`long long ... = g_me_...; g_me_... = 0;` snapshot-and-reset idiom used for
the other counters at lines 2291/2307):

```cpp
          long long dch = g_me_drawcache_hit, dcm = g_me_drawcache_miss;
          g_me_drawcache_hit = 0; g_me_drawcache_miss = 0;
          fprintf(stderr, "[blitter drawcache] /60fr hit=%lld miss=%lld\n", dch, dcm);
```

(Match the existing block's exact snapshot/print structure at the call site —
read the surrounding ~30 lines before inserting so indentation/braces line
up.)

- [ ] **Step 9: Commit inside work/solarus (includes Task 4's Camera.cpp
  change if not already committed separately), then export**

Commit-and-export MUST happen before the Docker build (see Global
Constraints).

```bash
cd work/solarus
git add include/solarus/entities/Entities.h src/entities/Entities.cpp \
        src/graphics/sdlrenderer/mister_blitter_renderer.cpp
git commit -m "perf(entities): cache entities_to_draw across frames, default off (SOLARUS_DRAWCACHE)"
cd ../..
scripts/export_patches.sh
```

- [ ] **Step 10: Docker build**

```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye \
  scripts/build_engine.sh
```

This build covers both Task 4's Camera.cpp commit and this task's
Entities.h/.cpp commit together — if it fails, check both diffs.

- [ ] **Step 11: Commit outer repo**

```bash
git add patches/series/
git commit -m "perf(entities): z-sorted-visible-list cache, lever 1e (#1 profile cost)"
```

- [ ] **Step 12: HW A/B**

Deploy, `SOLARUS_BLITTER_DIAG=1` + `SOLARUS_DRAWCACHE=0` in `diag.env`, drive
to the save spot, stand 60 s, capture 5 windows of
`[blitter drawcache|timing|hwperf|engcpp]`. Repeat with `SOLARUS_DRAWCACHE=1`.
**Expected while standing still:** `hit` should climb toward ~60/60 per
window (near-zero misses) once the camera settles, confirming Task 4 closed
the "dirties every tick" leak. Compare fps/A9-busy — this is the highest-value
lever in the whole plan (report estimate ~2.5–3.5 ms/frame), so also soak a
short walk (camera moving, entities animating) to confirm no visual
regression (sprite stacking/z-order, entities popping in/out at the camera
edge) before considering it for a future default-ON flip.

---

## Task 6: Lever 1a-a — static-entity idle predicate (TDD)

Report: ~230 of ~390 per-tick entity updates are walls (113), teletransporters
(73), destinations (46). None of these three types override `Entity::update()`
(`grep` confirms no `Wall::update`/`Teletransporter::update`/
`Destination::update` exist) — they run the base
`Entity::update()` (`work/solarus/src/entities/Entity.cpp:3719-3754`):
`update_sprites()` + `movement->update()` (if any) + `update_stream_action()`
+ `update_state()`. All four are genuinely no-ops when the entity has no
sprite that can advance/callback, no movement, no stream action, no attached
custom state, and isn't suspended. This mirrors
`work/solarus/src/entities/mister_idleskip.h`'s
`solarus_destructible_skippable` predicate, minus the three
`Destructible`-specific inputs (`being_cut`/`waiting_regen`/`regenerating`)
that don't apply to a generic `Entity`, **plus** one addition this
investigation found: `Entity::update_state()` calls `state->update()`
whenever a custom `Entity::State` is attached (used by e.g. `Camera`'s
`TrackingState` — the base `Entity` API exposes `set_state()` generically, so
it must be checked even though walls/teleporters/destinations don't use it in
practice).

**Files:**
- Create: `patches/mister/mister_staticpark.h`
- Test: `tests/staticpark_test.c`

**Interfaces:**
- Consumes: nothing.
- Produces: `solarus_staticpark_skippable(int suspended, int has_movement,
  int has_stream, int has_state, int sprite_may_change) -> int` (1 =
  skippable), consumed by Task 7.

- [ ] **Step 1: Write the header (predicate) with its doc comment**

Create `patches/mister/mister_staticpark.h`:

```c
/*
 * [perf] Static-entity update-skip predicate (SOLARUS_STATICPARK).
 *
 * Walls, teletransporters, and destinations (~230 of ~390 per-tick entity
 * updates in the heavy village room) never override Entity::update() -- they
 * run the base Entity::update() (update_sprites + movement->update() +
 * update_stream_action() + update_state()), which is a provable no-op when
 * the entity has no sprite that can advance a frame or fire a callback, no
 * movement, no active stream action, no custom state attached, and isn't
 * suspended. Reuses the same conservative-by-design contract as
 * mister_idleskip.h's destructible predicate, minus the 3 Destructible-only
 * inputs, plus has_state (base Entity exposes set_state() generically, e.g.
 * Camera's TrackingState, so it must be checked even though these 3 types
 * don't use it today).
 *
 * CONSERVATIVE BY DESIGN: return true (skip) ONLY when every path that could
 * do work this tick is inactive. Any doubt -> return false.
 *
 * Header-only, zero deps, C and C++ safe (see tests/staticpark_test.c).
 */
#ifndef MISTER_STATICPARK_H
#define MISTER_STATICPARK_H

#ifdef __cplusplus
extern "C" {
#endif

static inline int solarus_staticpark_skippable(
    int suspended, int has_movement, int has_stream, int has_state,
    int sprite_may_change) {
  return !suspended && !has_movement && !has_stream && !has_state
      && !sprite_may_change;
}

#ifdef __cplusplus
}  /* extern "C" */
#endif

#endif /* MISTER_STATICPARK_H */
```

- [ ] **Step 2: Write the failing test**

Create `tests/staticpark_test.c`:

```c
/* Host unit test for the static-entity update-skip predicate
 * (SOLARUS_STATICPARK). Locks the truth table: each veto condition alone
 * must forbid the skip.
 *
 * Build+run (from repo root):
 *   cc -Wall -Wextra -O2 -I patches/mister \
 *       tests/staticpark_test.c -o /tmp/staticpark_test && /tmp/staticpark_test
 */
#include "mister_staticpark.h"
#include <stdio.h>

static int failures = 0;
#define CHECK(cond, msg) do { \
    if (!(cond)) { printf("FAIL: %s (line %d)\n", msg, __LINE__); failures++; } \
} while (0)

/* Inputs, in order: suspended, has_movement, has_stream, has_state,
 * sprite_may_change */

static void test_idle_static_is_skippable(void) {
    CHECK(solarus_staticpark_skippable(0,0,0,0,0) == 1,
          "idle static entity must be skippable");
}

static void test_each_condition_vetoes_skip(void) {
    CHECK(solarus_staticpark_skippable(1,0,0,0,0) == 0,
          "suspended must not be skipped (normal suspend handling)");
    CHECK(solarus_staticpark_skippable(0,1,0,0,0) == 0,
          "has_movement must not be skipped (movement + collision-on-move)");
    CHECK(solarus_staticpark_skippable(0,0,1,0,0) == 0,
          "has_stream must not be skipped (stream action must run)");
    CHECK(solarus_staticpark_skippable(0,0,0,1,0) == 0,
          "has_state must not be skipped (custom state update() must run)");
    CHECK(solarus_staticpark_skippable(0,0,0,0,1) == 0,
          "sprite_may_change must not be skipped (animated/looping sprite)");
}

static void test_combined_vetoes(void) {
    CHECK(solarus_staticpark_skippable(1,0,0,0,1) == 0,
          "suspended + animating must not be skipped");
    CHECK(solarus_staticpark_skippable(0,1,0,1,0) == 0,
          "movement + state must not be skipped");
}

int main(void) {
    test_idle_static_is_skippable();
    test_each_condition_vetoes_skip();
    test_combined_vetoes();

    if (failures) { printf("staticpark: %d FAILED\n", failures); return 1; }
    printf("staticpark: all passed\n");
    return 0;
}
```

- [ ] **Step 3: Run it, confirm it passes (predicate is pure — no
  red/green cycle needed beyond running once, matching the existing
  idleskip_test.c precedent for this class of header-only predicate)**

```bash
cc -Wall -Wextra -O2 -I patches/mister tests/staticpark_test.c -o /tmp/staticpark_test
/tmp/staticpark_test
```

Expected: `staticpark: all passed`.

- [ ] **Step 4: Wire into the test runner and the whole-file copy script**

Edit `tests/run_tests.sh`, add after the existing `idlepark` block (former
line 68):

```bash
echo "== staticpark (perf: static-entity update-skip predicate) =="
$CC -Wall -Wextra -O2 -I patches/mister \
    tests/staticpark_test.c \
    -o /tmp/staticpark_test
/tmp/staticpark_test
```

Edit `scripts/apply_mister_files.sh`, add after the existing idle-park/skip
copy block (former last two lines):

```bash
# --- static-entity park header ---
cp patches/mister/mister_staticpark.h "$SRC/src/entities/"
```

- [ ] **Step 5: Run the full host test suite**

```bash
bash tests/run_tests.sh
```

Expected: `All host tests passed.` (includes the new `staticpark` block).

- [ ] **Step 6: Commit**

```bash
git add patches/mister/mister_staticpark.h tests/staticpark_test.c \
        tests/run_tests.sh scripts/apply_mister_files.sh
git commit -m "perf(entities): static-entity idle predicate (SOLARUS_STATICPARK), TDD'd"
```

---

## Task 7: Lever 1a-b — static-park integration in Entities

Wires Task 6's predicate into the update walk, mirroring the
`SOLARUS_IDLEPARK` mechanism exactly (`Entities.cpp:1223-1274`): a side-table
(not new fields on `Wall`/`Teletransporter`/`Destination`, which share no
common non-`Entity` base — a per-`Entities`-instance side-table avoids
touching three unrelated header files) tracks which eligible entities are
parked; parked entities are skipped by the main walk; an incremental sweep
(reusing `mister_idlepark.h`'s existing `solarus_idlepark_sweep_range`
unchanged) wakes any parked entity that a quest script made non-idle via Lua
(attached a movement/sprite/state) with no C++ chokepoint to hook — same
accepted-risk shape IDLEPARK already ships with for destructibles (see the
design spec's risk table: "Static-park wakes missed... mitigation: wake-hook
checklist + gameplay soak"). **Doors are out of scope** (not
Wall/Teletransporter/Destination) — they animate on open/close and were
explicitly excluded by the design spec.

**Files:**
- Modify: `work/solarus/include/solarus/entities/Entities.h` (side-table +
  park/wake methods, near the existing IDLEPARK section)
- Modify: `work/solarus/src/entities/Entities.cpp` (`add_entity`,
  `remove_marked_entities`, the update walk)

**Interfaces:**
- Consumes: `solarus_staticpark_skippable(...)` from Task 6
  (`patches/mister/mister_staticpark.h`, copied to
  `work/solarus/src/entities/mister_staticpark.h` by
  `scripts/apply_mister_files.sh`).
- Produces: nothing consumed by later tasks (independent lever from 1e/1b).

- [ ] **Step 1: Add the side-table and park/wake methods**

Edit `work/solarus/include/solarus/entities/Entities.h`, right after the
existing IDLEPARK block (former lines 247-255):

```cpp
    // [SOLARUS_IDLEPARK] parking machinery.
  public:
    void wake_destructible(Destructible* d);   /**< re-add a parked destructible to the walk. */
    void park_destructible(Destructible* d);   /**< drop an idle destructible from the walk. */
    bool idlepark_enabled = false;             /**< gate state, published by update(). */
  private:
    EntityList entities_to_update;             /**< all_entities minus parked destructibles. */
    std::vector<Destructible*> destructibles;  /**< cache for the incremental re-scan. */
    int idlepark_cursor = 0;                   /**< re-scan sweep position. */

    // [SOLARUS_STATICPARK] parking machinery for provably-idle
    // Wall/Teletransporter/Destination entities (see mister_staticpark.h).
    // A side-table (keyed by raw pointer) avoids widening Entity or adding
    // fields to three unrelated header files for a feature that applies to
    // only these three types. park_static() takes the caller's own walk
    // iterator (it's only ever called from the update walk, which already
    // holds it) so the park is O(1), same as Destructible's IDLEPARK.
  public:
    void wake_static(Entity* e);
    void park_static(Entity* e, EntityList::iterator it_in_walk);
  private:
    std::map<Entity*, EntityList::iterator> staticpark_it;
    std::vector<Entity*> staticpark_candidates;  /**< cache for the incremental re-scan. */
    int staticpark_cursor = 0;
```

- [ ] **Step 2: Implement `park_static`/`wake_static`**

Edit `work/solarus/src/entities/Entities.cpp`, right after the existing
`Entities::wake_destructible`/`park_destructible` definitions (former lines
961-966 area — find them and add these as siblings):

```cpp
void Entities::wake_static(Entity* e) {
  const auto& it = staticpark_it.find(e);
  if (it == staticpark_it.end()) return;  // Not parked.
  entities_to_update.insert(entities_to_update.end(),
      std::static_pointer_cast<Entity>(e->shared_from_this()));
  staticpark_it.erase(it);
}

void Entities::park_static(Entity* e, EntityList::iterator it_in_walk) {
  if (staticpark_it.count(e)) return;  // Already parked.
  // erase() returns the element AFTER the removed one; std::list iterators
  // to OTHER elements stay valid across it. park_static is only ever called
  // from the main update walk between its _it/_next capture (see Step 4),
  // same erase-mid-walk safety as IDLEPARK's park_destructible.
  staticpark_it[e] = entities_to_update.erase(it_in_walk);
}
```

- [ ] **Step 3: Register/unregister candidates in `add_entity` /
  `remove_marked_entities`**

Edit `work/solarus/src/entities/Entities.cpp` inside `add_entity`, right
after the existing IDLEPARK mirror block (former lines 1026-1036):

```cpp
    // [SOLARUS_IDLEPARK] mirror into the walk list; destructibles start active and
    // park on their first idle tick. Cache the list iterator for O(1) park/wake.
    if (type != EntityType::HERO) {
      auto _ip_it = entities_to_update.insert(entities_to_update.end(), entity);
      if (type == EntityType::DESTRUCTIBLE) {
        Destructible* _d = static_cast<Destructible*>(entity.get());
        _d->idlepark_it = _ip_it;
        _d->idlepark_parked = false;
        destructibles.push_back(_d);
      }
      // [SOLARUS_STATICPARK] Track wall/teletransporter/destination
      // candidates for the incremental wake sweep. Doors are excluded
      // (they animate on open/close, not provably idle).
      else if (type == EntityType::WALL ||
               type == EntityType::TELETRANSPORTER ||
               type == EntityType::DESTINATION) {
        staticpark_candidates.push_back(entity.get());
      }
    }
```

Edit `remove_marked_entities()`, right after the existing IDLEPARK mirror
block (former lines 1144-1152):

```cpp
    // [SOLARUS_IDLEPARK] mirror removal into the walk list + destructibles cache.
    if (type == EntityType::DESTRUCTIBLE) {
      Destructible* _d = static_cast<Destructible*>(entity.get());
      if (!_d->idlepark_parked) entities_to_update.erase(_d->idlepark_it);
      destructibles.erase(std::remove(destructibles.begin(), destructibles.end(), _d),
                          destructibles.end());
    } else if (type != EntityType::HERO) {
      // [SOLARUS_STATICPARK] a parked static entity is already out of
      // entities_to_update (erase would be a double-erase / UB); only erase
      // if it's still in the walk list.
      const auto& _sp_it = staticpark_it.find(entity.get());
      if (_sp_it == staticpark_it.end()) {
        entities_to_update.remove(entity);
      } else {
        staticpark_it.erase(_sp_it);
      }
      staticpark_candidates.erase(
          std::remove(staticpark_candidates.begin(), staticpark_candidates.end(), entity.get()),
          staticpark_candidates.end());
    }
```

- [ ] **Step 4: Classify + park in the main update walk, sweep to wake**

Edit `work/solarus/src/entities/Entities.cpp` in the update walk (former
lines 1230-1273). Add the flag read next to the existing `_idlepark` one, and
extend the per-entity loop body and the sweep:

```cpp
  static const char* _idlepark_env = std::getenv("SOLARUS_IDLEPARK");
  static const bool _idlepark = !(_idlepark_env && _idlepark_env[0] == '0');
  idlepark_enabled = _idlepark;
  // [SOLARUS_STATICPARK] default OFF (opt-in), same convention as
  // IDLESKIP/IDLEPARK started with.
  static const bool _staticpark = (std::getenv("SOLARUS_STATICPARK") != nullptr);
  EntityList& _walk = _idlepark ? entities_to_update : all_entities;
  for (EntityList::iterator _it = _walk.begin(); _it != _walk.end(); ) {
    EntityList::iterator _next = _it; ++_next;
    const EntityPtr entity = *_it;

    if (
        !entity->is_being_removed() &&
        entity->get_type() != EntityType::CAMERA  // The camera is updated after.
    ) {
      entity->update();
    }
    // ... (existing g_mister_lua_diag attribution block unchanged) ...

    // [IDLEPARK] Park a destructible that has returned to idle (erases *_it; _next held).
    if (_idlepark && entity->get_type() == EntityType::DESTRUCTIBLE) {
      Destructible* _d = static_cast<Destructible*>(entity.get());
      if (destructible_is_idle(_d)) park_destructible(_d);
    }
    // [SOLARUS_STATICPARK] Same erase-mid-walk shape: classify right after
    // this entity's update() ran, using the sprite/movement/stream/state it
    // has THIS tick.
    else if (_staticpark &&
             (entity->get_type() == EntityType::WALL ||
              entity->get_type() == EntityType::TELETRANSPORTER ||
              entity->get_type() == EntityType::DESTINATION)) {
      bool _spr = false;
      for (const SpritePtr& sp : entity->get_sprites()) {
        if (sp && !sp->is_paused() && !sp->is_animation_finished() && sp->get_frame_delay() > 0) {
          _spr = true;
          break;
        }
      }
      if (solarus_staticpark_skippable(
              entity->is_suspended() ? 1 : 0,
              (entity->get_movement() != nullptr) ? 1 : 0,
              entity->has_stream_action() ? 1 : 0,
              (entity->get_state() != nullptr) ? 1 : 0,
              _spr ? 1 : 0)) {
        park_static(entity.get(), _it);
      }
    }
    _it = _next;
  }
  // [IDLEPARK] Incremental backstop sweep (~n/30 per tick): wake any parked destructible
  // that is no longer idle (Lua-driven sprite/movement has no C++ wake hook).
  if (_idlepark && !destructibles.empty()) {
    int _ss, _cc, _nx;
    solarus_idlepark_sweep_range(idlepark_cursor, (int)destructibles.size(), 30,
                                 &_ss, &_cc, &_nx);
    for (int _k = 0; _k < _cc; ++_k) {
      Destructible* _d = destructibles[(_ss + _k) % (int)destructibles.size()];
      if (!destructible_is_idle(_d)) wake_destructible(_d);
    }
    idlepark_cursor = _nx;
  }
  // [SOLARUS_STATICPARK] Same incremental backstop, period 30, over the
  // candidate cache (both parked and active members -- active ones checked
  // here are a cheap no-op re-classification, matching the destructible
  // sweep's own shape).
  if (_staticpark && !staticpark_candidates.empty()) {
    int _ss, _cc, _nx;
    solarus_idlepark_sweep_range(staticpark_cursor, (int)staticpark_candidates.size(), 30,
                                 &_ss, &_cc, &_nx);
    for (int _k = 0; _k < _cc; ++_k) {
      Entity* _e = staticpark_candidates[(_ss + _k) % (int)staticpark_candidates.size()];
      if (staticpark_it.count(_e)) {
        bool _spr = false;
        for (const SpritePtr& sp : _e->get_sprites()) {
          if (sp && !sp->is_paused() && !sp->is_animation_finished() && sp->get_frame_delay() > 0) {
            _spr = true;
            break;
          }
        }
        if (!solarus_staticpark_skippable(
                _e->is_suspended() ? 1 : 0,
                (_e->get_movement() != nullptr) ? 1 : 0,
                _e->has_stream_action() ? 1 : 0,
                (_e->get_state() != nullptr) ? 1 : 0,
                _spr ? 1 : 0)) {
          wake_static(_e);
        }
      }
    }
    staticpark_cursor = _nx;
  }
```

Add `#include "mister_staticpark.h"` near the other MiSTer includes at the
top of `Entities.cpp` (next to the existing `#include "mister_idlepark.h"` /
`#include "mister_idleskip.h"`).

- [ ] **Step 5: Commit inside work/solarus, then export**

Commit-and-export MUST happen before the Docker build (see Global
Constraints). This also requires `patches/mister/mister_staticpark.h` (Task
6) to already be in place, since `apply_mister_files.sh` copies it into
`work/solarus/src/entities/` as part of the same apply cycle.

```bash
cd work/solarus
git add include/solarus/entities/Entities.h src/entities/Entities.cpp
git commit -m "perf(entities): static-entity park for wall/teletransporter/destination, default off (SOLARUS_STATICPARK)"
cd ../..
scripts/export_patches.sh
```

- [ ] **Step 6: Docker build**

```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye \
  scripts/build_engine.sh
```

- [ ] **Step 7: Commit outer repo**

```bash
git add patches/series/
git commit -m "perf(entities): static-entity park, lever 1a"
```

- [ ] **Step 8: HW A/B + wake-hook soak**

Deploy, `SOLARUS_STATICPARK=0` then `=1`, same measurement protocol. Because
this lever's correctness risk is explicitly named in the design spec's risk
table, soak beyond the standing-still fps check: walk through **every**
door/teleporter/destination interaction reachable near the save spot
(enter/exit a teleporter, arrive at a destination via a warp, walk into and
out of a wall's collision edge) with the flag ON, and confirm behavior is
identical to flag OFF. If a quest script dynamically attaches a movement to a
wall/teleporter/destination anywhere in the test quest (unlikely but
checkable via a` grep -r` over the quest's Lua scripts for
`:start_movement\(` calls on non-hero/enemy entities), specifically soak that
script.

---

## Task 8: Lever 1b — enemy ground-cell cache

Report: `Map::get_ground` (0.64 %) + `test_collision_with_ground`/`_obstacles`
(0.20 %) ≈ 0.7 ms/frame, confirmed by gprof as real cost from
`Entity::notify_position_changed()` →
`Entity::update_ground_below()` (`work/solarus/src/entities/Entity.cpp:1880`)
running on **every** movement step (not just when the ground actually
changes). `Map::get_ground`
(`work/solarus/src/core/Map.cpp:1131-1176`) itself does a spatial
(quadtree) query for nearby ground-modifying entities every call — so this is
additive to, not covered by, lever 1e's draw-list cache (different call site:
a 1×1-pixel ground-point query, not the camera-rect draw query).

**Design, found by reading the code (safer than the design spec's own
phrasing):** `update_ground_below()` is called from two distinct contexts —
(a) an entity's own movement (`notify_position_changed`, and similar direct
calls in `Hero.cpp`/`Pickable.cpp`/`Block.cpp`), and (b) a **reactive push**
from `update_ground_observers()`
(`work/solarus/src/entities/Entity.cpp:193-214`) when a **nearby
ground-modifying entity** changed (called from
`Entity::notify_position_changed` line 1878 and `Entity::notify_enabled` line
2618-2619). Only context (a) is cacheable by "same 8×8 cell as last time" —
context (b) means the ground at this entity's cell may have changed even
though this entity itself didn't move, so it must always force a real
recompute. Add a `force` parameter and thread it through: the reactive-push
call site passes `force=true` (bypassing the cache, always correct); the
"I moved myself" call sites use the default `force=false` (cache-eligible).

**Obstacle-test-funnel pruning is explicitly OUT of this task's scope.** The
design spec's own text for this half ("early-out on the cached traversability
of the current cell row/column") is the least-specified part of the whole
Phase 1 lever list, and the real code
(`work/solarus/src/movements/StraightMovement.cpp:400-560`) is a dense,
multi-branch diagonal-sliding collision-response algorithm — exactly the kind
of subtle physics code where a caching bug could cause silent, hard-to-spot
regressions (enemies clipping walls, getting stuck) that violate this
campaign's hard "no gameplay change" constraint. Its own measured value
(1.2–2.4 ms in the *original* banner estimate) is **already reconciled away**
by the Phase 0 report itself: "gprof puts most enemy 'integ' cost in the
quadtree reinsert + z-sort family... fix the retrieval/sort [lever 1e], not
the leaf." Shipping only the ground-cache half is the correct, safer scope
for this plan; a future dedicated investigation (its own design session, with
a collision-behavior HW soak protocol) is the right vehicle for the obstacle
funnel if 1e+ground-cache don't reach the Phase 1 fps gate alone.

**Files:**
- Modify: `work/solarus/include/solarus/entities/Entity.h:441` (signature +
  new private cache fields near `ground_below`, former line 485)
- Modify: `work/solarus/src/entities/Entity.cpp:193-214`
  (`update_ground_observers`, the reactive-push call site)
- Modify: `work/solarus/src/entities/Entity.cpp:237-264`
  (`update_ground_below` itself)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks (independent lever, last in this
  plan by design — smallest/most uncertain value per the handoff's own
  ranking).

- [ ] **Step 1: Add the `force` parameter and cache fields**

Edit `work/solarus/include/solarus/entities/Entity.h:441`, replace:

```cpp
    void update_ground_below();
```

with:

```cpp
    void update_ground_below(bool force = false);
```

Edit `work/solarus/include/solarus/entities/Entity.h`, right after
`ground_below`'s declaration (former line 485-486):

```cpp
    Ground ground_below;                        /**< Kind of ground under this entity: grass, shallow water, etc.
                                                 * Only used by entities sensible to their ground. */
    // [MiSTer #Phase1-1b, SOLARUS_GROUNDCACHE] Last 8x8 ground cell this
    // entity's update_ground_below() actually queried, and whether the cache
    // is populated yet. Only used to skip the "I moved myself but stayed in
    // the same cell" case -- the reactive push from a nearby ground modifier
    // (see update_ground_observers()) always passes force=true and bypasses
    // this, since the cell's ground can change without this entity moving.
    bool ground_cache_valid = false;
    int ground_cache_cell_x = 0;
    int ground_cache_cell_y = 0;
    int ground_cache_layer = -1;
```

- [ ] **Step 2: Force-recompute on the reactive-push path**

Edit `work/solarus/src/entities/Entity.cpp:211`, inside
`update_ground_observers()`, replace:

```cpp
      entity_nearby->update_ground_below();
```

with:

```cpp
      entity_nearby->update_ground_below(/*force=*/true);
```

- [ ] **Step 3: Implement the cache in `update_ground_below`**

Edit `work/solarus/src/entities/Entity.cpp:237-264`, replace:

```cpp
void Entity::update_ground_below() {

  if (!is_ground_observer()) {
    // This entity does not care about the ground below it.
    return;
  }

  if (!is_enabled() ||
      is_being_removed()) {
    return;
  }

  // Note that even if the entity is suspended,
  // the user might want to know the ground below it.

  if (map->test_collision_with_border(get_ground_point())) {
    // If the entity is outside the map, which is legal during a scrolling
    // transition, don't try to determine any ground.
    return;
  }

  Ground previous_ground = this->ground_below;
  this->ground_below = get_map().get_ground(
      get_layer(), get_ground_point(), this
  );
  if (this->ground_below != previous_ground) {
    notify_ground_below_changed();
  }
}
```

with:

```cpp
void Entity::update_ground_below(bool force) {

  if (!is_ground_observer()) {
    // This entity does not care about the ground below it.
    return;
  }

  if (!is_enabled() ||
      is_being_removed()) {
    return;
  }

  // Note that even if the entity is suspended,
  // the user might want to know the ground below it.

  const Point gp = get_ground_point();
  if (map->test_collision_with_border(gp)) {
    // If the entity is outside the map, which is legal during a scrolling
    // transition, don't try to determine any ground.
    return;
  }

  // [SOLARUS_GROUNDCACHE] Skip the query when this entity's own ground-point
  // is still inside the same 8x8 cell as last time it was queried. Only
  // valid for the "I moved myself" callers (force=false): a reactive push
  // from a nearby ground modifier always passes force=true, since the
  // cell's ground can change without this entity moving.
  static const bool _groundcache = (std::getenv("SOLARUS_GROUNDCACHE") != nullptr);
  const int cell_x = gp.x / 8;
  const int cell_y = gp.y / 8;
  const int layer = get_layer();
  if (_groundcache && !force && ground_cache_valid &&
      cell_x == ground_cache_cell_x && cell_y == ground_cache_cell_y &&
      layer == ground_cache_layer) {
    return;  // ground_below is already correct for this cell.
  }

  Ground previous_ground = this->ground_below;
  this->ground_below = get_map().get_ground(layer, gp, this);
  if (_groundcache) {
    ground_cache_cell_x = cell_x;
    ground_cache_cell_y = cell_y;
    ground_cache_layer = layer;
    ground_cache_valid = true;
  }
  if (this->ground_below != previous_ground) {
    notify_ground_below_changed();
  }
}
```

Add `#include <cstdlib>` near the top of `Entity.cpp` (confirmed absent —
needed for `std::getenv`).

- [ ] **Step 4: Commit inside work/solarus, then export**

Commit-and-export MUST happen before the Docker build (see Global
Constraints).

```bash
cd work/solarus
git add include/solarus/entities/Entity.h src/entities/Entity.cpp
git commit -m "perf(entities): ground-cell cache in update_ground_below, default off (SOLARUS_GROUNDCACHE)"
cd ../..
scripts/export_patches.sh
```

- [ ] **Step 5: Docker build**

```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye \
  scripts/build_engine.sh
```

- [ ] **Step 6: Commit outer repo**

```bash
git add patches/series/
git commit -m "perf(entities): enemy ground-cell cache, lever 1b (obstacle-prune half descoped)"
```

- [ ] **Step 7: HW A/B**

Deploy, `SOLARUS_GROUNDCACHE=0` then `=1`, same protocol. Soak: walk an enemy
or the hero across a ground-type boundary (grass → water, or onto/off a
dynamic tile/Block that modifies ground) with the flag ON and confirm the
ground-dependent behavior (splash, sinking, hole-fall, whatever the test
quest has) still triggers exactly on the boundary, not a cell late. This is
the correctness-sensitive check for this lever.

---

## Task 9: Equivalence gate + full patch-series regeneration

One consolidated pass confirming the whole Phase 1 series applies cleanly
from pristine upstream and the patch-series migration's own regression gate
still holds.

**Files:**
- None new — verification only.

**Interfaces:**
- Consumes: all of Tasks 1-8's exported patches.
- Produces: a clean `patches/series/` ready for Task 10's HW soak.

- [ ] **Step 1: Full reapply from pristine**

```bash
bash scripts/apply_patch_series.sh
```

Expected: `[apply] OK` — the whole series (all 17 pre-existing patches +
the new ones from Tasks 2/3/4-5/7/8) applies via `git am --3way` with no
conflicts, `apply_mister_files.sh` copies `mister_staticpark.h` correctly,
and `verify_patches.sh`'s ast-grep gate passes.

- [ ] **Step 2: Equivalence regression gate (informational — expected to
  report a diff, see below)**

```bash
bash scripts/tests/test_equivalence.sh
```

**Corrected expectation, discovered running this plan:** this gate compares
against `scripts/legacy/build_engine_patchphase.sh`, a snapshot FROZEN at the
patch-series migration (PR #71) and never updated since. It hard-codes that
only `src/entities/Entities.cpp` may ever differ from that frozen baseline —
so it already "fails" (reports `Main.cpp` as an unexpected diff) as of Phase
0's SIGTERM patch, which predates this entire plan. It is a one-time
migration-acceptance test, not a durable ongoing regression gate; do not
block on it. The durable structural check for the patch series is
`verify_patches.sh`'s ast-grep gate (run as part of Step 1, above — that one
must actually pass). If this step reports differing files, confirm they're
exactly the files this plan's tasks (or any prior post-migration patch, like
Phase 0's `Main.cpp` SIGTERM patch) intentionally touched, then move on.

Original (superseded) expected-pass text, for context: "confirms the
patch-series-built tree still matches the frozen legacy inline-patcher's
output for anything the series doesn't intentionally
change — catches an accidental behavior drift in an unrelated area).

- [ ] **Step 3: Full Docker build from the reapplied tree**

```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye \
  scripts/build_engine.sh
```

- [ ] **Step 4: Host test suite**

```bash
bash tests/run_tests.sh
```

Expected: `All host tests passed.`

- [ ] **Step 5: Refresh the deploy artifact**

```bash
cp build/armhf/solarus-run deploy/
cp build/armhf/libsolarus.so.1.6.5 deploy/
strings deploy/libsolarus.so.1.6.5 | grep -c SOLARUS_DRAWCACHE
```

Expected: non-zero (confirms the new flag string is actually linked into the
binary you're about to deploy — memory `fpga-deploy-refresh-from-build-armhf`
flags a stale-`deploy/` class of bug this catches).

---

## Task 10: Combined HW soak + Phase 1 gate decision

All five levers OFF by default; this task turns them on **together** (not
just pairwise) for the first time and checks the Phase 1 gate from the design
spec: *"banners show per_step ≤ 4.0 ms with no behavior deltas; fps ≥ 33."*

**Files:**
- None — HW-only task. Optionally: append results to
  `docs/superpowers/2026-07-07-gprof-attribution.md` or a new dated doc.

**Interfaces:**
- Consumes: Tasks 1-9.
- Produces: the bake-to-default-ON decision for each flag (a **follow-up**
  commit per flag, once its individual HW A/B and this combined soak both
  pass — not part of this plan; flip flags in a small dedicated PR per the
  IDLEPARK precedent, one flag or a reviewed bundle at a time).

- [ ] **Step 1: Deploy and enable all five flags together**

`diag.env`:
```
SOLARUS_LUACONSOLE=1
SOLARUS_HASFIELDCACHE=1
SOLARUS_DRAWCACHE=1
SOLARUS_STATICPARK=1
SOLARUS_GROUNDCACHE=1
SOLARUS_BLITTER_DIAG=1
```

- [ ] **Step 2: Standing-still measurement**

Drive to the village save spot, stand ≥ 60 s, capture 5 consecutive 60-frame
windows of `[blitter timing|hwperf|engcpp|entsplit|drawcache]`. Record
per-step ms, fps, A9-busy ms/frame, `entsplit` cost breakdown, `drawcache`
hit rate.

- [ ] **Step 3: Compare against the Phase 0 baseline**

| Metric | Baseline (2026-07-07) | Target | Measured |
|---|---|---|---|
| per_step | ~5.2 ms | ≤ 4.0 ms (stretch 3.5) | — |
| fps | 25.5–27 | ≥ 33 | — |
| A9 busy | 30–33.5 ms/frame | — | — |

- [ ] **Step 4: Walk-through soak (all 5 flags on)**

Walk from the save spot through the surrounding rooms for ≥ 5 minutes,
covering: a dialogue, an item use, at least one door/teleporter/destination
transition, at least one ground-type boundary crossing, and normal
enemy/combat interaction. Confirm zero visual/behavioral deltas versus all
flags off (same route).

- [ ] **Step 5: Record the gate result**

If the gate passes: this plan is complete: Phase 1 per-step target met,
proceed to the design spec's Phase 2 (emit/present, already descoped toward
pacing-wait-only per Phase 0) or Phase 3 (fabric). If the gate misses:
re-profile with LD_PROFILE (Phase 0's method) at the new baseline to see
which lever under-delivered or what new cost rose to the top, and scope a
Phase 1.5 task from there — do not guess further levers without new profile
data (the whole point of Phase 0 was replacing guesswork).

---

## Self-Review

**Spec coverage:** all 5 levers from the handoff (1e, 1d, 1a, 1b, 1f) have a
task. F2 (assertions) is folded into 1f per the design spec's own bundling
("Near-free companion: build with NDEBUG"), reinterpreted correctly after
finding `NDEBUG` doesn't gate the hot call sites (Task 2's own investigation
step). The design spec's Phase 1 gate (per_step ≤ 4.0 ms, fps ≥ 33) is Task
10. The obstacle-test-funnel half of 1b is explicitly and reasonedly
descoped (Task 8's design section) rather than silently dropped.

**Placeholder scan:** no TBD/TODO/"add error handling"-style steps; every
code-touching step shows the actual diff.

**Type consistency:** `Entities::park_static(Entity*, EntityList::iterator)`
used consistently between its Task 7 Step 1 declaration and Step 2/4
implementations. `Entity::update_ground_below(bool force = false)` consistent
across Task 8's header/impl. `solarus_staticpark_skippable(int,int,int,int,int)`
5-arg order consistent between Task 6's header/test and Task 7's call sites.
`userdata_has_field_cache` type (`std::map<const ExportableToLua*,
std::map<std::string,bool>>`) consistent between Task 3's header member and
all three `.cpp` call sites.
