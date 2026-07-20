# Stage 3b Phase A — bgplane bake deletion (host-only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete the host-side bgplane background-plane bake (~700 lines plus 5 entangled excisions), so #122/#127 are closed by removal rather than suppressed by a default-OFF flag.

**Architecture:** Pure deletion, outside-in. Remove *callers* first (so the tree keeps compiling at every step), then state, then definitions. The bake's only load-bearing seam is `resident_emit_static_layer()`, which already contains a complete non-plane fallback — collapsing to that fallback is the entire behavioural change. No RTL, so no Quartus build and no new RBF; the existing fabric arm for `OP_BGPLANE_WRITE` simply goes un-issued.

**Tech Stack:** C++17 renderer (`patches/mister/mister_blitter_renderer.cpp`, a whole-file copy — NOT in the patch series), C blitter emitter (`patches/mister/blitter/`), armhf cross-build in Docker, bash test harnesses.

## Global Constraints

- **`patches/mister/mister_blitter_renderer.{cpp,h}` and everything under `patches/mister/blitter/` are whole-file copies, not patch-series entries.** Edit them DIRECTLY. Never run `export_patches.sh` for them.
- **Changes under `patches/series/` DO require** `scripts/export_patches.sh` and must round-trip. Pin `diff.algorithm=myers` — a user-global `patience` setting breaks the round-trip gate.
- **Build only inside the container:** `scripts/docker_run.sh bash scripts/build_engine.sh`. A host build leaves a host-path `CMakeCache.txt` that blocks the container build afterward.
- **Grep `BUILD_EXIT` to determine build success.** The task exit code is not trustworthy; a trailing `grep` can yield a misleading exit 0.
- **Never run a bare `git stash pop`** in this repo — it targets an unrelated months-old WIP stash. Three long-lived stashes exist.
- **The syntax-check recipe MUST include `-DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO`.** `scripts/build_engine.sh:134-135` sets both unconditionally, and virtually the entire renderer implementation lives inside `#ifdef MISTER_NATIVE_VIDEO`. **The recipe printed in `CLAUDE.md` omits them and therefore compiles almost nothing while reporting success** — it will report `SYNTAX OK` on a file with 20 hard errors. Always use the flagged form given in each task's type-check step.
- **Every task must leave the tree compiling.** This plan deletes callers before definitions for exactly that reason. Never delete a header or definition while a live reference to it remains.
- **`SOLARUS_BGPLANE` is already default-OFF.** The correct end-state behaviour of Phase A is **identical to today's build**. Any visible change is a regression, not an improvement.
- **Do not self-declare visual correctness.** The HW gate requires the operator's eyes.
- Expected end state: `grep -ri bgplane patches/mister/ tests/ | wc -l` returns only the deliberately-reserved wire-ABI constants named in Task 8.

---

### Task 1: Delete the bgplane host tests

Removing tests first means later tasks that delete emitter symbols cannot break a test that is itself scheduled for deletion.

**The three `bgplane_*.h` headers are NOT deleted here.** They are still `#include`d by `mister_blitter_renderer.cpp:30-32`, and the renderer still calls their types and functions at ~15 sites. Deleting the headers before those call sites are gone (Tasks 2–6) breaks the build. Headers and includes leave together in **Task 6**.

**Files:**
- Delete: `tests/bgplane_geom_test.cpp`, `tests/bgplane_bounds_test.cpp`, `tests/bgplane_sync_batch_test.c`, `tests/bgplane_sync_bake_test.c`, `tests/blt_bgplane_write_test.c`
- Modify: `tests/run_tests.sh:126-158` (five stanzas)
- **Do NOT touch:** `patches/mister/blitter/bgplane_*.h`, or any file under `patches/mister/` at all.

**Interfaces:**
- Consumes: nothing.
- Produces: a tree with no host tests referencing bgplane, so Tasks 5–7 can delete `blt_bgplane_write_cell` and the bake bodies without a test failing.

- [ ] **Step 1: Confirm the CI gate does not reference bgplane**

Run:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
grep -c bgplane patches/mister/build_host_tests.sh || echo "0 — CI gate is clean"
```
Expected: `0 — CI gate is clean`. `build_host_tests.sh` is the CI entry point and lists its 8 tests explicitly; none are bgplane. Only `tests/run_tests.sh` (referenced by no workflow) carries them.

- [ ] **Step 2: Delete the five test files**

```bash
git rm tests/bgplane_geom_test.cpp tests/bgplane_bounds_test.cpp \
       tests/bgplane_sync_batch_test.c tests/bgplane_sync_bake_test.c \
       tests/blt_bgplane_write_test.c
```

The three `bgplane_*.h` headers stay for now — see this task's preamble.

- [ ] **Step 3: Remove the five stanzas from `tests/run_tests.sh`**

Delete lines 126–158 inclusive — the five `echo "== bgplane_… =="` blocks and their compile+run commands. Verify the surrounding stanzas are untouched:

```bash
sed -n '120,130p' tests/run_tests.sh
```
Expected: the stanza before line 126 flows directly into the stanza that followed line 158, with no orphaned `g++`/`gcc` continuation lines or dangling `-o /tmp/...` fragments.

- [ ] **Step 4: Verify no test still references bgplane**

```bash
grep -rn "bgplane" tests/ || echo "TESTS CLEAN"
```
Expected: `TESTS CLEAN`. Hits under `patches/` are expected at this stage and are removed by Tasks 2–7 — do not act on them here.

- [ ] **Step 5: Confirm the renderer still compiles (nothing under patches/ was touched)**

```bash
g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
  -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp && echo "SYNTAX OK"
```
Expected: `SYNTAX OK`. If this fails, you edited something under `patches/` that this task forbids — revert it.

- [ ] **Step 6: Run the CI host-test gate to confirm it is unaffected**

```bash
bash patches/mister/build_host_tests.sh
```
Expected: ends with `== all host tests passed ==`.

- [ ] **Step 7: Commit**

```bash
git add -A tests/
git commit -m "test: remove bgplane host tests (Stage 3b Phase A)"
```

---

### Task 2: Collapse `resident_emit_static_layer()` to its bucket-replay fallback

This is the **only behavioural change in Phase A**. Everything else is dead-code removal.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp:4119` (function body, ~220 lines → 5)

**Interfaces:**
- Consumes: `res_emit_static_bucket_(size_t)` and `d->res_static_ops` — both survive Phase A untouched.
- Produces: `resident_emit_static_layer(int layer)` with unchanged signature (still an override declared at `mister_blitter_renderer.h:87`, still called from `Entities.cpp`), now unconditionally replaying static buckets. Phase B replaces this body with the grid op.

- [ ] **Step 1: Record the pre-change behaviour you must preserve**

Read the existing fallback at `:4126-4133`. It is already exactly the target behaviour, reached whenever `!bgplane_enabled` — which is the default today. Confirm:

```bash
sed -n '4119,4135p' patches/mister/mister_blitter_renderer.cpp
```
Expected: you see `if (!d->bgplane_enabled || it == d->bg_planes.end() || !it->second.valid) {` guarding a `for` loop over `res_static_ops` that calls `res_emit_static_bucket_`.

- [ ] **Step 2: Confirm the plane path's scroll-bias logic is duplicated, not unique**

The plane path computes a Stage-3a scroll bias at `:4293`. Verify the surviving bucket path computes the identical thing, so deleting the plane copy loses nothing:

```bash
grep -n "scroll_bias_x\|scroll_bias_y" patches/mister/mister_blitter_renderer.cpp
```
Expected: hits at `:790-791` (the definitions), `:4026` (`res_emit_bucket_`), `:4054` (`res_emit_static_bucket_`), `:4293` (the plane path being deleted). Because `:4054` is inside the surviving fallback's callee, the `:4293` copy is redundant. **If `:4054` is absent, STOP** — the bias is unique to the plane path and this deletion would regress Stage 3a scroll transitions.

- [ ] **Step 3: Replace the entire function body**

Replace `mister_blitter_renderer.cpp:4119` through the function's closing brace with exactly:

```cpp
void MisterBlitterRenderer::resident_emit_static_layer(int layer) {
  d->flush_sprites_before_other_op();   // keep buffered sprites UNDER this op
  // [Stage 3b] Static tiles replay per-bucket. The camera/parallax bias and the
  // Stage-3a scroll bias both live in res_emit_static_bucket_. Phase B replaces
  // this body with the tilemap grid op at this same seam.
  for (size_t i = 0; i < d->res_static_ops.size(); ++i)
    if (d->res_static_ops[i].layer == layer)
      res_emit_static_bucket_(d->res_static_ops[i].bk);
}
```

- [ ] **Step 4: Type-check the renderer natively**

```bash
g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
  -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp && echo "SYNTAX OK"
```
Expected: `SYNTAX OK`. Unused-variable warnings about plane locals are expected at this stage and resolve in later tasks.

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "refactor(render): collapse resident_emit_static_layer to bucket replay

The plane COPY path is deleted with the bake. Its Stage-3a scroll bias is
duplicated in res_emit_static_bucket_ (:4054), so nothing is lost."
```

---

### Task 3: Excise the bgplane block from `res_arm_()`

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp:3747` (`res_arm_`), removing the inner `if (d->bgplane_enabled) { … }` block

**Interfaces:**
- Consumes: nothing new.
- Produces: `res_arm_()` with unchanged signature and unchanged resident behaviour.

- [ ] **Step 1: Locate the block's exact bounds**

```bash
awk 'NR>=3747 && NR<=4000 && /bgplane_enabled|res_armed = true/ {print NR": "$0}' \
  patches/mister/mister_blitter_renderer.cpp
```
Expected: an `if (d->bgplane_enabled)` opening around `:3810` and `d->res_armed = true;` around `:3993`. The block to delete is everything between them — it allocates from `sdram_bgplane`, populates `bg_planes`, and runs ARM diag asserts.

- [ ] **Step 2: Verify the block only READS resident state**

```bash
awk 'NR>=3810 && NR<=3992' patches/mister/mister_blitter_renderer.cpp | \
  grep -n "res_static_buckets\|res_static_ops\|res_buckets\|res_ops" | head -20
```
Expected: only reads (subscripting, `.size()`, range-for). **If you find an assignment, `push_back`, `clear`, or `resize` on any `res_*` container, STOP** — the block mutates resident state and deletion would change the surviving path.

- [ ] **Step 3: Delete the block and its stale rationale comments**

Delete from the `// sdram_bgplane pool. [#24] …` comment lead-in (around `:3815`) through the closing brace of the `if (d->bgplane_enabled)` block, leaving `d->res_armed = true;` intact. Also delete the now-stale bgplane rationale comment immediately preceding the block.

- [ ] **Step 4: Confirm `res_arm_` still ends correctly**

```bash
grep -n "res_armed = true" patches/mister/mister_blitter_renderer.cpp
```
Expected: exactly one hit, still inside `res_arm_`.

- [ ] **Step 5: Type-check**

```bash
g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
  -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp && echo "SYNTAX OK"
```
Expected: `SYNTAX OK`.

- [ ] **Step 6: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "refactor(render): drop the bgplane arena/alloc block from res_arm_"
```

---

### Task 4: Remove the remaining bgplane hooks from surviving functions

Four small excisions from live code paths, including one in the hot `fill()` path that currently rewrites colours.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` — `resident_begin_frame()` (~`:3050-3123`), `fill()` (~`:2760-2780`), `Impl` per-frame reset (`:1326`), `present()` (`:4358-4359`)

**Interfaces:**
- Consumes: nothing new.
- Produces: `resident_begin_frame(map_id, tileset_id, min_layer)` — signature **unchanged**, `min_layer` parameter **retained** (Phase B needs it; only the `(void)min_layer;` discard is removed).

- [ ] **Step 1: Remove the per-frame bake driver from `resident_begin_frame`**

Delete the bake dispatch at `:3079` (`if (d->bgplane_sync) bake_all_planes_sync();` and its surrounding `bake_background_plane_step()` branch) together with the ~45-line snapshot-safety comment block above it (~`:3050-3077`), which describes only bake ordering.

- [ ] **Step 2: Remove the plane-invalidation loop**

Delete the `for (auto& kv : d->bg_planes) { …valid = false; …baking = false; }` loop in the rebuild branch (~`:3121-3123`) and its 12-line rationale comment (~`:3110-3120`).

- [ ] **Step 3: Keep `min_layer`, drop only the discard**

Find `(void)min_layer;` (~`:3086`) and delete that line plus its bgplane-referencing comment. **Do not change the function signature** and do not touch `Renderer.h`. Confirm:

```bash
grep -n "min_layer" patches/mister/mister_blitter_renderer.cpp patches/mister/mister_blitter_renderer.h
```
Expected: `min_layer` still present as a parameter in both the declaration and definition; no `(void)min_layer;` remains.

- [ ] **Step 4: Remove the two `fill()` diag hooks**

Delete both `if (is_map_bg_fill && d->bgplane_diag …)` and `if (is_map_bg_fill && d->bgplane_solid …)` blocks (~`:2760-2780`). The second **rewrites the fill colour to magenta** — confirm no colour mutation survives:

```bash
grep -n "magenta\|0xF81F\|bgplane_solid" patches/mister/mister_blitter_renderer.cpp
```
Expected: no hits inside `fill()`.

- [ ] **Step 5: Remove the per-frame reset line and the probe dispatch**

Delete `:1326` (`for (auto& kv : bg_planes) kv.second.copied_this_frame = false;`) and the `present()` early-return at `:4358-4359` (`if (d->bgw_probe) { d->run_bgw_probe(); return; }`) with its comment.

- [ ] **Step 6: Type-check**

```bash
g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
  -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp && echo "SYNTAX OK"
```
Expected: `SYNTAX OK`.

- [ ] **Step 7: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "refactor(render): remove bgplane hooks from begin_frame, fill, present

Keeps resident_begin_frame's min_layer parameter (Phase B needs it) and
removes the SOLARUS_BGPLANE_SOLID colour rewrite from the hot fill path."
```

---

### Task 5: Delete the bake function bodies

With every caller gone, the definitions can go.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` — delete `bake_background_plane_step()` (`:3185`, ~349 lines), `bake_all_planes_sync()` (`:3545`, ~67), `bgplane_gradient_rgb565()` (`:3165`), `bgplane_gradient_debug_color()` (`:3178`), `run_bgw_probe()` (`:1410`, ~55)
- Modify: `patches/mister/mister_blitter_renderer.h` — remove the matching member declarations

**Interfaces:**
- Consumes: nothing.
- Produces: nothing (pure removal).

- [ ] **Step 1: Confirm all five are callerless**

```bash
for f in bake_background_plane_step bake_all_planes_sync \
         bgplane_gradient_rgb565 bgplane_gradient_debug_color run_bgw_probe; do
  printf "%-32s %s\n" "$f" "$(grep -c "$f" patches/mister/mister_blitter_renderer.cpp)"
done
```
Expected: each count reflects only its own definition line plus comments — **no call sites**. `bgplane_gradient_debug_color` legitimately calls `bgplane_gradient_rgb565`, so the latter may show 2. If any other count exceeds its definition, a caller survived from Tasks 2–4; go back and remove it.

- [ ] **Step 2: Delete the five function bodies from the .cpp**

Delete each function from its signature line through its closing brace. Work bottom-up by line number (`:3545`, then `:3185`, then `:3178`, `:3165`, then `:1410`) so earlier deletions don't shift later line numbers.

- [ ] **Step 3: Remove the declarations from the header**

```bash
grep -n "bake_background_plane_step\|bake_all_planes_sync\|run_bgw_probe" \
  patches/mister/mister_blitter_renderer.h
```
Delete each line found.

- [ ] **Step 4: Type-check**

```bash
g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
  -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp && echo "SYNTAX OK"
```
Expected: `SYNTAX OK`.

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp patches/mister/mister_blitter_renderer.h
git commit -m "refactor(render): delete the bake bodies (step, sync, gradients, bgw probe)"
```

---

### Task 6: Delete bgplane state, flags, env reads, and the SDRAM arena

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` — `:410-415` (arena constants + `static_assert`s), `:659-689` (`struct BgPlane`, `bg_planes`, `bgplane_enabled`, `bgplane_sync`), `:710-758` (diag flags), `:1707-1715` (arena banner), `:2520-2551` (env reads), `:2635` (`blt_alloc_init`), `:30-32` (includes)
- Modify: `patches/mister/blitter/blt_emitter.h` — remove `blt_alloc_t sdram_bgplane;` (`:67`)

**Interfaces:**
- Consumes: nothing.
- Produces: `blt_emitter_t` without the `sdram_bgplane` member. `sdram_perm` and `sdram_alloc` are untouched.

- [ ] **Step 1: Delete the six env-flag reads**

Remove the reads for `SOLARUS_BGW_PROBE`, `SOLARUS_BGPLANE_DIAG`, `SOLARUS_BGPLANE_SOLID`, `SOLARUS_BGPLANE_COPYDBG`, `SOLARUS_BGPLANE`, and `SOLARUS_BGPLANE_SYNC` (~`:2520-2551`).

- [ ] **Step 2: Delete the arena init and constants**

Remove `blt_alloc_init(&self->d->em.sdram_bgplane, SDRAM_BGPLANE_BASE, SDRAM_BGPLANE_SIZE);` at `:2635`, then `SDRAM_BGPLANE_BASE` / `SDRAM_BGPLANE_SIZE` and both `static_assert`s at `:410-415`, then the arena headroom banner at `:1707-1715`.

**Do not disturb the neighbouring `blt_sdram_regions_init` calls** for `sdram_perm` / `sdram_alloc` — the bgplane init sits in the middle of that sequence.

- [ ] **Step 3: Delete the state and flags**

Remove `struct BgPlane { … };`, `std::unordered_map<int, BgPlane> bg_planes;`, `bgplane_enabled`, `bgplane_sync` (`:659-689`), and the four diag flags `bgw_probe`, `bgplane_diag`, `bgplane_solid`, `bgplane_copydbg` (`:710-758`) with their comment blocks.

- [ ] **Step 4: Remove the emitter member, the three includes, and the three headers**

In `patches/mister/blitter/blt_emitter.h`, delete `blt_alloc_t sdram_bgplane;` (`:67`).

Then delete the three `#include "blitter/bgplane_*.h"` lines at renderer `:30-32` **and** the headers themselves, in the same commit — by this point Tasks 2–5 have removed every call site, so nothing references their types any more:

```bash
git rm patches/mister/blitter/bgplane_geom.h \
       patches/mister/blitter/bgplane_bounds.h \
       patches/mister/blitter/bgplane_sync.h
```

**Ordering matters:** the includes and headers must go together. Removing headers earlier breaks the build (the renderer still used their types); removing includes while headers remain leaves dead files. Step 6's syntax check is what proves the call sites are genuinely all gone.

- [ ] **Step 5: Verify the renderer is bgplane-free**

```bash
grep -in "bgplane\|bg_plane\|bgw_probe" patches/mister/mister_blitter_renderer.cpp \
  patches/mister/mister_blitter_renderer.h || echo "RENDERER CLEAN"
```
Expected: `RENDERER CLEAN`.

- [ ] **Step 6: Type-check**

```bash
g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
  -I patches/mister -I patches/mister/blitter \
  -I work/solarus/include -I build/armhf/include \
  -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) \
  patches/mister/mister_blitter_renderer.cpp && echo "SYNTAX OK"
```
Expected: `SYNTAX OK`.

- [ ] **Step 7: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp patches/mister/mister_blitter_renderer.h \
        patches/mister/blitter/blt_emitter.h
git commit -m "refactor(render): delete bgplane state, flags, env reads, SDRAM arena"
```

---

### Task 7: Remove `blt_bgplane_write_cell`, keep the wire-ABI constants reserved

The **emitter function** goes; the **opcode number and flag bit stay reserved**. Phase B adds a new opcode, and renumbering the wire ABI while simultaneously extending it is needless risk. `scripts/tests/test_wire_constants.py` asserts host↔RTL numbering and must keep passing unchanged.

**Files:**
- Modify: `patches/mister/blitter/blt_emitter.h` (remove decl `:267-276`), `patches/mister/blitter/blt_emitter.c` (remove impl `:520-530`)
- Modify: `patches/mister/blitter/blitter_ref.h` — annotate `BLT_OP_BGPLANE_WRITE = 8` (`:89`) and `BLT_F_BGCOV = 0x80` (`:171-174`) as reserved

**Interfaces:**
- Consumes: nothing.
- Produces: `BLT_OP_BGPLANE_WRITE = 8` and `BLT_F_BGCOV = 0x80` remain **defined with unchanged values**, marked reserved. Phase B must allocate a *new, higher* opcode and must not reuse 8.

- [ ] **Step 1: Confirm the emitter function is callerless**

```bash
grep -rn "blt_bgplane_write_cell" patches/ tests/ scripts/ || echo "CALLERLESS"
```
Expected: only its own declaration and definition (Tasks 1 and 5 removed every caller). If a test still calls it, Task 1 was incomplete.

- [ ] **Step 2: Delete the declaration and implementation**

Remove the `blt_bgplane_write_cell` prototype and doc comment from `blt_emitter.h:267-276`, and its body from `blt_emitter.c:520-530`.

- [ ] **Step 3: Mark the two constants reserved, values unchanged**

In `blitter_ref.h`, replace the `BLT_OP_BGPLANE_WRITE` comment with:

```c
    BLT_OP_BGPLANE_WRITE = 8, /* RESERVED (Stage 3b): the bgplane bake was deleted
                               * host-side. The value is held so host<->RTL opcode
                               * numbering stays stable and test_wire_constants.py
                               * keeps passing. Do NOT reuse 8 for a new op. */
```

and for the flag:

```c
    BLT_F_BGCOV = 0x80,       /* RESERVED (Stage 3b): bake coverage bit, no longer
                               * emitted. Value held for wire-ABI stability. */
```

- [ ] **Step 4: KEEP `blt_fill_flags` — do not delete it**

Task 5 removed its only two callers (both inside `bake_background_plane_step`), so it is now callerless. **This is expected and correct.** It is a reasonable generic emitter API and the spec keeps it deliberately. Confirm it survives:

```bash
grep -n "blt_fill_flags" patches/mister/blitter/blt_emitter.h patches/mister/blitter/blt_emitter.c
```
Expected: still declared at `blt_emitter.h:139` and defined at `blt_emitter.c:121`. If a compiler warning about an unused function appears, leave the function and suppress nothing — it has external linkage, so no warning should fire.

- [ ] **Step 5: Confirm the wire-constant cross-check still passes**

```bash
python3 scripts/tests/test_wire_constants.py && echo "WIRE OK"
```
Expected: `WIRE OK`. This test compares host enums against the RTL `blitter_defs.vh`; because both sides keep value 8, it passes with **no edit to the test**. If it fails, a value was changed — revert and keep the numbers.

- [ ] **Step 6: Run the CI host-test gate**

```bash
bash patches/mister/build_host_tests.sh
```
Expected: `== all host tests passed ==`.

- [ ] **Step 7: Commit**

```bash
git add patches/mister/blitter/
git commit -m "refactor(blitter): drop blt_bgplane_write_cell; reserve opcode 8 + BGCOV

Values are held so host<->RTL numbering stays stable and Phase B is forced
to allocate a fresh opcode rather than recycling 8."
```

---

### Task 8: Drop series patches 0032 and 0035; clean launch scripts

**Files:**
- Delete: `patches/series/0032-fix-render-keep-bgplane-s-full-frame-COPY-latch-runn.patch`
- Delete: `patches/series/0035-docs-render-fix-stale-bgplane-comment-describing-the.patch`
- Modify: `games/Solarus/solarus_run.sh:80` (banner field)
- Modify: `games/Solarus/diag.env` (comment blocks + commented-out flags)

**Interfaces:**
- Consumes: nothing.
- Produces: a renumbered patch series. **Patches 0033, 0034, and 0036 are KEPT** — 0033 publishes `mister_set_background_color` (Phase B needs the map background colour), 0034 threads `min_layer` (live ABI), 0036 is a net simplification that already reverted 0032.

- [ ] **Step 1: Verify 0032 is fully reverted by 0036**

```bash
grep -l "resident_static_before_animated" patches/series/*.patch
grep -rn "resident_static_before_animated" work/solarus/include work/solarus/src || echo "ABSENT from engine tree"
```
Expected: 0032, 0034, and 0036 mention the symbol; the engine tree reports `ABSENT` because 0036 removed it. That confirms dropping 0032 changes no final state.

- [ ] **Step 2: Confirm 0033's consumer survives**

```bash
grep -rn "mister_set_background_color" patches/series/*.patch work/solarus/src | head
```
Expected: declared by 0033 and re-declared by 0040. **Keep 0033.** If 0040 does not reference it, still keep 0033 — Phase B §2 needs the background colour.

- [ ] **Step 3: Remove the two patches and regenerate the series**

Pin the diff algorithm **for the repo** first — `git -c` only applies to a git subcommand and will not reach the algorithm used inside the script:

```bash
git config diff.algorithm myers
git rm patches/series/0032-fix-render-keep-bgplane-s-full-frame-COPY-latch-runn.patch \
       patches/series/0035-docs-render-fix-stale-bgplane-comment-describing-the.patch
bash scripts/export_patches.sh
```
Expected: the series renumbers contiguously with no gaps.

- [ ] **Step 4: Verify the series round-trips**

```bash
bash scripts/verify_patches.sh
```
Expected: clean apply of the whole series.
Expected: clean apply. A failure here is usually `diff.algorithm=patience` leaking from user-global git config — pin `myers` and retry.

- [ ] **Step 5: Clean the launch scripts**

In `games/Solarus/solarus_run.sh:80`, remove the `BGPLANE=${SOLARUS_BGPLANE:-unset}` field from the banner, leaving neighbouring fields and quoting intact. In `games/Solarus/diag.env`, remove the bgplane comment blocks and the two commented-out `SOLARUS_BGPLANE*` lines.

- [ ] **Step 6: Shellcheck both**

```bash
shellcheck games/Solarus/solarus_run.sh && echo "SHELLCHECK OK"
```
Expected: `SHELLCHECK OK` (CI runs a ShellCheck job).

- [ ] **Step 7: Commit**

```bash
git add -A patches/series/ games/Solarus/
git commit -m "chore: drop bgplane series patches 0032/0035; clean launch banners

0033 (background colour) and 0034 (min_layer) are kept — Phase B needs both.
0036 already reverted 0032, so dropping it changes no final state."
```

---

### Task 9: Build, deploy, and the Phase A hardware gate

**Files:**
- No source changes. Produces `build/armhf/solarus-run` + `libsolarus.so.1.6.5`, refreshes `deploy/`.

**Interfaces:**
- Consumes: everything from Tasks 1–8.
- Produces: a validated Phase A baseline for Phase B to branch from.

- [ ] **Step 1: Full container build**

```bash
scripts/docker_run.sh bash scripts/build_engine.sh 2>&1 | tee /tmp/build_phaseA.log
grep BUILD_EXIT /tmp/build_phaseA.log
```
Expected: `BUILD_EXIT=0`. **Do not trust the command's own exit status** — read this marker.

- [ ] **Step 2: Confirm the binary carries no bgplane symbols**

```bash
strings build/armhf/libsolarus.so.1.6.5 | grep -i bgplane || echo "NO BGPLANE SYMBOLS"
```
Expected: `NO BGPLANE SYMBOLS`. This is the objective proof the subsystem is gone from the shipped artifact, not merely unreferenced in source.

- [ ] **Step 3: Refresh `deploy/` and push**

```bash
cp build/armhf/solarus-run deploy/games/Solarus/solarus-run
cp build/armhf/libsolarus.so.1.6.5 deploy/libs/libsolarus.so.1.6.5
./deploy.py --no-rbf --host 192.168.20.81
```
`deploy.py` exiting 0 says nothing about which files moved — verify explicitly in Step 4.

- [ ] **Step 4: sha1-verify on device**

```bash
shasum -a 1 build/armhf/libsolarus.so.1.6.5 deploy/libs/libsolarus.so.1.6.5
ssh root@192.168.20.81 'sha1sum /media/fat/games/solarus/libs/libsolarus.so.1.6.5 \
                                /media/fat/games/solarus/solarus-run'
```
Expected: the device's `libsolarus` sha1 matches the freshly built one. A mismatch means a partial scp or an open-exe overwrite failure — `rm` the remote file and re-push.

- [ ] **Step 5: Launch for the HW gate**

Leave `/media/fat/config/Solarus.s0` **empty**, load the core from the OSD, then launch detached with a private quest override:

```bash
ssh root@192.168.20.81 'cd /media/fat/games/solarus && \
  mkdir -p /media/fat/logs/Solarus && \
  setsid env S0_FILE=/tmp/private_s0 sh solarus_run.sh \
    > /media/fat/logs/Solarus/phaseA.log 2>&1 </dev/null &'
```

Two concurrent engines make the host mostly unresponsive — confirm only one is running:
```bash
ssh root@192.168.20.81 'pidof solarus-run'
```
Expected: exactly one PID. Log to `/media/fat/logs/`, never `/tmp` (wiped on restart).

- [ ] **Step 6: Confirm the loaded core, then gather operator verdicts**

Confirm which RBF is active before judging any visual result — sending an opcode to a fabric with no arm for it produces garbage that looks like a bug.

Present to the **operator** (never self-declare — memory `solarus-no-self-declared-visual-validation`):
1. **Baseline comparison:** behaviour must be **identical to the pre-Phase-A default-OFF build**. Any visible difference is a regression.
2. **Explicit verdict on #122** (scroll-transition hold frame) — closed by removal, or still open.
3. **Explicit verdict on #127** (transition hitch + bg-colour flash on all transition types).
4. **Explicit verdict on #123** (scroll black frame) — the spec expects this *probably* resolves; record what is actually observed, not what was predicted.

Visit a scroll transition (map 8→9 or 9→3) and at least one fade transition.

- [ ] **Step 7: Record the validation and commit**

Write `docs/superpowers/2026-07-20-stage3b-phaseA-hw-validation.md` containing: the build sha1, the confirmed RBF filename, the four verdicts above **in the operator's words**, and anything observed but unexplained. Then:

```bash
git add docs/superpowers/2026-07-20-stage3b-phaseA-hw-validation.md
git commit -m "docs: Stage 3b Phase A HW validation record"
```

- [ ] **Step 8: Close the issues the operator confirmed**

Only for issues the operator explicitly declared closed in Step 6:

```bash
gh issue close 122 --comment "Closed by Stage 3b Phase A: the bgplane bake is deleted, not merely default-OFF. HW-validated — see docs/superpowers/2026-07-20-stage3b-phaseA-hw-validation.md"
gh issue close 127 --comment "Closed by Stage 3b Phase A: the bake is deleted. HW-validated — see docs/superpowers/2026-07-20-stage3b-phaseA-hw-validation.md"
```

Leave #123 open unless the operator confirmed it resolved.

- [ ] **Step 9: Update `CLAUDE.md`**

`CLAUDE.md` currently documents `SOLARUS_BGPLANE` as a live default-OFF flag. Replace that bullet with a note that the bake was deleted in Stage 3b Phase A, that opcode 8 and `BLT_F_BGCOV` are reserved-not-reused, and that the bgplane **RTL** removal lands with Phase B.

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md — bgplane bake deleted (Stage 3b Phase A)"
```

---

## Phase A completion

Phase A is done when: the engine builds with `BUILD_EXIT=0`, the shipped `.so` contains no bgplane symbols, `build_host_tests.sh` and `test_wire_constants.py` pass, the patch series round-trips, and the **operator** has confirmed on hardware that behaviour is unchanged and given explicit verdicts on #122/#127/#123.

**Do not begin Phase B until Step 6's verdicts are recorded.** Phase B changes RTL and adds a new opcode; starting it on an unvalidated Phase A tree would put a host deletion and a fabric change into the same attribution window, which is precisely what the two-phase split exists to prevent.
