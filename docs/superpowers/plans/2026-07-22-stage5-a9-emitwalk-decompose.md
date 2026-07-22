# Stage 5 (A9 track) — `emit_walk` decomposition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attribute map 3's ~5 ms `emit_walk` A9 leaf into its sub-components on real hardware, then commit a data-selected decision doc naming the Phase-3 lever — with zero behaviour change in this plan's scope.

**Architecture:** Three diag-gated `ScopedNs` wall-clock accumulators wrap the three concrete emit sub-paths (per-sprite push, resident tilemap emit, overlay composite); a new `[blitter walksplit]` banner prints them plus `engine_traversal` as the residual. The `a9_decompose.py` analyzer learns the new line; the capture harness grabs it; a committed decision doc closes Phase 2 and hands off to a follow-on Phase 3 lever plan.

**Tech Stack:** C++11 whole-file renderer copy (`patches/mister/mister_blitter_renderer.cpp`), armhf Docker cross-build (`scripts/build_engine.sh`), Python 3 analyzer + asserts (`scripts/perf/a9_decompose.py`), the Stage 5 A9 capture harness (`scripts/perf/capture_a9_drill.sh`), device `192.168.20.81`.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-22-stage5-a9-emitwalk-decompose-design.md`. **Prior baseline:** `docs/superpowers/2026-07-22-stage5-a9-decision.md` (map 3 A9-bound, map 119 fabric-bound).
- **Instrumentation only — zero behaviour change.** No emitted pixel or command may change, diag on or off. The `SOLARUS_BLITTER_DIAG`-off path stays byte-identical to master.
- **`mister_blitter_renderer.cpp` is a WHOLE-FILE COPY** (not in `patches/series`) — edit it directly, nothing to regenerate.
- **No RBF.** Host instrumentation only; deploy `./deploy.py --no-rbf`. RBF stays the current ship `Solarus_20260722.rbf`.
- **Accumulators follow the existing delta-counter pattern:** a module-global `volatile long long g_*_ns` that accumulates forever + an `Impl` member `t_*_prev` snapshot; the banner prints `(g - prev)/N/1e6` and updates `prev`. Mirror `g_emit_blit_ns` / `t_emit_blit_prev` exactly (`:70`, `:919`, `:3722-3725`).
- **`diag` reference differs by class:** `emit_overlay_composite` and `sprite_channel_push` are **`Impl`** members → use bare `diag`. `res_emit_bucket_` and `res_emit_static_bucket_` are **`MisterBlitterRenderer`** members → use `d->diag`.
- **Renderer native type-check is MANDATORY and needs BOTH `-D` flags** (`-std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO`); omitting them compiles almost nothing and falsely passes (CLAUDE.md). Full recipe in Task 1 Step 7.
- **`engine_traversal` residual MUST be ≥ 0.** A negative value means a bracket is mis-scoped/double-counted — fix the instrumentation, do NOT ship a decision off a negative residual.
- **Anti-bias gate:** the decision doc (Task 4) is committed **before** any Phase-3 lever code, and its target is selected from the capture, not pre-picked.
- **Commit trailers:** end every commit with the repo's `Co-Authored-By:` + `Claude-Session:` lines (see any recent commit).

**Line numbers are anchors as of `feat/stage5-a9-next-lever` @ HEAD; Task 1's own edits shift later anchors, so re-grep the unique anchor string before each edit rather than trusting a line number.**

---

## File Structure

- `patches/mister/mister_blitter_renderer.cpp` — **modify** (Task 1): 3 accumulators, 3 prev fields, 4 wrap sites, 1 banner block.
- `scripts/perf/a9_decompose.py` — **modify** (Task 2): 1 regex, 1 field map, refined `pick_lever`.
- `scripts/perf/test_a9_decompose.py` — **modify** (Task 2): parser + arithmetic + lever tests.
- `scripts/perf/capture_a9_drill.sh` — **modify** (Task 3): add `walksplit` to `BANNERS`.
- `docs/superpowers/data/stage5-a9/walksplit-map{3,119}.txt` — **create** (Task 3): raw captures.
- `docs/superpowers/2026-07-22-stage5-a9-emitwalk-decision.md` — **create** (Task 4): the gate.

---

### Task 1: Renderer walk sub-brackets + `[blitter walksplit]` banner

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp`

**Interfaces:**
- Consumes: existing `struct ScopedNs` (`:172`), the `diag` bool (`Impl:746`), the `N=60.0` and `walk_ms` locals inside the `[blitter emitsplit]` report block (`:3721-3732`).
- Produces: banner line `\[blitter walksplit\] /60fr: walk=Fms = engine_traversal=F + sprite_push=F + resident_emit=F + overlay=F` (consumed by Task 2's parser + Task 3's capture).

- [ ] **Step 1: Add the three module-global accumulators.** Re-grep the anchor: `grep -n 'volatile long long g_emit_psadd_ns' patches/mister/mister_blitter_renderer.cpp`. Insert immediately AFTER that line:

```cpp
  // [walksplit] wall-ns attribution of emit_walk (diag-gated, delta-counter like
  // g_emit_blit_ns): per-sprite channel push (map_blend/upload/buffer), resident
  // tilemap/tile-list command emit, and the root overlay convert+composite. The
  // residual walk - these three = engine_traversal (Entities::draw z-sort +
  // per-drawable dispatch), computed in the banner.
  volatile long long g_sprite_push_ns   = 0;
  volatile long long g_resident_emit_ns = 0;
  volatile long long g_overlay_ns       = 0;
```

- [ ] **Step 2: Add the three `Impl` snapshot fields.** Re-grep: `grep -n 't_emit_blit_prev = 0, t_emit_psadd_prev = 0' patches/mister/mister_blitter_renderer.cpp`. Insert immediately AFTER that line:

```cpp
  long long t_sprite_push_prev = 0, t_resident_emit_prev = 0, t_overlay_prev = 0; // [walksplit] snapshots
```

- [ ] **Step 3: Wrap `emit_overlay_composite` (Impl member → bare `diag`).** Re-grep: `grep -n 'void emit_overlay_composite() {' patches/mister/mister_blitter_renderer.cpp`. The current first body line is `if (!overlay_touched) return;`. Insert a new line BEFORE it (as the first statement of the function body) so RAII covers the early return too:

```cpp
  void emit_overlay_composite() {
    ScopedNs _ov(&g_overlay_ns, diag);
    if (!overlay_touched) return;
```

- [ ] **Step 4: Wrap `sprite_channel_push` (Impl member → bare `diag`).** Re-grep: `grep -n 'int sprite_channel_push(const SurfaceImpl& src, const DrawInfos& infos' patches/mister/mister_blitter_renderer.cpp`. Its body opens on the next line with `uint8_t blend, flags, want_fmt;`. Insert as the first body statement:

```cpp
                          int off_x, int off_y) {
    ScopedNs _sp(&g_sprite_push_ns, diag);
    uint8_t blend, flags, want_fmt; uint16_t key; int why = 0;
```

- [ ] **Step 5: Wrap both resident-emit bucket functions (MisterBlitterRenderer members → `d->diag`).** Re-grep: `grep -n 'MisterBlitterRenderer::res_emit_bucket_(size_t idx)' patches/mister/mister_blitter_renderer.cpp`. Insert as the first body statement (BEFORE the existing `d->flush_sprites_before_other_op();`):

```cpp
void MisterBlitterRenderer::res_emit_bucket_(size_t idx) {
  ScopedNs _re(&g_resident_emit_ns, d->diag);
  d->flush_sprites_before_other_op();   // [Task 4] keep buffered sprites UNDER this op
```

  Then re-grep `grep -n 'MisterBlitterRenderer::res_emit_static_bucket_(size_t idx)' patches/mister/mister_blitter_renderer.cpp` and do the same:

```cpp
void MisterBlitterRenderer::res_emit_static_bucket_(size_t idx) {
  ScopedNs _re(&g_resident_emit_ns, d->diag);
  d->flush_sprites_before_other_op();   // [Task 4] keep buffered sprites UNDER this op
```

- [ ] **Step 6: Add the `[blitter walksplit]` banner inside the emitsplit block.** Re-grep the emitsplit `fprintf`: `grep -n 'emit=%.1fms = walk=%.1f + blit=%.1f' patches/mister/mister_blitter_renderer.cpp`. That `std::fprintf(...)` call is the LAST statement inside the `{ ... }` block that also declares `walk_ms` (`:3726`). Insert the following AFTER that `fprintf(...);` and BEFORE the block's closing `}` (so `walk_ms` and `N` are in scope, and `g_emit_blit_ns`'s delta was already consumed above — we reuse the in-scope `walk_ms`, not re-read the counter):

```cpp
          // [walksplit] attribute emit_walk (walk_ms, in scope above) into our three
          // measured sub-paths; engine_traversal is the residual (Solarus Entities::draw
          // z-sort + per-drawable dispatch). engtrav_ms MUST be >= 0 — a negative means a
          // bracket is mis-scoped/double-counted (fix the instrumentation, don't ship).
          long long sp = g_sprite_push_ns, re = g_resident_emit_ns, ov = g_overlay_ns;
          double push_ms  = (sp - d->t_sprite_push_prev)   / N / 1e6;
          double remit_ms = (re - d->t_resident_emit_prev) / N / 1e6;
          double ovl_ms   = (ov - d->t_overlay_prev)       / N / 1e6;
          d->t_sprite_push_prev = sp; d->t_resident_emit_prev = re; d->t_overlay_prev = ov;
          double engtrav_ms = walk_ms - push_ms - remit_ms - ovl_ms;
          std::fprintf(stderr,
            "[blitter walksplit] /60fr: walk=%.1fms = engine_traversal=%.1f + "
            "sprite_push=%.1f + resident_emit=%.1f + overlay=%.1f\n",
            walk_ms, engtrav_ms, push_ms, remit_ms, ovl_ms);
```

- [ ] **Step 7: Native type-check (BOTH `-D` flags mandatory).**

  Run:
  ```bash
  g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
    -I patches/mister -I patches/mister/blitter -I work/solarus/include \
    -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include \
    $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp
  ```
  Expected: exit 0, no output. If `work/solarus/include` / `build/armhf/include` are absent in a fresh worktree, the include paths won't resolve — in that case defer the type-check to run inside the Docker build (Task 3 Step 2) and note it; do NOT drop the `-D` flags to force a pass.

- [ ] **Step 8: Host suite stays green (no behaviour change).**

  Run: `bash tests/run_tests.sh`
  Expected: all green (this edit adds no host-modeled logic; the suite must be unaffected).

- [ ] **Step 9: Commit.**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "$(printf 'feat(stage5-a9): [blitter walksplit] — attribute emit_walk sub-paths\n\nThree diag-gated ScopedNs accumulators (sprite_push / resident_emit /\noverlay) + a walksplit banner; engine_traversal is the residual. Pure\ninstrumentation, byte-identical with diag off.\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_013qHAXsgJ4PZMsrSMgRFu2t')"
```

---

### Task 2: Teach `a9_decompose.py` the `walksplit` line (TDD)

**Files:**
- Modify: `scripts/perf/a9_decompose.py`
- Modify: `scripts/perf/test_a9_decompose.py`

**Interfaces:**
- Consumes: the Task 1 banner string; existing `_PATS`, `_FIELDS`, `_F` (`:11`), `parse_medians` (`:42`), `pick_lever` (`:61`).
- Produces: parsed keys `walk`, `walk_engine`, `walk_sprite_push`, `walk_resident_emit`, `walk_overlay`; a refined `pick_lever` emit-branch that names the dominant walk sub-leaf's lever.

- [ ] **Step 1: Write the failing tests.** Append to `scripts/perf/test_a9_decompose.py` (before the `_run()` definition):

```python
# Two windows carrying the [blitter walksplit] line, sprite_push-dominant.
SAMPLE_WALK = """\
[blitter a9split] /60fr: A9=12.2ms = lua=5.8ms + emit=5.2ms + present=0.5ms
[blitter emitsplit] /60fr: emit=5.2ms = walk=5.2 + blit=0.0 | ps_add(diag-tax)=0.0 -> real_emit~5.2ms
[blitter walksplit] /60fr: walk=5.2ms = engine_traversal=1.6 + sprite_push=3.0 + resident_emit=0.4 + overlay=0.2
[blitter a9split] /60fr: A9=12.0ms = lua=5.7ms + emit=5.0ms + present=0.5ms
[blitter emitsplit] /60fr: emit=5.0ms = walk=5.0 + blit=0.0 | ps_add(diag-tax)=0.0 -> real_emit~5.0ms
[blitter walksplit] /60fr: walk=5.0ms = engine_traversal=1.4 + sprite_push=3.0 + resident_emit=0.4 + overlay=0.2
"""

def test_walksplit_parses():
    m = parse_medians(SAMPLE_WALK)
    assert m["walk"] == 5.1                 # median(5.2, 5.0)
    assert m["walk_engine"] == 1.5          # median(1.6, 1.4)
    assert m["walk_sprite_push"] == 3.0
    assert m["walk_resident_emit"] == 0.4
    assert m["walk_overlay"] == 0.2

def test_walksplit_arithmetic_reconstructs():
    m = parse_medians(SAMPLE_WALK)
    parts = m["walk_engine"] + m["walk_sprite_push"] + m["walk_resident_emit"] + m["walk_overlay"]
    assert abs(parts - m["walk"]) < 0.11    # rounds to walk within one 0.1ms tick

def test_pick_lever_walk_sprite_push():
    # emit_walk is the top A9 leaf and sprite_push dominates the walk -> per-sprite cache
    m = parse_medians(SAMPLE_WALK)
    lever = pick_lever(m, {})
    assert "sprite_push" in lever and "per-sprite" in lever
```

- [ ] **Step 2: Run to verify they fail.**

  Run: `python3 scripts/perf/test_a9_decompose.py`
  Expected: FAIL — `KeyError: 'walk'` (or an assertion error) in the new tests; `walksplit` is not yet parsed and `pick_lever` doesn't consult it.

- [ ] **Step 3: Add the `walksplit` regex + field map.** In `scripts/perf/a9_decompose.py`, add to the `_PATS` dict (after the `emitsplit` entry, `:15`):

```python
    "walksplit": re.compile(r"\[blitter walksplit\].*?walk="+_F+r"ms = engine_traversal="+_F+r" \+ sprite_push="+_F+r" \+ resident_emit="+_F+r" \+ overlay="+_F),
```

  and to `_FIELDS` (after the `emitsplit` entry, `:25`):

```python
    "walksplit": [(1, "walk"), (2, "walk_engine"), (3, "walk_sprite_push"),
                  (4, "walk_resident_emit"), (5, "walk_overlay")],
```

- [ ] **Step 4: Refine `pick_lever`'s emit branch to name the dominant walk sub-leaf.** Replace the existing block (`:69-71`):

```python
    if top in ("emit_walk", "emit_blit"):
        return ("emit dominant -> z-sorted visible-entity cache (lever 1e) OR emit-walk "
                "collapse; use LD_PROFILE to disambiguate draw-retrieval/z-sort vs blit")
```

  with:

```python
    if top in ("emit_walk", "emit_blit"):
        subs = {k: m[k] for k in ("walk_engine", "walk_sprite_push",
                                  "walk_resident_emit", "walk_overlay") if k in m}
        if subs:
            sub = max(subs, key=subs.get)
            names = {
                "walk_sprite_push":   "per-sprite resolution cache (memoize map_blend/upload by "
                                      "src/frame/blend/opacity; motion-independent -> helps moving)",
                "walk_engine":        "engine_traversal: z-sort/visible-set cache (standing-only, "
                                      "camera-keyed) OR per-drawable dispatch reduction",
                "walk_resident_emit": "resident-emit: reduce per-bucket command re-emission",
                "walk_overlay":       "overlay: should already be small post overlay-skip -> re-verify",
            }
            return f"emit_walk dominant; walk sub-leaf '{sub}' ({subs[sub]:.1f}ms) -> {names[sub]}"
        return ("emit dominant, but no [blitter walksplit] parsed -> capture with the "
                "walksplit banner to disambiguate sprite_push vs engine_traversal")
```

- [ ] **Step 5: Run to verify all tests pass.**

  Run: `python3 scripts/perf/test_a9_decompose.py`
  Expected: PASS for every test (the pre-existing ones still green — the `SAMPLE_WALK` additions don't perturb `SAMPLE`).

- [ ] **Step 6: Commit.**

```bash
git add scripts/perf/a9_decompose.py scripts/perf/test_a9_decompose.py
git commit -m "$(printf 'feat(stage5-a9): a9_decompose parses [blitter walksplit] + names walk lever\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_013qHAXsgJ4PZMsrSMgRFu2t')"
```

---

### Task 3: Capture harness + build + deploy + HW drill

**Files:**
- Modify: `scripts/perf/capture_a9_drill.sh`
- Create: `docs/superpowers/data/stage5-a9/walksplit-map3.txt`, `docs/superpowers/data/stage5-a9/walksplit-map119.txt`

**Interfaces:**
- Consumes: the Task 1 banner (in the deployed `.so`), Task 2's analyzer.
- Produces: two raw drill files (each with standing + moving windows) for Task 4.

- [ ] **Step 1: Add `walksplit` to the grabbed banner list.** In `scripts/perf/capture_a9_drill.sh`, the `BANNERS=` line (`:16`) currently reads `... a9split emitsplit luasplit ...`. Insert `walksplit` right after `emitsplit`:

```sh
BANNERS="timing hwperf p0 resident cvt a9split emitsplit walksplit luasplit engcpp drawcat enttype entphase entsplit movedrill"
```

- [ ] **Step 2: Build the engine (armhf Docker).**

  Run: `bash scripts/build_engine.sh`
  Expected: produces `build/armhf/{solarus-run,libsolarus.so.1.6.5}`, 0 `error:` lines. (If Task 1 Step 7's native type-check was deferred, this build is where a renderer type error would surface — treat any `error:` here as a Task 1 regression.)

- [ ] **Step 3: Confirm the banner string is in the binary.**

  Run: `strings build/armhf/libsolarus.so.1.6.5 | grep -c 'blitter walksplit'`
  Expected: `1` (or more). If `0`, the edit didn't compile in — stop and fix Task 1.

- [ ] **Step 4: Deploy engine-only + verify.**

  Refresh `deploy/` from `build/armhf` (per `fpga-deploy-refresh-from-build-armhf` memory — deploy ships from `deploy/`), then:
  ```bash
  ./deploy.py --no-rbf
  ```
  Expected: deploy.py's own sha1 stage-then-swap + loader probe pass. Confirm the on-device `.so` matches the new build:
  ```bash
  ssh root@192.168.20.81 'sha1sum /media/fat/games/solarus/libs/libsolarus.so.1.6.5'
  sha1sum build/armhf/libsolarus.so.1.6.5
  ```
  Expected: the two sha1s are equal.

- [ ] **Step 5: Capture map 3 (A9-bound target) — standing + moving.**

  Run: `MAP=3 DEST=out_link_house TAG=map3 bash scripts/perf/capture_a9_drill.sh`
  Then copy the harness output to this plan's data path:
  ```bash
  cp docs/superpowers/data/stage5-a9/drill-map3.txt docs/superpowers/data/stage5-a9/walksplit-map3.txt
  ```
  Expected: the file contains a `--- [blitter walksplit] (last 5) ---` section under BOTH `state=standing` and `state=moving`, each with ≥3 populated `[blitter walksplit]` windows, and `engine alive? -> ALIVE`.

- [ ] **Step 6: Capture map 119 (fabric-bound reference) — standing + moving.**

  Run: `MAP=119 DEST=from_dungeon_10 TAG=map119 bash scripts/perf/capture_a9_drill.sh`
  ```bash
  cp docs/superpowers/data/stage5-a9/drill-map119.txt docs/superpowers/data/stage5-a9/walksplit-map119.txt
  ```
  Expected: same structure. (map 119 is the fabric-bound reference — its walksplit confirms the A9 sub-shape but its fps won't move on an A9 lever; this is the control.)

- [ ] **Step 7: Sanity-check the residual is non-negative.**

  Run: `python3 scripts/perf/a9_decompose.py docs/superpowers/data/stage5-a9/walksplit-map3.txt`
  Expected: it prints the leaf table and a `LEVER CANDIDATE:` line. In the raw file, confirm every `[blitter walksplit]` window has `engine_traversal` ≥ 0 and `walk` ≈ the same window's `[blitter emitsplit]` `emit` (they measure the same quantity). If any `engine_traversal` is negative, a Task 1 bracket is mis-scoped — return to Task 1, do not proceed to Task 4.

- [ ] **Step 8: Commit the harness change + raw data.**

```bash
git add scripts/perf/capture_a9_drill.sh docs/superpowers/data/stage5-a9/walksplit-map3.txt docs/superpowers/data/stage5-a9/walksplit-map119.txt
git commit -m "$(printf 'measure(stage5-a9): HW walksplit drill — map3 (A9-bound) + map119 (fabric ref)\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_013qHAXsgJ4PZMsrSMgRFu2t')"
```

---

### Task 4: Commit the decision doc (Phase 2 gate)

**Files:**
- Create: `docs/superpowers/2026-07-22-stage5-a9-emitwalk-decision.md`

**Interfaces:**
- Consumes: Task 3's raw captures + `a9_decompose.py`.
- Produces: the committed decision that Phase 3's follow-on lever plan starts from. This is the anti-bias gate — committed before any lever code.

- [ ] **Step 1: Compute the walksplit medians.** For each of map 3 and map 119, standing and moving, take the median of ≥3 `[blitter walksplit]` windows for `engine_traversal`, `sprite_push`, `resident_emit`, `overlay` (and `walk`). Run `python3 scripts/perf/a9_decompose.py docs/superpowers/data/stage5-a9/walksplit-map3.txt` and record its `LEVER CANDIDATE:` line verbatim.

- [ ] **Step 2: Identify the dominant sub-leaf and select the Phase-3 lever.** The dominant `emit_walk` sub-leaf on **map 3 moving** (the operative A9-bound case) selects the lever, using the spec's Phase-3 menu:
  - `sprite_push` dominant → **per-sprite resolution cache** (motion-independent; correctness trap = animation/source-mutation staleness → needs a `written_this_frame`-style guard like overlay-skip).
  - `engine_traversal` dominant → **dispatch reduction** (if it's our glue) or **z-sort/visible-set cache** (engine z-sort; known standing-only, low value for moving — accept only if forced).
  - `resident_emit` dominant → per-bucket command re-emission reduction.

- [ ] **Step 3: Write the decision doc.** Create `docs/superpowers/2026-07-22-stage5-a9-emitwalk-decision.md` containing, at minimum:
  - a per-scene walksplit table (map 3 / map 119 × standing / moving, the four sub-leaves + walk total);
  - the reproducibility check (`walk` ≈ `emit` per window; `engine_traversal` ≥ 0 everywhere);
  - the **named dominant sub-leaf** and the **selected Phase-3 lever**, with its expected magnitude (an UPPER BOUND, since fps < 60 caps the per-frame recovery) and its top correctness trap;
  - an explicit restatement that **map 119 stays fabric-bound** and this lever will not raise its fps (its walksplit is the control, not a target);
  - a "Deferred" section listing the non-selected walk sub-levers (one-lever discipline).
  Mirror the structure/tone of `docs/superpowers/2026-07-22-stage5-a9-decision.md`.

- [ ] **Step 4: Commit.**

```bash
git add docs/superpowers/2026-07-22-stage5-a9-emitwalk-decision.md
git commit -m "$(printf 'decide(stage5-a9): emit_walk lever data-selected from HW walksplit\n\nAnti-bias gate: committed before any lever code. Names the dominant\nemit_walk sub-leaf on map3 moving and the Phase-3 lever. map119 stays\nfabric-bound (control, not a target).\n\nCo-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_013qHAXsgJ4PZMsrSMgRFu2t')"
```

- [ ] **Step 5: Hand off to Phase 3.** Phase 3 (the actual optimization) is a SEPARATE follow-on plan authored off this decision doc — gated `SOLARUS_*` default-off, TDD'd bit-exact/host test, armhf build, `deploy.py --no-rbf`, HW A/B at the same spots, operator visual gate (never self-declared — `solarus-no-self-declared-visual-validation`). Do NOT start Phase 3 in this plan. Report the decision and the selected lever to the user; brainstorm/plan Phase 3 as its own cycle.

---

## Self-Review

**Spec coverage:**
- Spec Component 1 (three `ScopedNs` sub-brackets at the four verified sites, `diag`-gated) → Task 1 Steps 1,3,4,5 ✓ (`sprite_channel_push`, `res_emit_bucket_`+`res_emit_static_bucket_`, `emit_overlay_composite`).
- Spec Component 2 (`[blitter walksplit]` banner, `engine_traversal` residual, ≥0 self-check) → Task 1 Step 6 + Task 3 Step 7 ✓.
- Spec Component 3 (type-check, host suite, `a9_decompose.py`+test parse, build, `--no-rbf` deploy, capture at the exact spots, decision-doc gate) → Task 1 Steps 7-8, Task 2, Task 3, Task 4 ✓.
- Spec "correctness = instrumentation only, byte-identical diag-off" → Global Constraints + Task 1 Step 8 (suite green) ✓.
- Spec "map 119 fabric bound out of scope / control" → Task 3 Step 6 + Task 4 Step 3 ✓.
- Spec Phase 3 is a follow-on, not chosen here → Task 4 Step 5 ✓.

**Placeholder scan:** No TBD/TODO. Task 4's decision-doc *content* is inherently data-dependent (it records real captured medians), but its required sections, the sub-leaf→lever selection rule, and the commit are all fully specified — the one place values can't be pre-written is the measured numbers, which is correct for a measure-first gate.

**Type consistency:** accumulators `g_sprite_push_ns` / `g_resident_emit_ns` / `g_overlay_ns` and snapshots `t_sprite_push_prev` / `t_resident_emit_prev` / `t_overlay_prev` are named identically in Task 1 Steps 1,2,6. The banner field names `engine_traversal` / `sprite_push` / `resident_emit` / `overlay` in Task 1 Step 6 match the regex + `_FIELDS` keys (`walk_engine` / `walk_sprite_push` / `walk_resident_emit` / `walk_overlay`) and the `pick_lever` `names` dict in Task 2 Steps 3,4, and the test assertions in Task 2 Step 1. `diag` vs `d->diag` is correct per the Global Constraint (Impl vs MisterBlitterRenderer members).
