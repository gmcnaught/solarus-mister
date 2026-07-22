# Stage 5 — Performance Re-baseline + First Lever Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure where the completed retained-scene architecture lands on the map-119 parallax scene, commit a data-driven verdict on the limiter, and land the single limiting lever (host or RTL) gated + HW-validated.

**Architecture:** Four gated phases → five tasks. Tasks 1–3 are host-only on the deployed B2/B3 tilemap RBF: build a cyc/px derivation tool (T1), build a reproducible map-119 capture harness (T2), capture the baseline + commit the decision doc (T3). Task 4 lands the **one** lever the decision doc names — a decision-gated task with two concrete, execute-exactly-one variants (4-HOST engine lever / 4-RTL tilemap-prefetch lever). Task 5 is the HW-validation doc + PR. The measurement is committed *before* any lever code so it can't be retrofitted.

**Tech Stack:** Python 3 (host derivation tool + its unit tests, run with the system `python3`), Bash (device capture harness over SSH), the existing `[blitter *]` diag banners in `patches/mister/mister_blitter_renderer.cpp`, C++11 (host-branch lever, armhf Docker build), SystemVerilog + Quartus/`fpga/sim` (RTL-branch lever), `deploy.py` (SSH deploy), device `192.168.20.81`.

## Global Constraints

- **Base branch:** `feat/stage5-perf-rebaseline`, cut from `origin/master` (contains merged Stage 4 / PR #135). Do not carry Stage 4 branch commits.
- **Phases 1–3 change NO engine/RTL code and require NO rebuild** — they run on the already-deployed B2/B3 tilemap engine + `Solarus_20260721.rbf`. New files are host-side tooling only (`scripts/perf/`).
- **Measure against today's HEAD, no engine change** — the baseline must be the true post-migration state.
- **Commit the decision doc (T3) BEFORE any lever code (T4).** Anti-bias: the verdict is data, not a justification for a pre-picked lever.
- **One lever only.** If two candidates appear, land the highest-leverage one; a second lever is a follow-up stage.
- **Lever gating (T4, both variants):** new `SOLARUS_<LEVER>` env flag, **default-off**, wired via the existing `mister_flag_default_on`/`std::getenv` convention already in the renderer ctor. `=0` must reproduce the T3 baseline exactly (proves a true no-op).
- **Renderer type-check (host-branch build), `-std=c++11` NOT c++17** (c++17 masked a build break in Stage 3b B3), mandatory `-D` flags included:
  ```
  g++ -fsyntax-only -std=c++11 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
    -I patches/mister -I patches/mister/blitter -I work/solarus/include \
    -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include \
    $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp
  ```
- **Safe launch (T2/T3/T4 capture):** exactly ONE `solarus-run` on the fabric (two engines wedge the host). Leave `/media/fat/config/Solarus.s0` EMPTY, load the core, launch with the `S0_FILE` override; log to `/media/fat/logs/Solarus/` (NOT `/tmp`, wiped on restart). Enable banners with a `diag.env` line `SOLARUS_BLITTER_DIAG=1` (sourced by `games/Solarus/solarus_run.sh`; `deploy.py` scrubs it on end-user deploys).
- **Never self-declare visual correctness** — the T4/T5 visual gate is the operator's eyes, per the repo rule.
- **RTL branch only if the data says so** and only if timing closes: Quartus + STA + seed sweep is a hard gate; prefetch, never clock (Cyclone V SE is near its ~100 MHz ceiling — negative-slack builds have occurred).
- **Commit messages** end with the repo's Co-Authored-By + Claude-Session trailers (see existing commits).

**Line numbers are anchors as of `feat/stage5-perf-rebaseline` @ HEAD; re-grep before editing.**

---

### Task 1: cyc/px derivation tool (host-only, no device)

A pure host tool that turns a captured `[blitter hwperf]` + `[blitter resident]` + `[blitter p0]` banner window into the §7 acceptance number: map-119 **tilemap cyc/px**, with a validity check that the grid path (not the overlap-replay fallback) was actually exercised. TDD against synthetic banner fixtures — no hardware.

**Files:**
- Create: `scripts/perf/derive_tilemap_cycpx.py`
- Create: `scripts/perf/test_derive_tilemap_cycpx.py`

**Interfaces:**
- Consumes: nothing (reads banner text).
- Produces: `parse_window(text) -> dict` with keys `comp_cyc_per_frame` (float), `bucket_entries` (int), `blend_draws` (int), `fb_layers` (int, default 3); and `tilemap_cycpx(window) -> {'cycpx': float, 'px_est_fb': int, 'px_est_entries': int, 'divergence_pct': float, 'grid_path_live': bool, 'verdict': str}` where `verdict ∈ {'PASS','FAIL','AMBIGUOUS'}` (AMBIGUOUS iff `2.7 <= cycpx <= 3.3`). Both consumed by T3.

- [ ] **Step 1: Write the failing test.** Create `scripts/perf/test_derive_tilemap_cycpx.py`:

```python
import subprocess, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from derive_tilemap_cycpx import parse_window, tilemap_cycpx

# A synthetic standing-map119 window: comp counter ~ 460800 cyc/frame over
# ~230400 composited px (3 layers * 320*240) -> ~2.0 cyc/px (clean PASS).
SAMPLE = """\
[blitter hwperf] /60fr: fabric_hw=5.20ms comp=4.68ms comp%=90% (460800 cyc/frame) | A9-or-fabric-bound: FABRIC
[blitter resident] /60fr: rebuild=0 fast_noop=60 patch_pass=0 patched_entries=0 | buckets=6 patterns=41 entries=3600 tl_used=1000/4096 valid=1 fatal=0
[blitter p0] /60fr: draws=210 fills=1 | blend NONE=210 BLEND=0 ADD=0 MUL=0 | op full=210 part=0 | xform rot=0 scale=0 colormod=0 | distinct_tex=6
"""

def test_parse_pulls_fields():
    w = parse_window(SAMPLE)
    assert w["comp_cyc_per_frame"] == 460800.0
    assert w["bucket_entries"] == 3600
    assert w["blend_draws"] == 0

def test_cycpx_clean_pass():
    r = tilemap_cycpx(parse_window(SAMPLE))
    # 460800 / (3*320*240=230400) = 2.0
    assert abs(r["cycpx"] - 2.0) < 0.01
    assert r["verdict"] == "PASS"
    assert r["grid_path_live"] is True   # BLEND=0 -> parallax went through the grid, not per-tile BLEND

def test_ambiguous_band_flags_escalation():
    amb = SAMPLE.replace("460800", "691200")  # 691200/230400 = 3.0 -> AMBIGUOUS
    r = tilemap_cycpx(parse_window(amb))
    assert r["verdict"] == "AMBIGUOUS"

def test_grid_path_not_live_when_blend_present():
    replay = SAMPLE.replace("BLEND=0", "BLEND=1500")
    r = tilemap_cycpx(parse_window(replay))
    assert r["grid_path_live"] is False   # per-tile BLEND -> measuring a fallback/replay scene, invalid
```

- [ ] **Step 2: Run test to verify it fails.**

  Run: `python3 scripts/perf/test_derive_tilemap_cycpx.py` (or `python3 -m pytest scripts/perf/test_derive_tilemap_cycpx.py -v` if pytest is present).
  Expected: FAIL — `ModuleNotFoundError`/`ImportError: cannot import name 'parse_window'`.

- [ ] **Step 3: Write minimal implementation.** Create `scripts/perf/derive_tilemap_cycpx.py`:

```python
#!/usr/bin/env python3
"""Derive map-119 tilemap cyc/px from captured [blitter *] banners (Stage 5 Phase 1).

No RTL / no device: reuses the comp-pipeline cycle counter (C_STATUS+4) already
published every frame in [blitter hwperf], divided by the composited tilemap pixel
count reconstructed two independent ways (framebuffer-area and bucket-entries).
"""
import re

FB_W, FB_H, CELL = 320, 240, 8  # 320x240 frame; grid cells are 8px (Stage 3b B3)

def _num(pat, text, cast=float, default=None):
    m = re.search(pat, text)
    if not m:
        if default is not None:
            return default
        raise ValueError(f"pattern not found: {pat!r}")
    return cast(m.group(1))

def parse_window(text):
    return {
        "comp_cyc_per_frame": _num(r"\((\d+)\s*cyc/frame\)", text, float),
        "bucket_entries":     _num(r"\bentries=(\d+)", text, int),
        "blend_draws":        _num(r"blend NONE=\d+ BLEND=(\d+)", text, int),
        "fb_layers":          _num(r"tilemap_layers=(\d+)", text, int, default=3),
    }

def tilemap_cycpx(w):
    px_fb = FB_W * FB_H * w["fb_layers"]          # estimate A: full-frame per layer
    px_entries = w["bucket_entries"] * CELL * CELL # estimate B: composited grid cells
    px = px_fb if px_fb > 0 else px_entries
    cycpx = w["comp_cyc_per_frame"] / px if px else float("inf")
    div = (abs(px_fb - px_entries) / max(px_fb, px_entries) * 100.0) if max(px_fb, px_entries) else 0.0
    grid_live = w["blend_draws"] == 0             # per-tile BLEND == replay/fallback, not the grid path
    if 2.7 <= cycpx <= 3.3:
        verdict = "AMBIGUOUS"
    elif cycpx <= 3.0:
        verdict = "PASS"
    else:
        verdict = "FAIL"
    return {"cycpx": cycpx, "px_est_fb": px_fb, "px_est_entries": px_entries,
            "divergence_pct": div, "grid_path_live": grid_live, "verdict": verdict}

if __name__ == "__main__":
    import sys
    text = sys.stdin.read()
    r = tilemap_cycpx(parse_window(text))
    print(f"tilemap cyc/px = {r['cycpx']:.2f}  verdict={r['verdict']}  "
          f"grid_path_live={r['grid_path_live']}  "
          f"px(fb={r['px_est_fb']} entries={r['px_est_entries']} "
          f"div={r['divergence_pct']:.0f}%)")
```

- [ ] **Step 4: Run test to verify it passes.**

  Run: `python3 scripts/perf/test_derive_tilemap_cycpx.py` (add a `if __name__ ...` runner that calls each `test_*` and prints OK, or use pytest).
  Expected: all four tests PASS.

- [ ] **Step 5: Commit.**
  ```bash
  git add scripts/perf/derive_tilemap_cycpx.py scripts/perf/test_derive_tilemap_cycpx.py
  git commit -m "perf(stage5): tilemap cyc/px derivation tool + tests (Phase 1)"
  ```

---

### Task 2: map-119 reproducible capture harness (device)

A Bash harness that boots the deployed engine safely (one instance), drives the hero to a **fixed** map-119 destination, captures a standing window, then injects a **fixed** held direction and captures a moving window — all banners tee'd to a dated log. This is the reproducibility foundation; two runs at the same spot must agree within window jitter.

**Files:**
- Create: `scripts/perf/capture_map119.sh`
- Create: `scripts/perf/README-stage5.md` (records the fixed teleport destination + held direction, so future A/B is byte-reproducible — resolves spec §7 open item)

**Interfaces:**
- Consumes: the deployed engine (no build), the safe-launch recipe, the lua-console FIFO + joypad-inject recipes.
- Produces: `/media/fat/logs/Solarus/stage5-<state>.log` on device (pulled to `docs/superpowers/data/stage5/` locally); consumed by T3.

- [ ] **Step 1: Author the harness.** Create `scripts/perf/capture_map119.sh`. It must (comments cite the recipe memories):

```bash
#!/usr/bin/env bash
# Stage 5 Phase 2 — reproducible map-119 standing+moving capture.
# Recipes: safe-launch (solarus-two-engines-wedge-launch-recipe),
#          lua-console teleport (solarus-84-luaconsole-teleport-repro),
#          joypad inject (solarus-joypad-inject-hw: devmem 0x3A000008; dpad down=0x004).
set -euo pipefail
HOST="${HOST:-root@192.168.20.81}"
GAMEDIR=/media/fat/games/Solarus
LOGDIR=/media/fat/logs/Solarus
MAP119_DEST="${MAP119_DEST:-<MAP_ID>:<DEST_NAME>}"   # FIXED, recorded in README-stage5.md
HELD_DIR_BIT="${HELD_DIR_BIT:-0x004}"                # dpad down; FIXED
WINDOW_SECS="${WINDOW_SECS:-8}"                       # >= 3 * 60-frame windows

ssh "$HOST" bash -s <<REMOTE
set -e
mkdir -p "$LOGDIR"
# 1) one instance only: kill any running engine, empty the s0, ensure diag on
kill -9 \$(pidof solarus-run) 2>/dev/null || true
: > /media/fat/config/Solarus.s0
grep -q SOLARUS_BLITTER_DIAG "$GAMEDIR/diag.env" 2>/dev/null || echo 'SOLARUS_BLITTER_DIAG=1' >> "$GAMEDIR/diag.env"
# 2) load core, launch ONE engine with the S0_FILE override, FIFO for lua-console
FIFO=/tmp/sol_luac; rm -f \$FIFO; mkfifo \$FIFO
setsid sh -c "cd $GAMEDIR && S0_FILE=/tmp/sol_pick sh solarus_run.sh -lua-console=yes < \$FIFO > $LOGDIR/stage5-boot.log 2>&1" </dev/null &
sleep 12   # boot + quest_manager settle
# 3) teleport to the fixed map-119 destination, let it settle
printf 'hero:teleport("%s")\n' "${MAP119_DEST%%:*}" > \$FIFO || true   # console form per repro memory
sleep 4
# 4) STANDING window
: > $LOGDIR/stage5-standing.log
timeout ${WINDOW_SECS}s sh -c "tail -f $LOGDIR/stage5-boot.log | grep -E '\[blitter (timing|hwperf|p0|engcpp|resident)\]'" >> $LOGDIR/stage5-standing.log || true
# 5) MOVING window: hold the fixed direction via devmem, capture, then release
: > $LOGDIR/stage5-moving.log
( for i in \$(seq 1 200); do busybox devmem 0x3A000008 32 $HELD_DIR_BIT; sleep 0.05; done ) &
HOLD=\$!
timeout ${WINDOW_SECS}s sh -c "tail -f $LOGDIR/stage5-boot.log | grep -E '\[blitter (timing|hwperf|p0|engcpp|resident)\]'" >> $LOGDIR/stage5-moving.log || true
kill \$HOLD 2>/dev/null || true; busybox devmem 0x3A000008 32 0x000
echo "capture done"
REMOTE

mkdir -p docs/superpowers/data/stage5
for s in boot standing moving; do
  scp "$HOST:$LOGDIR/stage5-$s.log" "docs/superpowers/data/stage5/stage5-$s.log"
done
echo "pulled logs to docs/superpowers/data/stage5/"
```

- [ ] **Step 2: Resolve + record the fixed spot.** Run the harness once with a candidate `MAP119_DEST` (find map 119's id + a destination name from the quest data via the teleport repro memory). Confirm the boot log shows the engine reaching map 119 (`Opening map 119` / parallax layers in `[blitter resident]`). Write the exact `MAP119_DEST` + `HELD_DIR_BIT` into `scripts/perf/README-stage5.md` with a one-line rationale, so all future A/B uses the identical spot.

  Run: `HOST=root@192.168.20.81 MAP119_DEST=<resolved> bash scripts/perf/capture_map119.sh`
  Expected: `docs/superpowers/data/stage5/stage5-{standing,moving}.log` exist and each contain ≥3 `[blitter timing]` lines.

- [ ] **Step 3: Reproducibility check.** Run the harness a second time at the same spot. Parse both standing logs with the T1 tool; the two `fps` and `comp_cyc_per_frame` values must agree within window jitter (fps within ±1.5, cyc/frame within ±10%). If they don't, the spot isn't stable — pick a less dynamic destination and re-record before proceeding.

  Run: `for f in docs/superpowers/data/stage5/stage5-standing.log; do grep -m1 hwperf $f; done` twice across two captures; compare.
  Expected: agreement within the stated bounds.

- [ ] **Step 4: Commit.**
  ```bash
  git add scripts/perf/capture_map119.sh scripts/perf/README-stage5.md docs/superpowers/data/stage5/
  git commit -m "perf(stage5): reproducible map-119 capture harness + fixed spot (Phase 2)"
  ```

---

### Task 3: Baseline capture + committed decision doc (Phase 2 close + Phase 3)

Run the harness against today's HEAD, derive the numbers, apply the deterministic fork rule, and commit the verdict **before** any lever code exists.

**Files:**
- Create: `docs/superpowers/2026-07-21-stage5-decision.md`
- Use: `docs/superpowers/data/stage5/stage5-{standing,moving}.log` (from T2)

**Interfaces:**
- Consumes: T1 `tilemap_cycpx`, T2 logs.
- Produces: a committed verdict naming the limiter + the ONE selected lever + its expected magnitude — consumed by T4 to pick its variant.

- [ ] **Step 1: Derive the numbers.**

  Run: `python3 scripts/perf/derive_tilemap_cycpx.py < docs/superpowers/data/stage5/stage5-standing.log`
  Also extract, from both logs, per state: `fps`, `period`, `fabric_hw ms`, `comp ms`, `A9 ms`, `[blitter p0]` BLEND count, `[blitter engcpp]` entities/hero split, and the `[blitter resident]` grid/fatal fields.
  Expected: a `cycpx` + `verdict` + `grid_path_live=True` (if False, STOP — the capture measured a replay/fallback scene; revisit the spot).

- [ ] **Step 2: Apply the fork rule and write the decision doc.** Create `docs/superpowers/2026-07-21-stage5-decision.md` with: (a) the raw standing+moving banner lines pasted verbatim; (b) the derived `tilemap cyc/px` vs the 3.0 target; (c) the verdict from this table (from spec §3 Phase 3):

  | Signature (standing) | Limiter | Selected lever |
  |---|---|---|
  | `fabric_hw_ms > a9_ms` AND still fabric-saturated | **Fabric** | **4-RTL**: `tilemap_unit` grid-walk prefetch (burst cells / wider linebuf / skip-transparent-run) |
  | `a9_ms > fabric_hw_ms` AND `p0 BLEND==0` (grid live) | **A9** | **4-HOST**: `engcpp/entities` dominant → enemy per-update lever; `emit` dominant → emit-walk collapse |
  | fabric ≈ A9, both under budget, fps ~60 | **Neither** | **No lever** — close stage as migration validation; name the next-frontier scene |

  (d) the ONE selected lever with its expected fps/metric magnitude and the exact `SOLARUS_<LEVER>` flag name it will use in T4.

- [ ] **Step 3: Commit the decision (gate before any lever code).**
  ```bash
  git add docs/superpowers/2026-07-21-stage5-decision.md docs/superpowers/data/stage5/
  git commit -m "perf(stage5): committed map-119 baseline + limiter decision (Phase 3)"
  ```

---

### Task 4: Land the selected lever (decision-gated — execute EXACTLY ONE variant)

Read `docs/superpowers/2026-07-21-stage5-decision.md`. Execute **4-HOST** if it names a host lever, **4-RTL** if it names the tilemap-prefetch lever, or **skip Task 4 entirely** (go to Task 5) if the verdict is "No lever." The shared scaffolding (new default-off flag, A/B via the T2 harness, operator gate) is identical; only the lever body + its build/test chain differ.

**Interfaces (both variants):**
- Consumes: T3 decision doc (lever + flag name), T2 harness (for A/B), T1 tool (for the cyc/px delta).
- Produces: a gated, HW-validated lever; flag-off reproduces the T3 baseline.

#### Variant 4-HOST (engine/renderer lever; no RTL)

The decision doc names either the **enemy per-update** lever (leading candidate: skip `quadtree->move` in `Entity::notify_position_changed` when the entity's bounding box did not cross a spatial-grid cell boundary — memory `solarus-enemy-per-update-cost-simd`) or the **emit-walk** lever. Steps below are written for the enemy candidate; if the doc names the emit lever, substitute the emit hot-path the `[blitter engcpp]`/`[blitter timing] emit` split identifies, keeping the identical flag/test/A-B structure.

- [ ] **H-1: Add the gated flag (default-off, true no-op).** In `patches/mister/mister_blitter_renderer.cpp` ctor parse block (near the other `mister_flag_*`/`std::getenv` reads), add:
  ```cpp
  // [Stage 5 lever] default-OFF; =0 must reproduce the Stage 5 baseline exactly.
  self->d->stage5_lever = (std::getenv("SOLARUS_<LEVER>") != nullptr);
  ```
  and the `bool stage5_lever = false;` member. (For an engine-side lever in `work/solarus`, gate via the existing `build_engine.sh` injection pattern used by `SOLARUS_IDLEPARK` — a `getenv` check bracketing the hot path — rather than the renderer, following that precedent exactly.)

- [ ] **H-2: Write the host test for the pure decision.** Add a case to the host suite (`tests/`, registered in `tests/run_tests.sh`) that models the lever's pure predicate — e.g. "bbox stayed within one cell ⇒ skip predicate true; crossed a cell boundary ⇒ false" — asserting the skip is taken iff behavior is provably unchanged. Show the actual assertions (cell size, two bbox positions, expected bool), not a description.

- [ ] **H-3: Run the host test; verify it fails, then implement the minimal gated change, then passes.**
  Run: `bash tests/run_tests.sh` → FAIL (predicate undefined) → implement the guarded skip behind `stage5_lever` → `bash tests/run_tests.sh` → PASS.

- [ ] **H-4: Type-check + armhf build.**
  Run the `-std=c++11` type-check (Global Constraints) → exits 0.
  Run: `bash scripts/build_engine.sh` (Docker) → produces `build/armhf/{solarus-run,libsolarus.so.1.6.5}`, 0 `error:`.

- [ ] **H-5: Deploy engine-only + HW A/B on the fixed map-119 spot.**
  Refresh `deploy/` from `build/armhf`, `./deploy.py --no-rbf`, verify sha1 on device.
  Capture flag-OFF then flag-ON with the T2 harness (set `SOLARUS_<LEVER>=1` in `diag.env` for the ON leg). Assert: OFF reproduces the T3 baseline (true no-op); ON moves the predicted metric (enemy `entities` ms down / fps up) with no other banner regressing.

- [ ] **H-6: Commit.**
  ```bash
  git add -A
  git commit -m "perf(stage5): <lever> behind SOLARUS_<LEVER> (default-off); HW A/B <delta>"
  ```

#### Variant 4-RTL (tilemap-prefetch lever; new RBF)

The decision doc names a `tilemap_unit`/grid-walk prefetch change (burst multiple cells, wider linebuf, or skip-transparent-run). §7: **prefetch, never clock.**

- [ ] **R-1: Add the gated host emit path + flag.** Behind `SOLARUS_<LEVER>` (default-off), have the host emit the new prefetch-friendly descriptor variant; `=0` emits the current descriptor so the current RBF path is byte-identical.

- [ ] **R-2: fpga/sim bit-exact grid-walk vs golden.** Add/extend a `fpga/sim` testbench that runs the prefetch grid-walk and structural-diffs the framebuffer against the current grid-walk golden on a map-119-shaped grid — the #24 60/60 bit-exact pattern. Show the tb wiring + the diff assertion.
  Run the sim → PASS (bit-exact; prefetch changes throughput, not pixels).

- [ ] **R-3: Quartus build + timing closure + seed sweep (HARD gate).**
  Build the RBF; run STA; sweep seeds until one closes **positive** slack. If none closes, STOP: record "fabric lever blocked on timing" in the decision doc and fall back to closing the stage without the RTL lever (or re-scope to a cheaper prefetch). Do not ship a negative-slack RBF.

- [ ] **R-4: Deploy engine+RBF + HW A/B on the fixed map-119 spot.**
  Deploy the new `Solarus_YYYYMMDD.rbf` + engine; verify checksums + lib closure.
  Capture flag-OFF (current path) then flag-ON with the T2 harness. Assert: OFF reproduces the T3 baseline; ON shows `tilemap cyc/px` DOWN (T1 tool) and fps/period improved, no correctness regression.

- [ ] **R-5: Commit.**
  ```bash
  git add -A
  git commit -m "perf(stage5): tilemap grid-walk prefetch behind SOLARUS_<LEVER> (default-off); cyc/px <before>-><after>"
  ```

---

### Task 5: HW validation doc + PR (operator-gated)

Behavior-neutral + "improved" are claims until the operator confirms on device. **The visual gate is the operator's eyes**, per the repo rule.

**Files:**
- Create: `docs/superpowers/2026-07-21-stage5-hw-validation.md`

- [ ] **Step 1: Operator visual gate.** With the lever ON (or, for the No-lever verdict, just the current build), the operator confirms on map 119: parallax renders correctly standing + moving, one transition in/out of map 119 is clean, no new `[MiSTer blitter]`/engine errors, frame counter (`0x3A000000`) advancing, audio flowing. For a host lever, additionally: enemy movement/AI unchanged at normal speed (behavior-neutral).

- [ ] **Step 2: Record the result.** Write `docs/superpowers/2026-07-21-stage5-hw-validation.md`: the baseline numbers, the derived cyc/px vs 3.0, the limiter verdict, the lever + its measured A/B delta (or "No lever — migration validated"), and the operator confirmation. Commit.

- [ ] **Step 3: Open the PR.** `feat/stage5-perf-rebaseline` → master, summarizing: baseline, verdict, lever (or none), the measured delta, and the operator sign-off. Do NOT mark Stage 5 done until the operator confirms.

---

## Self-Review

**Spec coverage:** §1 goal/non-goals → T3 verdict + one-lever constraint ✓; §2 why-map-119 → T2 scene + T1 grid-live guard ✓; §3 Phase 1 derivation (host-only, ±0.3 escalation) → T1 (`AMBIGUOUS` band = 2.7–3.3) ✓; §3 Phase 2 capture (standing+moving, self-driven, ≥3 windows, safe-launch) → T2 ✓; §3 Phase 3 fork rule + commit-before-lever → T3 ✓; §3 Phase 4 land+validate (gated default-off, host/RTL branches, HW A/B) → T4 4-HOST/4-RTL ✓; §4 component boundaries → one file/responsibility per task ✓; §5 testing (synthetic-fixture derivation, reproducibility check, bit-exact sim, flag-off=baseline) → T1 S1 / T2 S3 / R-2 / H-5+R-4 ✓; §6 risks (ambiguous cyc/px, fallback-scene, two-engines wedge, timing miss, self-declared visual) → T1 verdict band / T1 grid_path_live / T2 safe-launch / R-3 gate / T5 operator ✓; §7 open items (fixed spot, derivation-vs-engine-line, A9 sub-lever) → T2 S2 records the spot / T1 is pure host post-process / T3 selects the sub-lever ✓.

**Placeholder scan:** No TBD/TODO. `<MAP_ID>:<DEST_NAME>`, `<LEVER>`, `<delta>` are explicitly resolved-at-runtime values (the fixed spot is discovered in T2 S2 and recorded; the flag name + lever are named in the T3 decision doc) — each carries the exact step that fills it, not a vague "fill in later." Task 4's two variants are concrete and execute-exactly-one by the committed T3 verdict — this is a genuine data-fork the spec defined, not an unresolved placeholder.

**Type consistency:** `parse_window`/`tilemap_cycpx` signatures + return keys (`cycpx`, `verdict`, `grid_path_live`, `comp_cyc_per_frame`, `bucket_entries`, `blend_draws`) are defined in T1 and consumed unchanged in T2 S3 / T3 S1. `SOLARUS_<LEVER>` + `stage5_lever` are named once and reused across H-1/H-5 and R-1/R-4. Banner tokens grepped in T2 (`[blitter timing|hwperf|p0|engcpp|resident]`) match the real format strings confirmed at renderer ~3448–3487. The 2.7–3.3 AMBIGUOUS band matches the spec's ±0.3 escalation clause.
