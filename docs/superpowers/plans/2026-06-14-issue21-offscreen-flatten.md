# #21 Off-screen-path Background Flatten — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the static + scrolling background flatten on #18's off-screen `C_TARGET=2` compose path so the overworld composite drops from 6× to ~2×, lifting fps toward 60, then ship it default-on after a visual gate.

**Architecture:** Engine-only changes to `patches/mister/mister_blitter_renderer.cpp` (the FPGA-blitter Renderer backend). The flatten state machine (LEARN→SNAPSHOT→ACTIVE), off-screen snapshot, and scroll-shifted copy already exist; this plan retires the dead alias-path heuristic, perf-tunes the scroll path, and validates engine-side. **No RBF/fabric change** → the working analog-clean core stays untouched.

**Tech Stack:** C++ (Solarus SurfaceImpl/DrawProxies API), cross-compiled armhf via Docker (`solarus-armhf-build:bullseye`), deployed to MiSTer at `192.168.20.81` over SSH, validated by on-device stderr counters.

---

## ⚠️ Validation model (read first — this is NOT a unit-test plan)

This is hardware-in-the-loop perf work. There is **no local test harness** for rendering. Each task's "test" is:

1. **Build** the engine (Docker cross-compile).
2. **Deploy** the `.so` (`deploy.py --no-rbf` — no RBF, analog stays clean).
3. **Run** on-device with a scripted-input scenario and diag counters.
4. **Read counters** from the log and compare to the recorded baseline.

**Counters certify throughput (fps), workload (overdraw), and safety (escape==0). They do NOT certify render correctness** — that is a **deferred visual gate the user performs at the monitor** (Task 8). Do not flip anything default-on before that gate passes. **Commit before each experiment** so any change is revertible.

### Canonical commands (used by every task)

**Build (from repo root, host with Docker):**
```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh
# Output: build/armhf/libsolarus.so.1.6.5  (+ build/armhf/solarus-run)
```

**Deploy engine only (no RBF):**
```bash
./deploy.py --no-rbf --host 192.168.20.81
```

**Run a scenario on device + capture counters** (`$SCRIPT` = the scenario's input script; `$TAG` = a per-run log name). The `kill` is required — busybox has no `pkill`:
```bash
ssh root@192.168.20.81 'kill -9 $(pidof solarus-run) 2>/dev/null; \
  cd /media/fat/games/solarus && \
  ln -sf "$(ls quests/*.sol | head -1)" /tmp/solarus_quest/data.solarus 2>/dev/null; \
  SDL_VIDEODRIVER=dummy LD_LIBRARY_PATH=/media/fat/games/solarus/libs:. \
  SOLARUS_BLITTER=1 SOLARUS_BGCACHE=1 SOLARUS_SCROLLCACHE=1 SOLARUS_BLITTER_DIAG=1 \
  SOLARUS_INPUT_SCRIPT="'"$SCRIPT"'" \
  timeout 35 ./solarus-run -force-software-rendering /tmp/solarus_quest 2>&1 | tail -200 > /tmp/'"$TAG"'.log; \
  grep -E "\[blitter timing\]|\[blitter diag\]|bgcache|bg_state" /tmp/'"$TAG"'.log | tail -25'
```

**Two canonical scenarios** (input-script masks: 0x010=B/action, 0x004=Down; tune `t_ms` to the quest's intro if the hero never spawns — confirm via a non-zero `[blitter timing]` fps in the log):
- **STATIC** (standing in the overworld, no scroll):
  `SCRIPT="800:0x010,1100:0,1900:0x010,2200:0,3000:0"`
- **WALKING** (sustained downward scroll):
  `SCRIPT="800:0x010,1100:0,1900:0x010,2200:0,3000:0x004"` (holds Down from 3s to the 35s timeout)

### Counters you will read
- `[blitter timing] ... fps=NN period=NNms | fabric=NNms A9=NNms ... ` — throughput + the A9/fabric split.
- `[blitter diag] /60fr: emit=.. escape=.. fills=.. blits=.. ...` — **escape MUST be 0**.
- bg-cache line: `bg_state=.. bg_copies=.. bg_skips=.. bg_snaps=.. bg_stable_run=..` — confirms the cache engaged (`bg_state=2`=ACTIVE) and how often it re-snapshots (`bg_snaps`).

---

## File structure

Only two files change:
- `patches/mister/mister_blitter_renderer.cpp` — the renderer backend (all flatten logic + instrumentation). Modified in Tasks 1–6.
- `games/Solarus/solarus_run.sh` — launch env defaults. Modified in Task 7 (default-on flip, gated on Task 8).

No new files. The spec lives at `docs/superpowers/specs/2026-06-14-issue21-offscreen-flatten-design.md`.

---

## Task 0: Record the post-#18 baseline

No code change. Establish that the loop works and capture the numbers everything else is measured against (we have **no** post-#18 figures — the 45/30 numbers predate the off-screen rewire).

- [ ] **Step 1: Build + deploy current `master`-derived branch**

```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh
./deploy.py --no-rbf --host 192.168.20.81
```
Expected: build prints `libsolarus.so.1.6.5`; deploy prints sha1-verified upload.

- [ ] **Step 2: Measure STATIC**

Run the canonical run command with `TAG=base_static` and the STATIC `SCRIPT`.
Expected: a `[blitter timing]` line with a non-zero fps (cache warmed → `bg_state=2`). Record `fps`, `fabric`, `A9`, `escape`, `bg_snaps`.

- [ ] **Step 3: Measure WALKING**

Run with `TAG=base_walk` and the WALKING `SCRIPT`.
Expected: `[blitter timing]` fps during the held-Down phase. Record `fps`, `fabric`, `escape`, `bg_snaps`, `bg_skips`.

- [ ] **Step 4: Write the baseline into the spec**

Append a `## Baseline (post-#18, YYYY-MM-DD)` section to `docs/superpowers/specs/2026-06-14-issue21-offscreen-flatten-design.md` with the static + walking fps/fabric/escape numbers.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-06-14-issue21-offscreen-flatten-design.md
git commit -m "docs(#21): record post-#18 static+walking baseline"
```

---

## Task 1: Gap A — retire dead alias-path code (conservatively)

The `SOLARUS_ALIAS_SW` heuristic (`looks_like_promote` accepting software surfaces) is superseded by the deterministic camera tag (#15, `g_tagged_camera`). Remove it **only if** the baseline confirmed the camera is tagged (so the heuristic is genuinely dead). Conservative: keep `looks_like_promote` as the no-tag fallback; remove just the `alias_allow_sw` software-surface relaxation.

**Files:** Modify `patches/mister/mister_blitter_renderer.cpp`

- [ ] **Step 1: Confirm the camera tag is active (not the heuristic)**

In `/tmp/base_static.log` from Task 0, expect `[blitter alias] camera TAGGED=0x..` (deterministic path, line ~1036). If instead you see `[blitter alias] camera surface=.. aliased` (heuristic path), STOP — the heuristic is live; skip this task and note it in the commit log of Task 2.

- [ ] **Step 2: Remove the `alias_allow_sw` software relaxation**

In `looks_like_promote` (line ~869), the gate is:
```cpp
    if (!alias_allow_sw && !s->get_texture()) return false;  // must be a render texture
```
Replace with (the tag path doesn't route through here; the heuristic should only ever accept true render-textures):
```cpp
    if (!s->get_texture()) return false;  // must be a render texture (camera tag handles sw surfaces)
```
Then delete the now-unused field `bool alias_allow_sw = false;` (line ~333) and its initializer `self->d->alias_allow_sw = (std::getenv("SOLARUS_ALIAS_SW") != nullptr);` (line ~900). Leave the `SOLARUS_ALIAS_SW` mention in the env-knob diag print (line ~866 comment) updated to note it is retired.

- [ ] **Step 3: Build + deploy**

```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh && ./deploy.py --no-rbf --host 192.168.20.81
```
Expected: clean build (no reference-to-removed-symbol errors).

- [ ] **Step 4: Re-measure STATIC for parity**

Run with `TAG=t1_static`, STATIC `SCRIPT`.
Expected: `fps`, `fabric`, `escape`, `bg_state=2` **within noise of the Task 0 static baseline** (this is a no-op cleanup; any change means the heuristic WAS load-bearing — revert and reassess).

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "refactor(#21): retire dead SOLARUS_ALIAS_SW heuristic (camera tag is the path)"
```

---

## Task 2: Gap A — audit double-buffer coherence (written conclusion)

A correctness concern best reasoned in code (the smear is a visual artifact counters can't see; the `VERIFY` counter gives a partial check). ACTIVE emits `blt_blit_copy(bg_handle)` into `target_buf` every frame, and `target_buf` alternates each present — so each of the two display buffers is re-based from the cache every frame. Confirm there is no path that emits dynamic-on-stale.

**Files:** Read-only audit of `patches/mister/mister_blitter_renderer.cpp`; write conclusion to the spec.

- [ ] **Step 1: Trace the ACTIVE per-frame path**

Confirm in `present()`/`blt_begin_frame` (lines ~590–602) that the ACTIVE branch runs `blt_begin_frame(clear=0)` then `blt_blit_copy(bg_handle, -cur_dx, -cur_dy)` **unconditionally every frame** (no carry-forward, no skip), into the current `target_buf`. Confirm `target_buf` toggles each non-off-screen submit (line ~1356: `if (!single_buf && submitted_buf != 2) target_buf ^= 1`).

- [ ] **Step 2: Confirm the off-screen snapshot does NOT toggle the display buffer**

At line ~1356 the toggle is gated `submitted_buf != 2`, so a `C_TARGET=2` snapshot frame leaves `target_buf` unchanged — the next display frame lands in the correct buffer. Verify no other site advances the buffer on a snapshot.

- [ ] **Step 3: Optional counter check with VERIFY**

Run with `TAG=t2_verify` and `SOLARUS_BLITTER_VERIFY=1` added to the env (STATIC scenario). Expected: `[blitter verify]` `this-frame match` high (≈100%) — confirms committed buffer matches the intended composite. (This is a coherence sanity check, not a render-correctness proof.)

- [ ] **Step 4: Write the conclusion to the spec**

Append a `## Double-buffer coherence (audited)` note to the spec stating the per-frame re-base guarantees both buffers carry the current bg, and the snapshot-buffer-toggle gate is correct. If Step 1–2 found a gap, instead write the gap + the fix and implement it here (re-base both buffers explicitly).

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/specs/2026-06-14-issue21-offscreen-flatten-design.md
git commit -m "docs(#21): audit double-buffer coherence on the ACTIVE path"
```

---

## Task 3: Gap B — instrument per-frame composited pixels (diagnose the 30fps cap)

The scroll path's suspected culprit: edge-strip recomposite re-emitting whole cells instead of just the ~|shift|px revealed edge. Add a per-frame composited-pixel counter so we can SEE the scroll workload, then diagnose.

**Files:** Modify `patches/mister/mister_blitter_renderer.cpp`

- [ ] **Step 1: Add a composited-pixel tally**

Near the diag tallies (`long bg_skips = 0, bg_copies = 0, bg_snaps = 0;`, line ~346) add:
```cpp
  long bg_strip_px = 0;   // px emitted by scroll edge-strips this diag window (Gap B diag)
  long bg_dyn_px   = 0;   // px emitted by dynamic (hero/HUD) blits this diag window
```

- [ ] **Step 2: Accumulate strip pixels in the scroll edge-emit**

In the ACTIVE scroll branch (lines ~1147–1150), `emit_draw_clipped` returns whether it emitted. Accumulate the clipped rect area. Change each of the four strip emits from:
```cpp
          if (d->cur_dx > 0) any |= d->emit_draw_clipped(src, infos, ox, oy, FB_W - d->cur_dx, 0, FB_W, FB_H);
```
to also tally (apply the same pattern to all four lines, using each strip's own clip box):
```cpp
          if (d->cur_dx > 0) { bool e = d->emit_draw_clipped(src, infos, ox, oy, FB_W - d->cur_dx, 0, FB_W, FB_H); if (e) d->bg_strip_px += (long)d->cur_dx * FB_H; any |= e; }
```
(Strip area = shift × screen-edge length. For dy strips use `cur_dy * FB_W`.)

- [ ] **Step 3: Print + reset the tallies in the diag block**

In the bg-cache diag `fprintf` (line ~1283) add `bg_strip_px`/`bg_dyn_px` to the format + args, and reset them to 0 alongside the other per-window tallies (find where `bg_copies`/`bg_skips` reset each diag window and add `bg_strip_px = bg_dyn_px = 0;`).

- [ ] **Step 4: Build + deploy + measure WALKING**

```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh && ./deploy.py --no-rbf --host 192.168.20.81
```
Run with `TAG=t3_walk`, WALKING `SCRIPT`.
Expected: a `bg_strip_px=NN` value during scroll. **Diagnosis threshold:** at ~2px/frame scroll, ideal strip work ≈ `2 * 240 * n_layers` ≈ a few thousand px/frame. If `bg_strip_px` is instead near a full-screen-per-layer (320×240×n ≈ 100k+), the strips are re-emitting whole cells → confirmed bug, proceed to Task 4. If strip px is already tiny, the cap is re-snapshot churn → skip to Task 5.

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "diag(#21): per-frame scroll-strip + dynamic composited-pixel counters"
```

---

## Task 4: Gap B — fix edge-strip clipping if whole cells leak (contingent on Task 3)

**Only if Task 3 Step 4 showed `bg_strip_px` near full-cell size.** The likely cause: `emit_draw_clipped` clips the *destination* box but still uploads/emits the full source cell, or `in_uncovered_margin` isn't gating the cell-skip so non-edge cells re-emit fully.

**Files:** Modify `patches/mister/mister_blitter_renderer.cpp`

- [ ] **Step 1: Verify the clip reaches the emitted blit rect**

Read `emit_draw_clipped` (line ~835). Confirm the clip box intersects the **destination rect** and that the corresponding **source sub-region** (`infos.region` offset by the clip) is what gets emitted — not the full `src`. If it emits the full source with only a dst scissor, narrow it to the intersected src sub-rect (compute `clip ∩ dst`, map back to src coords, emit only that).

- [ ] **Step 2: Confirm non-edge cacheable cells are fully skipped**

In the ACTIVE scroll branch (line ~1141), a cell entirely covered by the shifted snapshot must emit nothing. Verify the four-strip emit produces zero when the cell's dst rect doesn't intersect any uncovered margin (the `any` stays false → counted as `bg_skips`). If covered cells still emit, gate the whole block with `if (in_uncovered_margin(dst.x,dst.y,dst.w,dst.h))` before the strip emits.

- [ ] **Step 3: Build + deploy + re-measure WALKING**

```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh && ./deploy.py --no-rbf --host 192.168.20.81
```
Run with `TAG=t4_walk`, WALKING `SCRIPT`.
Expected: `bg_strip_px` drops to the few-thousand range; `fabric` ms drops; `fps` rises above the Task 0 walking baseline; `escape=0`.

- [ ] **Step 4: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "fix(#21): scroll edge-strips emit only the revealed edge, not whole cells"
```

---

## Task 5: Gap B — reduce re-snapshot churn

`MAXSHIFT=96` forces a full static recomposite every ~96px of scroll. If `bg_snaps` ticks frequently during the held-Down phase (each snap = a costly off-screen compose), raise the re-snapshot interval and confirm the snapshot does not stall the displayed frame.

**Files:** Modify `patches/mister/mister_blitter_renderer.cpp`

- [ ] **Step 1: Check snapshot frequency from Task 0/4 logs**

In the walking log, read `bg_snaps`. If it increments more than ~once per second of walking, churn is a factor → proceed. If it's rare, this task is a no-op; record that and skip to Task 6.

- [ ] **Step 2: Raise MAXSHIFT toward the cache margin**

`MAXSHIFT` (line ~358, `static const int MAXSHIFT = 96;`) bounds how far the shifted snapshot can slide before it no longer covers the screen. The off-screen cache region is a full 320×240 today, so the snapshot can only cover up to its own size minus the view. Raising MAXSHIFT alone without enlarging the cached area would shift past valid data. **Decision:** if Task 4 already cleared the target, do NOT enlarge the cache (YAGNI). Only if walking is still well short and churn dominates, raise to the safe max the current cache geometry allows and re-measure:
```cpp
  static const int MAXSHIFT = 160;   // was 96; re-snapshot less often (verify coverage holds)
```

- [ ] **Step 3: Confirm `present()` doesn't block on the snapshot's C_DONE**

In the post-submit wait, confirm a `C_TARGET=2` snapshot submit is NOT awaited in a way that stalls the displayed frame (the snapshot has no display flip; the engine should continue). If `present()` waits on `C_DONE==submit_seq` unconditionally including the snapshot submit, that's a per-snapshot hitch — gate the wait to display submits only.

- [ ] **Step 4: Build + deploy + re-measure WALKING**

```bash
docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/build_engine.sh && ./deploy.py --no-rbf --host 192.168.20.81
```
Run with `TAG=t5_walk`, WALKING `SCRIPT`.
Expected: `bg_snaps` lower; walking `fps` ≥ Task 4; `escape=0`. **Stop at diminishing returns — ~60 walking is a target, not a requirement.**

- [ ] **Step 5: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "perf(#21): reduce scroll re-snapshot churn (MAXSHIFT / non-blocking snapshot)"
```

---

## Task 6: Record achieved numbers + update the spec success criteria

- [ ] **Step 1: Final measurement pass**

Re-run STATIC (`TAG=final_static`) and WALKING (`TAG=final_walk`) with the canonical command. Record final `fps`/`fabric`/`escape` for both.

- [ ] **Step 2: Update the spec**

In `docs/superpowers/specs/2026-06-14-issue21-offscreen-flatten-design.md`, fill the `## Baseline` section's companion `## Achieved (YYYY-MM-DD)` with before→after static + walking fps, and note any lever that was a no-op (so the rationale is recorded).

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-06-14-issue21-offscreen-flatten-design.md
git commit -m "docs(#21): record achieved static+walking fps after flatten"
```

---

## Task 7: Default-on flip (BLOCKED on Task 8 visual gate)

**Do NOT perform this task until the user has completed the Task 8 visual gate and approved.** Flipping the scroll cache on by default without a visual pass risks shipping an invisible-broken render (the exact failure mode the autonomous-block rule guards against).

**Files:** Modify `games/Solarus/solarus_run.sh`

- [ ] **Step 1: Add the scroll-cache default**

In the default-on block (lines ~100–102, after `export SOLARUS_BGCACHE=1`):
```sh
    export SOLARUS_BGCACHE=1
    export SOLARUS_SCROLLCACHE=1
```
And update the launch echo (line ~105) to include `scrollcache=${SOLARUS_SCROLLCACHE:-off}`.

- [ ] **Step 2: Deploy + smoke-run**

```bash
./deploy.py --no-rbf --host 192.168.20.81
```
Run the WALKING scenario once more; confirm `bg_state=2`, `escape=0`, fps at the achieved level with the env knobs now coming from the script (no explicit `SOLARUS_SCROLLCACHE=1` on the command line).

- [ ] **Step 3: Commit**

```bash
git add games/Solarus/solarus_run.sh
git commit -m "feat(#21): enable scroll-aware bg cache by default (visual-validated)"
```

---

## Task 8: Visual gate + close-out (USER)

**This task is the user's — the agent cannot validate render correctness.**

- [ ] **Step 1: User plays the WALKING + STATIC + transition scenarios at the monitor** and checks: scroll has no edge seams or smear, hero/HUD z-order correct, no re-snapshot hitches, dialog/pause menus correct, overworld entry (the #25/#23/#24 symptoms) clean.
- [ ] **Step 2: If the visual pass succeeds**, the agent performs Task 7 (default-on flip) and the branch is ready to merge; update issue #21 to closed and check whether #23/#24/#25 are resolved by the flatten.
- [ ] **Step 3: If the visual pass finds artifacts**, file the specific symptom, return to systematic-debugging against the relevant task (3/4/5), and re-validate.

---

## Self-review notes

- **Spec coverage:** Gap A (Tasks 1–2), Gap B levers 1–2 (Tasks 3–5), validation/counters (every task + Task 6), visual gate (Task 8), default-on rollout (Task 7), ring-double-buffer dropped (not a task, per spec §6). All spec sections map to a task.
- **Contingency honesty:** Tasks 4 and 5 are explicitly gated on the Task 3 diagnosis / `bg_snaps` reading — a measure-then-decide loop, not fabricated fixes. Decision thresholds are stated.
- **Hard-60 removed:** Tasks 5 and 6 state ~60 walking is a target, stop at diminishing returns (per the user's clarification).
