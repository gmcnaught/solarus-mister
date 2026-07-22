# Stage 5 A9 — per-drawable draw-walk reduction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `[blitter drawsplit]` attribution probe that splits the `engine_traversal`
draw-walk cost into `build` / `luahook` / `builtin` / `loop_residual`, HW-capture map 3, decide the
lever from the data (anti-bias gate), then land the gate-selected engine lever (Lever A fully
specified; B/C/D re-plan on selection).

**Architecture:** Diagnostics are delta-counter globals defined in the whole-file renderer
(`patches/mister/mister_blitter_renderer.cpp`, edited directly) and read/incremented from the
Solarus draw path via a NEW git-am series patch (`patches/series/0041-*.patch`) touching
`Entities.cpp` + `Entity.cpp`. Everything is diag-gated (`g_mister_lua_diag`) and zero-cost when
off. Levers are env-flag-gated until HW-validated default-on. Engine-only — **no RBF**.

**Tech Stack:** C++17 (Solarus engine + MiSTer renderer), armhf cross-build in
`solarus-armhf-build:bullseye` Docker via `scripts/build_engine.sh`, git-am patch series, host C
test suite (`tests/run_tests.sh`), on-device HW validation over SSH (192.168.20.81).

## Global Constraints

- **Engine-only, no RBF.** All work is A9/host. If any candidate needs RTL, it is out of scope.
- **Target scene = map 3 town** (A9-bound, save1, teleport `out_link_house`). map 119 is the
  fabric-bound control (`from_dungeon_10`) — this arc will not raise its fps.
- **Diagnostics ship diag-gated** (`g_mister_lua_diag`), **zero-cost when off**; **levers ship
  env-flag-gated** until HW-validated default-on.
- **Gate rule (ship-blocking):** every drawsplit primary sub-bracket ≥ 0 and secondary
  `geom_est ≥ 0` on every window; a negative means mis-scoped instrumentation — fix, do not ship.
- **Correctness bar for any lever:** bit-exact blit-emission order vs current (host model test) +
  operator visual gate (Z-fighting / missing-sprite / dynamic-hook). **Never self-declare visual
  correctness** (`solarus-no-self-declared-visual-validation`).
- **Anti-bias:** commit the probe brackets BEFORE any lever code; select the lever FROM the capture.
- **Patch mechanics:** engine-file edits (`Entities.cpp`, `Entity.cpp`, `LuaContext.*`) become a
  numbered `patches/series/NNNN-*.patch`; the renderer (`patches/mister/mister_blitter_renderer.cpp`)
  and any new `patches/mister/*.h` are whole-file copies edited directly (NOT in the series).
- **Native type-check recipe (renderer edits):** `g++ -fsyntax-only -std=c++17
  -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO -I patches/mister -I patches/mister/blitter
  -I work/solarus/include -I build/armhf/include
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags)
  patches/mister/mister_blitter_renderer.cpp` — **both `-D` flags mandatory** (else it type-checks
  almost nothing and falsely passes).

---

## File Structure

- `patches/mister/mister_blitter_renderer.cpp` (MODIFY, whole-file copy) — 3 new `extern "C"`
  globals `g_draw_build_ns` / `g_draw_luahook_ns` / `g_draw_builtin_ns`; 3 new per-frame `prev`
  snapshot fields; the `[blitter drawsplit]` print appended after the existing `[blitter walksplit]`
  print.
- `patches/series/0041-chore-mister-drawsplit-attribution-probe.patch` (CREATE via `git format-patch`)
  — the `extern` declarations + `ScopedNs`-style brackets in `Entities.cpp` (`build`) and
  `Entity.cpp` (`luahook`, `builtin`).
- `docs/superpowers/data/stage5-a9/drawsplit-map3.txt` (CREATE) — raw HW capture, Task 2.
- `docs/superpowers/2026-07-22-stage5-a9-drawsplit-decision.md` (CREATE) — the gate/decision, Task 2.
- **Lever A only (Task 3, contingent):**
  - `patches/mister/mister_drawhook_cache.h` (CREATE, whole-file) — the pure cache/invalidation
    model, host-testable.
  - `tests/drawhook_cache_test.c` (CREATE) + wired into `tests/run_tests.sh` (MODIFY).
  - `patches/series/0042-perf-lua-cache-entity-draw-hook-probe.patch` (CREATE) — wire the model into
    `LuaContext::userdata_has_field` / the draw-hook call sites behind `SOLARUS_DRAWHOOKCACHE`.
  - `docs/superpowers/2026-07-22-stage5-a9-drawhookcache-hw-validation.md` (CREATE).

---

## Task 1: `[blitter drawsplit]` attribution probe

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` (globals ~L70–79; `prev` fields ~L928;
  print ~L3758, inside the existing emitsplit/walksplit block)
- Create (via `git format-patch`): `patches/series/0041-chore-mister-drawsplit-attribution-probe.patch`
  from edits to `work/solarus/src/entities/Entities.cpp` and `work/solarus/src/entities/Entity.cpp`

**Interfaces:**
- Produces: `extern "C" volatile long long g_draw_build_ns, g_draw_luahook_ns, g_draw_builtin_ns;`
  (defined in the renderer, referenced from the engine patch). Per-frame `/60fr` banner line
  `[blitter drawsplit] ... = build + luahook + builtin | geom_est=.. loop_residual=..`.
- Consumes: existing `g_mister_lua_diag`, `_me_now_ns()` (Entities.cpp), `_me_now_ns_ent()`
  (Entity.cpp), and the existing banner locals `emit_ms`, `blit_ms`, `push_ms`, `remit_ms`,
  `ovl_ms`, `engtrav_ms`.

- [ ] **Step 1: Define the 3 new renderer globals.** In `patches/mister/mister_blitter_renderer.cpp`,
  in the `extern "C" { … }` block alongside `g_sprite_push_ns` (~L77), add:

```cpp
  // [drawsplit] wall-ns attribution of the Solarus draw-walk (diag-gated, delta-counter):
  // build = Entities::draw entities_to_draw build+z-sort block (DRAWCACHE-miss only);
  // luahook = entity_on_pre_draw + entity_on_post_draw probe/callback, summed per entity;
  // builtin = built_in_draw (per-entity sprite geometry + our dispatch + blit/push).
  volatile long long g_draw_build_ns    = 0;
  volatile long long g_draw_luahook_ns  = 0;
  volatile long long g_draw_builtin_ns  = 0;
```

- [ ] **Step 2: Add the 3 per-frame snapshot fields.** Find the walksplit snapshot line (~L928:
  `long long t_sprite_push_prev = 0, t_resident_emit_prev = 0, t_overlay_prev = 0;`) and add
  after it:

```cpp
  long long t_draw_build_prev = 0, t_draw_luahook_prev = 0, t_draw_builtin_prev = 0; // [drawsplit]
```

- [ ] **Step 3: Append the drawsplit print.** Immediately after the existing `[blitter walksplit]`
  `std::fprintf(...)` (ends ~L3758), inside the same `{ … }` block (so `emit_ms`, `blit_ms`,
  `push_ms`, `remit_ms`, `ovl_ms`, `engtrav_ms`, `N` are all in scope), add:

```cpp
          // [drawsplit] split engine_traversal into the Solarus draw-walk components.
          // Primary (nesting-safe, each a direct ScopedNs region): build / luahook / builtin.
          // loop_residual = emit - remit - ovl - build - luahook - builtin (draw-loop overhead
          // + visibility checks + FPS-overlay emit + diag tax). Secondary: geom_est = builtin
          // - blit - push (Sprite::draw geometry + dispatch, net of the pixel blit). All MUST be
          // >= 0 -- a negative means a bracket is mis-scoped; fix, don't interpret.
          long long db = g_draw_build_ns, dl = g_draw_luahook_ns, di = g_draw_builtin_ns;
          double build_ms   = (db - d->t_draw_build_prev)   / N / 1e6;
          double luahook_ms = (dl - d->t_draw_luahook_prev) / N / 1e6;
          double builtin_ms = (di - d->t_draw_builtin_prev) / N / 1e6;
          d->t_draw_build_prev = db; d->t_draw_luahook_prev = dl; d->t_draw_builtin_prev = di;
          double geom_est_ms = builtin_ms - blit_ms - push_ms;
          double loop_res_ms = emit_ms - remit_ms - ovl_ms - build_ms - luahook_ms - builtin_ms;
          std::fprintf(stderr,
            "[blitter drawsplit] /60fr: build=%.2f luahook=%.2f builtin=%.2f | "
            "geom_est=%.2f loop_residual=%.2f | xcheck(engtrav=%.2f vs "
            "b+l+g+lr=%.2f)\n",
            build_ms, luahook_ms, builtin_ms, geom_est_ms, loop_res_ms,
            engtrav_ms, build_ms + luahook_ms + geom_est_ms + loop_res_ms);
```

  Note: `remit_ms`/`ovl_ms` are the walksplit locals (`remit_ms` = `resident_emit`, `ovl_ms` =
  `overlay`); confirm the exact local names in the block and match them (they are named `remit_ms`
  and `ovl_ms` in the current source).

- [ ] **Step 4: Apply the series to the working tree** so the engine files can be edited and
  re-exported to a patch.

Run: `SOLARUS_PATCH_ONLY=1 bash scripts/build_engine.sh`
Expected: `[patch-series] SOLARUS_PATCH_ONLY=1 — patched tree ready in work/solarus, skipping build.`
(If Docker `git am` is flaky, apply on host — see `solarus-docker-git-am-flaky-host-patch-workaround`.)

- [ ] **Step 5: Add the `build` bracket in `Entities::draw`.** In `work/solarus/src/entities/Entities.cpp`:
  (a) extend the `extern "C" { … }` diag block (~L28) with:

```cpp
  extern volatile long long  g_draw_build_ns;   // [drawsplit]
```

  (b) wrap the lazy-build block in `Entities::draw()` (the `if (entities_to_draw.empty()) { … }` at
  ~L1469–1514). Add a timer around the whole `if`/`else` so a hit records ~0 and a miss records the
  cull+sort:

```cpp
  // [drawsplit] time the entities_to_draw build+z-sort (runs only on a DRAWCACHE miss).
  long long _ds_t0 = g_mister_lua_diag ? _me_now_ns() : 0;
  // Lazily build the list of entities to draw.
  if (entities_to_draw.empty()) {
    ...existing build body unchanged...
  }
  else if (g_mister_lua_diag) {
    ++g_me_drawcache_hit;
  }
  if (g_mister_lua_diag) g_draw_build_ns += _me_now_ns() - _ds_t0;
```

- [ ] **Step 6: Add the `luahook` + `builtin` brackets in `Entity::draw`.** In
  `work/solarus/src/entities/Entity.cpp`: (a) extend the `extern "C" { … }` block (~L22) with:

```cpp
  extern volatile long long g_draw_luahook_ns;   // [drawsplit]
  extern volatile long long g_draw_builtin_ns;   // [drawsplit]
```

  (b) rewrite the body of `Entity::draw(Camera& camera)` (~L3877) to time the two hook calls and
  the built-in draw separately, preserving exact call order and semantics:

```cpp
void Entity::draw(Camera& camera) {

  if (!is_visible()) {
    return;
  }
  if (get_state() != nullptr && !get_state()->is_visible()) {
    return;
  }

  const bool _ds = g_mister_lua_diag;
  long long _t = _ds ? _me_now_ns_ent() : 0;
  get_lua_context()->entity_on_pre_draw(*this, camera);
  if (_ds) { long long _n = _me_now_ns_ent(); g_draw_luahook_ns += _n - _t; _t = _n; }

  if (draw_override.is_empty()) {
    built_in_draw(camera);
  }
  else {
    get_lua_context()->do_entity_draw_override_function(draw_override, *this, camera);
  }
  if (_ds) { long long _n = _me_now_ns_ent(); g_draw_builtin_ns += _n - _t; _t = _n; }

  get_lua_context()->entity_on_post_draw(*this, camera);
  if (_ds) g_draw_luahook_ns += _me_now_ns_ent() - _t;
}
```

  (Note: `builtin` here brackets both `built_in_draw` and the Lua `draw_override` branch — both are
  "the entity's draw content", the intended meaning; the hook probes are `luahook`.)

- [ ] **Step 7: Export the engine edits as series patch 0041.** From the repo root:

```bash
cd work/solarus
git add src/entities/Entities.cpp src/entities/Entity.cpp
git commit -m "chore(mister): [drawsplit] attribution brackets in Entities/Entity::draw"
git format-patch -1 --start-number=41 -o "$OLDPWD/patches/series/"
cd "$OLDPWD"
git -C work/solarus reset --soft HEAD~1   # leave edits staged so a rebuild re-applies cleanly
ls patches/series/0041-*.patch
```

Expected: `patches/series/0041-chore-mister-drawsplit-attribution-brackets-in-Enti.patch` exists.
Rename to `0041-chore-mister-drawsplit-attribution-probe.patch` if a shorter name is preferred.

- [ ] **Step 8: Native type-check the renderer edit.**

Run the Global-Constraints `g++ -fsyntax-only` recipe.
Expected: no errors (exit 0). If it prints errors, fix them (do NOT trust a bare success without
both `-D` flags).

- [ ] **Step 9: Full armhf build (proves the patch series applies + engine links).**

Run: `bash scripts/build_engine.sh`
Expected: builds `build/armhf/solarus-run` + `libsolarus.so.1.6.5`; the `git am` of 41 patches
succeeds (0041 applies clean).

- [ ] **Step 10: Host suite still green (no regression to modelled logic).**

Run: `bash tests/run_tests.sh`
Expected: all existing tests PASS (this task adds no host test — it is pure instrumentation;
correctness is the ≥0 gate verified on HW in Task 2).

- [ ] **Step 11: Commit.**

```bash
git add patches/mister/mister_blitter_renderer.cpp patches/series/0041-*.patch
git commit -m "measure(stage5-a9): [blitter drawsplit] — split engine_traversal into build/luahook/builtin"
```

---

## Task 2: HW capture + decision gate (anti-bias)

**Files:**
- Create: `docs/superpowers/data/stage5-a9/drawsplit-map3.txt`
- Create: `docs/superpowers/2026-07-22-stage5-a9-drawsplit-decision.md`

**Interfaces:**
- Consumes: the `[blitter drawsplit]` + `[blitter walksplit]` banner lines from Task 1.
- Produces: a committed decision naming the dominant sub-bracket and selecting Task 3's lever
  (`luahook`→A, `builtin`/`geom_est`→B, `build`→C, `builtin`/dispatch→D, diffuse→stop).

- [ ] **Step 1: Deploy the Task-1 engine to the device (no RBF).**

Run: `./deploy.py --no-rbf --host 192.168.20.81`
Expected: `solarus-run` + `libsolarus.so.1.6.5` refreshed on device; sha1 verified by deploy.py.
(Refresh `deploy/` from `build/armhf` first if deploy.py ships from `deploy/` — see
`fpga-deploy-refresh-from-build-armhf`.)

- [ ] **Step 2: Launch map 3 with diag on, detached, logging to persistent storage.**

SSH-launch the engine with `g_mister_lua_diag` enabled (the diag env the renderer reads to set
`g_mister_lua_diag`), teleporting to map 3 `out_link_house` from save1, per the walksplit capture
recipe in `docs/superpowers/data/stage5-a9/walksplit-map3.txt`. Use the detached recipe
(`setsid sh solarus_run.sh >/media/fat/logs/drawsplit.log 2>&1 </dev/null &`) so it survives SSH
disconnect (`solarus-ssh-launch-dies-on-disconnect`); log to `/media/fat/logs`, not `/tmp`.

- [ ] **Step 3: Capture ≥3 standing + ≥3 moving windows.** Standing = idle on map 3; moving = hold
  DOWN (inject via `devmem 0x3A000008` dpad bits, `solarus-joypad-inject-hw`). Collect the
  `[blitter drawsplit]`, `[blitter walksplit]`, `[blitter a9split]`, `[blitter timing]`, and
  `[blitter hwperf]` lines for each window into `docs/superpowers/data/stage5-a9/drawsplit-map3.txt`.

- [ ] **Step 4: Verify the gate on every window.** For each captured window confirm:
  - `build_ms ≥ 0`, `luahook_ms ≥ 0`, `builtin_ms ≥ 0`, `loop_residual_ms ≥ 0`, `geom_est_ms ≥ 0`.
  - `xcheck`: `build+luahook+geom_est+loop_residual` ≈ `engtrav` (walksplit's `engine_traversal`)
    within rounding.
  If any is negative or the xcheck diverges materially, the instrumentation is mis-scoped —
  return to Task 1, fix, redeploy, recapture. Do NOT interpret a failing capture.

- [ ] **Step 5: Write the decision doc.** In
  `docs/superpowers/2026-07-22-stage5-a9-drawsplit-decision.md`, record the median-of-windows split
  (standing + moving), name the dominant sub-bracket, and select the lever per this map:

  | Dominant bracket | Selected lever | Action |
  |---|---|---|
  | `luahook` (expected) | **Lever A** — draw-hook probe elimination | proceed to Task 3 |
  | `builtin` with large `geom_est` | **Lever B** — Sprite::draw geometry memoization | STOP; re-invoke writing-plans for Lever B |
  | `builtin` with small `geom_est` | **Lever D** — dispatch-glue trim | STOP; re-invoke writing-plans for Lever D |
  | `build` non-trivial | **Lever C** — DRAWCACHE over-invalidation fix | STOP; re-invoke writing-plans for Lever C |
  | diffuse / all small | **STOP** — no single lever worth it; re-baseline | close the arc |

  State explicitly whether the `luahook` leading suspect is CONFIRMED or REFUTED (anti-bias — the
  direction is read from the data, exactly as the predecessor refuted `sprite_push`).

- [ ] **Step 6: Commit the gate BEFORE any lever code.**

```bash
git add docs/superpowers/data/stage5-a9/drawsplit-map3.txt \
        docs/superpowers/2026-07-22-stage5-a9-drawsplit-decision.md
git commit -m "decide(stage5-a9): drawsplit lever = <selected> (data-selected, anti-bias gate)"
```

---

## Task 3: Lever A — draw-hook probe elimination  *(CONTINGENT: execute ONLY if Task 2 selects `luahook`)*

> If Task 2 selected B / C / D / STOP instead, do NOT execute this task. Re-invoke
> `superpowers:writing-plans` with the drawsplit decision to plan that lever. This task is the
> fully-specified path for the expected (`luahook`) outcome.

**Goal:** Eliminate the per-entity-per-frame `userdata_has_metafield` probe for
`on_pre_draw`/`on_post_draw` in the common "no draw override" case, behind `SOLARUS_DRAWHOOKCACHE`,
without changing emission order and with correct invalidation when a hook is added at runtime.

**Files:**
- Create: `patches/mister/mister_drawhook_cache.h` (whole-file, host-testable pure model)
- Create: `tests/drawhook_cache_test.c`; Modify: `tests/run_tests.sh`
- Create (via `git format-patch`): `patches/series/0042-perf-lua-cache-entity-draw-hook-probe.patch`
  from edits to `work/solarus/src/lua/EntityApi.cpp` (+ `LuaContext.cpp`/`LuaContext.h` if needed)
- Create: `docs/superpowers/2026-07-22-stage5-a9-drawhookcache-hw-validation.md`

**Interfaces:**
- Consumes: `LuaContext::entity_on_pre_draw`/`entity_on_post_draw` (`lua/EntityApi.cpp:6721/6741`),
  `userdata_has_field`/`userdata_has_metafield` (`lua/LuaContext.cpp`), `ExportableToLua::
  get_lua_type_name()`, `is_with_lua_table()`.
- Produces: a per-entity-type cache of "does this type's metatable define `on_pre_draw`/`on_post_draw`",
  consulted before the metatable probe; env flag `SOLARUS_DRAWHOOKCACHE` (opt-in until HW-validated).

- [ ] **Step 1: Write the failing host model test.** The project pattern is a pure decision function
  in a header (cf. `mister_staticpark.h` / `staticpark_test.c`). Create `tests/drawhook_cache_test.c`
  that exercises a cache model with these semantics: (1) first query for a `(type, key)` is a MISS
  and records the probed result; (2) a repeat query is a HIT returning the same result with no
  re-probe; (3) an invalidation of `type` (metatable mutated) forces the next query to MISS and
  re-probe; (4) distinct keys (`on_pre_draw` vs `on_post_draw`) are independent.

```c
#include <assert.h>
#include <string.h>
#include "mister_drawhook_cache.h"

/* A test double for the underlying probe: returns a value we control and counts calls. */
static int g_probe_calls;
static int g_probe_ret;
static int fake_probe(const char* type, const char* key) {
  (void)type; (void)key; g_probe_calls++; return g_probe_ret;
}

int main(void) {
  dhc_cache c; dhc_init(&c, fake_probe);

  /* (1) MISS records; (2) HIT no re-probe */
  g_probe_calls = 0; g_probe_ret = 0;
  assert(dhc_has_field(&c, "npc", "on_pre_draw") == 0);
  assert(g_probe_calls == 1);
  assert(dhc_has_field(&c, "npc", "on_pre_draw") == 0);
  assert(g_probe_calls == 1);                 /* cached, no second probe */

  /* (4) distinct keys independent */
  g_probe_ret = 1;
  assert(dhc_has_field(&c, "npc", "on_post_draw") == 1);
  assert(g_probe_calls == 2);

  /* (3) invalidation forces re-probe with the NEW value */
  g_probe_ret = 1;
  dhc_invalidate_type(&c, "npc");
  assert(dhc_has_field(&c, "npc", "on_pre_draw") == 1);   /* re-probed, sees new true */
  assert(g_probe_calls == 3);

  printf("drawhook_cache: OK\n");
  return 0;
}
```

- [ ] **Step 2: Run it to confirm it fails (header missing).**

Run: `cc -Wall -Wextra -O2 -I patches/mister tests/drawhook_cache_test.c -o /tmp/dhc_test && /tmp/dhc_test`
Expected: FAIL — `mister_drawhook_cache.h: No such file or directory`.

- [ ] **Step 3: Implement the pure model header.** Create `patches/mister/mister_drawhook_cache.h`
  with a small `(type-name,key) -> bool` cache and a per-type invalidation. Keep it dependency-free
  (host-testable); the engine patch supplies the real probe fn + real type/key strings.

```c
#ifndef MISTER_DRAWHOOK_CACHE_H
#define MISTER_DRAWHOOK_CACHE_H
#include <stdio.h>
#include <string.h>
/* Pure model of the entity draw-hook metafield cache (Lever A). Keyed by Lua type
 * name + field key; a type-level invalidation (metatable mutated at runtime) drops
 * that type's entries so the next query re-probes. Bounded, no allocation: the set
 * of (entity-type, {on_pre_draw,on_post_draw}) pairs is tiny (<=~40). */
#define DHC_MAX 128
typedef int (*dhc_probe_fn)(const char* type, const char* key);
typedef struct {
  char type[32]; char key[24]; int result; int valid;
} dhc_entry;
typedef struct { dhc_entry e[DHC_MAX]; int n; dhc_probe_fn probe; } dhc_cache;

static inline void dhc_init(dhc_cache* c, dhc_probe_fn p) { c->n = 0; c->probe = p; }

static inline int dhc_has_field(dhc_cache* c, const char* type, const char* key) {
  for (int i = 0; i < c->n; i++)
    if (c->e[i].valid && !strcmp(c->e[i].type, type) && !strcmp(c->e[i].key, key))
      return c->e[i].result;
  int r = c->probe(type, key);
  /* reuse an invalidated slot if present, else append (bounded; if full, just return r) */
  int slot = -1;
  for (int i = 0; i < c->n; i++) if (!c->e[i].valid) { slot = i; break; }
  if (slot < 0 && c->n < DHC_MAX) slot = c->n++;
  if (slot >= 0) {
    snprintf(c->e[slot].type, sizeof c->e[slot].type, "%s", type);
    snprintf(c->e[slot].key, sizeof c->e[slot].key, "%s", key);
    c->e[slot].result = r; c->e[slot].valid = 1;
  }
  return r;
}

static inline void dhc_invalidate_type(dhc_cache* c, const char* type) {
  for (int i = 0; i < c->n; i++)
    if (c->e[i].valid && !strcmp(c->e[i].type, type)) c->e[i].valid = 0;
}
static inline void dhc_invalidate_all(dhc_cache* c) {
  for (int i = 0; i < c->n; i++) c->e[i].valid = 0;
}
#endif
```

- [ ] **Step 4: Run the host test to green.**

Run: `cc -Wall -Wextra -O2 -I patches/mister tests/drawhook_cache_test.c -o /tmp/dhc_test && /tmp/dhc_test`
Expected: `drawhook_cache: OK`.

- [ ] **Step 5: Wire the test into the suite.** In `tests/run_tests.sh`, add a block mirroring the
  existing per-test pattern:

```bash
echo "== drawhook_cache (Lever A: entity draw-hook probe cache + invalidation) =="
$CC -Wall -Wextra -O2 -I patches/mister \
    tests/drawhook_cache_test.c \
    -o /tmp/drawhook_cache_test
/tmp/drawhook_cache_test
```

Run: `bash tests/run_tests.sh`  →  Expected: the new block prints `drawhook_cache: OK`, all PASS.

- [ ] **Step 6: Commit the model + test.**

```bash
git add patches/mister/mister_drawhook_cache.h tests/drawhook_cache_test.c tests/run_tests.sh
git commit -m "feat(stage5-a9): draw-hook probe cache model + host test (Lever A)"
```

- [ ] **Step 7: Apply the series to the working tree** (so the engine files can be edited):

Run: `SOLARUS_PATCH_ONLY=1 bash scripts/build_engine.sh`  →  Expected: patched tree ready.

- [ ] **Step 8: Wire the cache into the draw-hook call sites, flag-gated.** In
  `work/solarus/src/lua/EntityApi.cpp`, gate `entity_on_pre_draw`/`entity_on_post_draw` so the
  `userdata_has_field` metatable probe is served from a `LuaContext`-owned `dhc_cache` when
  `SOLARUS_DRAWHOOKCACHE` is set. The cache is consulted ONLY for the type-metatable result; the
  per-instance `is_with_lua_table()` membership check (already cheap) stays live so an
  instance-level field is never missed:

```cpp
void LuaContext::entity_on_pre_draw(Entity& entity, Camera& camera) {
  if (!entity_draw_hook_present(entity, "on_pre_draw")) {
    return;
  }
  run_on_main([this, &entity, &camera](lua_State* l){
    push_entity(l, entity);
    on_pre_draw(camera);
    lua_pop(l, 1);
  });
}
```

  where the new helper (added to `LuaContext`) is:

```cpp
// [SOLARUS_DRAWHOOKCACHE, Lever A] Cache the TYPE-metatable probe for the two draw
// hooks (types are registered once; effectively immutable at gameplay time), so the
// common no-override entity skips the ~4-op Lua metafield probe every frame. The
// per-instance lua-table field can still add the hook dynamically -> checked live.
bool LuaContext::entity_draw_hook_present(const ExportableToLua& u, const char* key) {
  static const bool on = (std::getenv("SOLARUS_DRAWHOOKCACHE") != nullptr);
  if (!on) {
    return userdata_has_field(u, key);            // stock path, bit-identical
  }
  // Instance-level table field can appear/disappear at runtime -> never cached.
  if (u.is_with_lua_table()) {
    const auto& it = userdata_fields.find(&u);
    if (it != userdata_fields.end() && it->second.find(key) != it->second.end())
      return true;
  }
  // Type-metatable result IS cached, keyed by type name.
  return draw_hook_type_cache_lookup(u.get_lua_type_name().c_str(), key);
}
```

  Implement `draw_hook_type_cache_lookup` over a `dhc_cache` member whose `probe` fn calls
  `userdata_has_metafield`. Add the `dhc_cache draw_hook_cache;` member + init in `LuaContext.h`/
  ctor and `#include "mister_drawhook_cache.h"`.

- [ ] **Step 9: Invalidate on runtime metatable mutation (correctness-critical).** Find where a
  script can write an entity type's metatable (the `sol.main.get_metatable()` write path / the
  metatable `__newindex`, and the registration in `register_entity_module`). On any such write, call
  `draw_hook_cache.dhc_invalidate_all()` (coarse but correct — metatable writes are rare and
  gameplay-cold). If a precise per-type site is not cleanly reachable, invalidate-all is the
  conservative correct choice. Document the exact site chosen in the patch commit message.

- [ ] **Step 10: Export the engine edits as series patch 0042.**

```bash
cd work/solarus
git add src/lua/EntityApi.cpp src/lua/LuaContext.cpp include/solarus/lua/LuaContext.h
git commit -m "perf(lua): cache entity draw-hook metafield probe behind SOLARUS_DRAWHOOKCACHE (Lever A)"
git format-patch -1 --start-number=42 -o "$OLDPWD/patches/series/"
cd "$OLDPWD"; git -C work/solarus reset --soft HEAD~1
ls patches/series/0042-*.patch
```

- [ ] **Step 11: Native type-check the renderer (unchanged file, sanity) + full armhf build.**

Run: `bash scripts/build_engine.sh`
Expected: 42 patches apply clean; engine links.

- [ ] **Step 12: Host suite green.**

Run: `bash tests/run_tests.sh`  →  Expected: all PASS incl `drawhook_cache: OK`.

- [ ] **Step 13: A/B correctness + perf on HW.** Deploy (`./deploy.py --no-rbf`). Capture map 3
  standing + moving with `SOLARUS_DRAWHOOKCACHE` **unset** (A) and **set** (B):
  - **Perf:** `[blitter drawsplit] luahook` must drop materially in B; `[blitter walksplit]` /
    `[blitter a9split]` A9 total down; fps up (upper bound per spec).
  - **Correctness (operator visual gate):** side-by-side A vs B on map 3 — no missing sprites, no
    Z-fighting, HUD/entities identical. Then a **dynamic-hook test**: run a quest snippet that adds
    `on_pre_draw` to an entity at runtime and confirm it fires with the flag ON (invalidation works).
    Never self-declare — operator confirms.
  Record all of it in `docs/superpowers/2026-07-22-stage5-a9-drawhookcache-hw-validation.md`.

- [ ] **Step 14: If validated, flip default-on (matching prior lever rollout).** Change the flag
  sense to default-ON with `SOLARUS_DRAWHOOKCACHE=0` opt-out ONLY after the HW gate + a soak, in a
  separate commit (same discipline as IDLEPARK/DRAWCACHE). Update CLAUDE.md's rendering-architecture
  note with the new channel + its default + the HW-validation doc reference.

- [ ] **Step 15: Commit + re-measure for the next lever.**

```bash
git add patches/series/0042-*.patch docs/superpowers/2026-07-22-stage5-a9-drawhookcache-hw-validation.md
git commit -m "feat(stage5-a9): draw-hook probe cache HW-validated (Lever A)"
```

  Then re-run the Task-2 capture with Lever A on: if a second sub-bracket now dominates and is worth
  it, return to `superpowers:writing-plans` for the next lever behind a fresh decision gate
  (one-lever discipline, measure between). Stop when the residual is diffuse, fps target met, or the
  scene flips FABRIC-bound.

---

## Self-Review

**Spec coverage:**
- Spec §1 (drawsplit probe, 6 brackets, primary/secondary split, gate rule, cross-check) → Task 1
  (Steps 1–3 print incl. `geom_est`/`loop_residual`/xcheck) + Task 2 Step 4 (gate) ✓
- Spec §1 "Decision gate" (anti-bias, HW capture, decision doc) → Task 2 ✓
- Spec §2 Lever A (type-metatable cache, instance-table live check, invalidation, flag,
  correctness bar) → Task 3 ✓
- Spec §2 Levers B/C/D → Task 2 Step 5 selection table + Task 3 contingency banner (each re-plans;
  deliberate scope boundary, not a placeholder — matches the spec's fresh-gate-per-landing loop) ✓
- Spec §3 (successive-lever loop, validation stack, stop condition) → Task 3 Steps 13–15 ✓
- Spec §3 scope guardrails → Global Constraints ✓

**Placeholder scan:** no TBD/TODO; every code step shows code; every command shows expected output.
The B/C/D "re-plan" is an explicit measure-first boundary, not a deferred detail.

**Type consistency:** `g_draw_build_ns`/`g_draw_luahook_ns`/`g_draw_builtin_ns` defined in Task 1
Step 1, `extern`-declared in Steps 5–6, read in Step 3; `t_draw_*_prev` defined Step 2, used Step 3.
`dhc_cache`/`dhc_init`/`dhc_has_field`/`dhc_invalidate_type`/`dhc_invalidate_all` consistent across
Task 3 Steps 1/3/8. `entity_draw_hook_present`/`draw_hook_type_cache_lookup` consistent Steps 8–9.

**Gaps:** none blocking. The one implementer decision left open by design is Task 3 Step 9's exact
invalidation site (documented default = `dhc_invalidate_all`), which depends on the live
`sol.main.get_metatable` write path — correctly resolved at implementation with the conservative
default already specified.
