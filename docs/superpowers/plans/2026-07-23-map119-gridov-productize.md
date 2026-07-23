# Map 119 GRIDOV productization — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **Tasks 1–3 are code (subagent-implementable). Tasks 4–5 are OPERATOR/HW tasks — driven on the device by the human operator, not a subagent.**

**Goal:** Ship `SOLARUS_GRIDOV` default-on so map 119's overlapping parallax tiles decompose onto the coalesced grid path instead of the uncoalesced resident tile-list replay, recovering the sized ~5–7 ms, validated pixel-correct and measured against 16.7 ms/60 fps.

**Architecture:** Three engine-only code changes — (1) cherry-pick the host-side SDRAM-source-mux fix so gridded tiles read the atlas from SDRAM not DDR3 (else garbage), (2) extend the GRIDSTATS instrument to emit per decomposed sub-layer so Σ coalesced runs is measurable, (3) flip GRIDOV from env-presence-gated to `mister_flag_default_on`, keeping every graceful replay fallback — then two operator HW tasks: pixel-correctness validation across the quest and an fps A/B against the 60 fps wall.

**Tech Stack:** C++17 renderer (`patches/mister/mister_blitter_renderer.cpp`, a whole-file copy edited directly — NOT in the patch series), C host emitter/ref (`patches/mister/blitter/*.c,*.h`), host test suite (`tests/run_tests.sh`), armhf cross-build via Docker, device `root@192.168.20.81`.

## Global Constraints

- **Engine-only, no RBF rebuild.** The SDRAM mux is a host-side emitter fix; the fabric already carries the per-command `BLT_F_SRC_SDRAM` mux. Ships on the current `Solarus_20260723.rbf`. Deploy `--no-rbf`.
- **Renderer is a whole-file copy** (`mister_blitter_renderer.cpp`) — edit it directly; it is NOT in `patches/series/`, nothing to regenerate.
- **Build recipe:** host-apply the series then compile-only in Docker: `scripts/apply_patch_series.sh` then `SOLARUS_SKIP_APPLY=1 scripts/docker_run.sh scripts/build_engine.sh`. Renderer changes are NOT host-unit-tested (the suite models emitter/ref logic, does not compile the renderer) — verify renderer edits with the native type-check (below) plus the on-device dump.
- **Native type-check** (mandatory two `-D` flags, or it type-checks almost nothing): `g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO -I patches/mister -I patches/mister/blitter -I work/solarus/include -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp`.
- **Deploy:** refresh `deploy/` from `build/armhf` first (`deploy.py` ships from `deploy/`, not `build/armhf`), then `./deploy.py --no-rbf`.
- **Keep every graceful fallback** in `res_arm_()` (tokenless / bounds / decompose-declined / GRID_BUF-full / alloc-fail → resident replay) so worst case degrades to today's behavior, never garbage or crash.
- **No self-declared visual validation** (`solarus-no-self-declared-visual-validation`): the operator's eyes confirm pixel correctness (Task 4). Never declare a frame correct from a screenshot I took.
- **Single-engine discipline:** every device launch first kills `quest_manager.sh`/`core_watch.sh`/`solarus_daemon.sh`/`solarus-run` (two engines wedge the host).

---

### Task 1: Land the SDRAM-source-mux prerequisite

**Files:**
- Cherry-pick: `6be6a28` (modifies `patches/mister/blitter/blt_emitter.c` — `blt_grid_list` gains the SDRAM-vs-DDR source mux). Verified host-only, 1 file, applies cleanly on this branch.
- Test: `tests/blt_sdram_vram_test.c` (exercises `blt_grid_list`'s SDRAM source), full suite via `tests/run_tests.sh`.

**Interfaces:**
- Consumes: nothing from earlier tasks (first task).
- Produces: a mux-correct `blt_grid_list` so that ANY gridded/decomposed tile (Tasks 2–5) reads its source atlas from staged SDRAM (`src_off = tex.sdram_off`, `BLT_F_SRC_SDRAM` set) instead of the DDR3 heap.

- [ ] **Step 1: Cherry-pick the fix**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
git cherry-pick 6be6a28
```
Expected: clean cherry-pick, one file changed (`patches/mister/blitter/blt_emitter.c`). If it conflicts, resolve minimally against `blt_grid_list` only (do NOT pull in unrelated master changes).

- [ ] **Step 2: Confirm the mux is present in source**

```bash
grep -n "use_sdram\|BLT_F_SRC_SDRAM" patches/mister/blitter/blt_emitter.c | grep -A2 -B2 grid || \
  grep -n "use_sdram" patches/mister/blitter/blt_emitter.c
```
Expected: the `blt_grid_list` body now computes `use_sdram = e->sdram_src && tex.sdram_off != BLT_ALLOC_FAIL` and sets `BLT_F_SRC_SDRAM` (mirrors `tl_emit_header`).

- [ ] **Step 3: Run the host suite**

```bash
bash tests/run_tests.sh
```
Expected: all tests PASS, including `blt_sdram_vram_test` (the grid-list SDRAM source case). No test regresses.

- [ ] **Step 4: Commit is already made by cherry-pick** — verify

```bash
git log --oneline -1
```
Expected: the top commit is `6be6a28`'s message (`fix(blitter): grid emitter missing SDRAM source mux — door-roof garbage`), now on this branch.

---

### Task 2: Per-sub-layer GRIDSTATS instrumentation

**Problem this fixes:** the existing GRIDSTATS emit (`mister_blitter_renderer.cpp:3326-3343`) runs on the *pre-decompose* overlapping grid produced by `blt_grid_build_ov`. When GRIDOV decomposes an overlapping bucket into K sub-layers, the fabric executes those K grids — NOT the pre-decompose grid — so the emitted `runs` count is not the real fabric grid-blit count. This task moves the emit so it reports the grid(s) the fabric actually walks: one line for a non-overlapping bucket, K lines for a decomposed bucket. Σ`runs` across all lines then equals the coalesced grid-blit count to compare against today's ~11,764 resident blits.

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` — the `if (d->tilemapch ...)` grid-build block, `res_arm_()`, lines `3298-3436`.

**Interfaces:**
- Consumes: `blt_grid_stats()` / `blt_grid_stats_t` (`patches/mister/blitter/grid_stats.h`), `mister_camera_x/y()`, `FB_W`/`FB_H`, `blt_grid_cell_t`, the `g_gridstats_on` global — all already in scope at this site.
- Produces: `GRIDSTATS ... sub=<s>/<K> ... runs=<r>` lines (one per grid the fabric walks) parsed by `scripts/perf/comp_attribution.py::parse_gridstats` (which reads `nonempty=`/`empty=`/`runs=` and is unaffected by the new `sub=` token).

- [ ] **Step 1: Add a window-and-emit lambda before the bucket loop**

Insert immediately after the scratch-vector declarations at line 3304 (after `std::vector<int> sublayer;`), before `for (auto& b : d->res_static_buckets) {`:

```cpp
    // [SOLARUS_GRIDSTATS] Emit one GRIDSTATS line for a BUILT grid over bucket b's
    // visible map-cell window. Called once per grid the FABRIC actually walks:
    // sub=0/1 for a non-overlapping bucket, sub=s/K for each decomposed sub-layer.
    // Reads only globals + args (captures nothing).
    auto gridstats_emit = [](const blt_grid_cell_t* cells, uint16_t gw, uint16_t gh,
                             int layer, int r, int sub, int nsub) {
      const int camx = mister_camera_x(), camy = mister_camera_y();
      const int bx = (r <= 1) ? -camx : camx / r - camx;
      const int by = (r <= 1) ? -camy : camy / r - camy;
      auto clampc = [](int v, int hi){ return v < 0 ? 0 : (v > hi ? hi : v); };
      const int cx0 = clampc((-bx) / 8, gw), cx1 = clampc((FB_W - bx + 7) / 8, gw);
      const int cy0 = clampc((-by) / 8, gh), cy1 = clampc((FB_H - by + 7) / 8, gh);
      blt_grid_stats_t st;
      blt_grid_stats(cells, gw, (uint16_t)cx0, (uint16_t)cx1,
                     (uint16_t)cy0, (uint16_t)cy1, &st);
      std::fprintf(stderr,
          "GRIDSTATS layer=%d sub=%d/%d ratio=%d win=%d,%d-%d,%d "
          "nonempty=%u empty=%u runs=%u hist=",
          layer, sub, nsub, r, cx0, cy0, cx1, cy1,
          st.nonempty_cells, st.empty_cells, st.runs);
      for (int i = 1; i <= 16; ++i)
        std::fprintf(stderr, "%u%s", st.run_hist[i], i < 16 ? "," : "\n");
    };
```

- [ ] **Step 2: Remove the pre-decompose inline emit**

Delete the entire `if (g_gridstats_on) { ... }` block at lines 3326-3343 (the one that emits right after `blt_grid_build_ov`, before the `if (overlapped)` branch). That grid is the pre-decompose grid and is misleading for decomposed buckets.

- [ ] **Step 3: Emit per sub-layer in the decompose K-loop**

In the `for (int s = 0; s < K; ++s)` loop, immediately after the `std::memcpy(... d->grid_scratch.data() ...)` that copies sub-layer `s` into GRID_BUF (line 3390-3391, before `b.grid_off[s] = off;`), add:

```cpp
          if (g_gridstats_on)
            gridstats_emit(d->grid_scratch.data(), gw, gh, b.layer, b.scroll_ratio, s, K);
```
(`d->grid_scratch` still holds sub-layer `s`'s freshly-built grid at this point — the next iteration's `blt_grid_build` overwrites it.)

- [ ] **Step 4: Emit for the single-grid (non-overlapping) path**

After the single-grid success line 3435 (`b.grid_off[0] = off; b.grid_w = gw; ... b.grid_ok = true;`), add:

```cpp
      if (g_gridstats_on)
        gridstats_emit(d->grid_scratch.data(), gw, gh, b.layer, b.scroll_ratio, 0, 1);
```
(On the non-overlap path `d->grid_scratch` still holds the grid `blt_grid_build_ov` wrote — it was not overwritten.)

- [ ] **Step 5: Type-check the renderer**

```bash
g++ -fsyntax-only -std=c++17 -DMISTER_NATIVE_VIDEO -DMISTER_NATIVE_AUDIO \
  -I patches/mister -I patches/mister/blitter -I work/solarus/include \
  -I build/armhf/include -I work/solarus/libraries/win32/mingw32/include \
  $(sdl2-config --cflags) patches/mister/mister_blitter_renderer.cpp
```
Expected: exit 0, no errors. (Both `-D` flags are mandatory — most of the renderer is under `#ifdef MISTER_NATIVE_VIDEO`.)

- [ ] **Step 6: Confirm the parser tolerates the new token**

```bash
printf 'GRIDSTATS layer=2 sub=0/3 ratio=2 win=1,2-3,4 nonempty=5 empty=6 runs=7 hist=0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0\n' > /tmp/gs_probe.log
python3 - <<'PY'
import importlib.util
spec = importlib.util.spec_from_file_location("ca", "scripts/perf/comp_attribution.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.parse_gridstats(open("/tmp/gs_probe.log")))
PY
```
Expected: `(6, 7, 5)` (empty, runs, nonempty) — the `sub=0/3` token is ignored, no exception.

- [ ] **Step 7: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp
git commit -m "perf(map119): GRIDSTATS emits per decomposed sub-layer

The pre-decompose grid GRIDSTATS reported is not what the fabric walks
when GRIDOV splits an overlapping bucket into K sub-layers. Emit one line
per grid the fabric actually executes (sub=0/1 non-overlap, sub=s/K per
decomposed sub-layer) so summed runs = the real coalesced grid-blit count.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Flip GRIDOV to a validated default-on

**Files:**
- Modify: `patches/mister/mister_blitter_renderer.cpp` — the ctor parse at line 2512, the adjacent comment 2510-2511, the pre-parse default at line 810.
- Modify: `CLAUDE.md` and any doc that states GRIDOV is default-off (grep-driven).

**Interfaces:**
- Consumes: `mister_flag_default_on()` (line 100 — returns true unless the env value starts with `'0'`).
- Produces: `d->gridov == true` by default, so overlapping buckets decompose onto the grid path quest-wide; `SOLARUS_GRIDOV=0` forces the legacy replay.

- [ ] **Step 1: Flip the ctor parse**

Line 2512, replace:
```cpp
  self->d->gridov = (std::getenv("SOLARUS_GRIDOV") != nullptr);
```
with:
```cpp
  self->d->gridov = mister_flag_default_on("SOLARUS_GRIDOV");
```

- [ ] **Step 2: Update the adjacent comment**

Replace the "opt-in lever, not a validated default" comment at lines 2510-2511 with a note that GRIDOV is now a validated default-on channel (overlapping static buckets decompose into ≤`BLT_GRIDOV_MAXK` grid sub-layers; `=0` forces replay), citing this plan/spec date `2026-07-23`.

- [ ] **Step 3: Update the pre-parse default comment**

Line 810, update the `bool gridov = false;` comment from "real default set in the ctor parse (std::getenv presence)" to "real default set ON in the ctor parse (mister_flag_default_on)".

- [ ] **Step 4: Sync the docs**

```bash
grep -rn "SOLARUS_GRIDOV\|GRIDOV" CLAUDE.md docs/ | grep -i "off\|opt-in\|default"
```
For each hit that states GRIDOV is default-off / opt-in, update it to default-on (with `=0` as the escape hatch), referencing this productization. If CLAUDE.md's tilemap-channel note describes the overlap→replay fallback as unconditional, amend it to "replay only when GRIDOV is off or decomposition declines (K>`BLT_GRIDOV_MAXK`/GRID_BUF-full)".

- [ ] **Step 5: Type-check the renderer**

Run the native type-check command from Global Constraints. Expected: exit 0.

- [ ] **Step 6: Commit**

```bash
git add patches/mister/mister_blitter_renderer.cpp CLAUDE.md docs/
git commit -m "feat(map119): SOLARUS_GRIDOV default-on (validated coalescing path)

Overlapping static buckets (map119 parallax, door-roofs, interior walls)
now decompose onto the coalesced grid path by default instead of
uncoalesced resident replay. SOLARUS_GRIDOV=0 forces legacy replay. All
graceful fallbacks retained: tokenless / bounds / K>MAXK / GRID_BUF-full
-> replay, never garbage. Ships on Solarus_20260723.rbf (host-only).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: [OPERATOR/HW] Build, deploy, and pixel-correctness validation

> Not subagent-implementable — build + device + the operator's eyes. Depends on Tasks 1–3 committed. Single-engine discipline throughout.

**Files:** none edited. Uses `scripts/apply_patch_series.sh`, `scripts/docker_run.sh`, `scripts/build_engine.sh`, `deploy.py`, `scripts/perf/stage5_device_launch.sh`.

- [ ] **Step 1: Build the engine**

```bash
scripts/apply_patch_series.sh
SOLARUS_SKIP_APPLY=1 scripts/docker_run.sh scripts/build_engine.sh
```
Verify freshness and that the mux + gridstats code compiled in:
```bash
ls -l build/armhf/libsolarus.so.1.6.5           # mtime = now
strings build/armhf/libsolarus.so.1.6.5 | grep -c "GRIDSTATS layer"   # expect >= 1
```

- [ ] **Step 2: Deploy engine-only**

```bash
cp build/armhf/solarus-run deploy/solarus-run
cp build/armhf/libsolarus.so.1.6.5 deploy/libs/libsolarus.so.1.6.5
./deploy.py --no-rbf
```
Expected: `deploy.py`'s own sha1 + link-probe post-checks pass.

- [ ] **Step 3: Launch map 119 with GRIDOV on by default (single engine)**

Launch via the detached single-engine recipe (kill daemons + `solarus-run` first), start `save1.dat`, teleport to the fixed spot `("119","from_dungeon_10")`, per `scripts/perf/stage5_device_launch.sh` and the runbook `docs/superpowers/plans/2026-07-23-map119-comp-attribution-runbook.md` §2–3. Confirm `CURMAP=119`.

- [ ] **Step 4: Operator validates pixels (the gate)**

The operator visually confirms GRIDOV-on is correct on each scene below (teleport between them over the held FIFO). Do NOT self-declare from a screenshot.

| scene | teleport / how | pass criterion |
|---|---|---|
| map 119 parallax | `("119","from_dungeon_10")` | parallax layers correct, no garbage tiles |
| door-roofs | a cave/dungeon door map (e.g. map 4 Tom's Cave, pattern 901) | roof tiles correct (the `6be6a28` case) |
| interior walls | any dungeon interior with layered wall decoration | overlapping wall tiles composite correctly |
| plain overworld | a non-parallax overworld map | no regression vs today |

- [ ] **Step 5: Record the verdict**

If any scene shows garbage → **STOP**, this is a blocker for default-on (proceed to Task 5's NO-GO/revert path). If all scenes are clean, record operator PASS and proceed to Task 5's fps measurement.

---

### Task 5: [OPERATOR/HW] fps A/B, bgfill combination, and decision gate

> Not subagent-implementable — device capture + analysis + decision. Depends on Task 4 PASS. Same ship RBF, single-engine discipline.

**Files:** none edited. Uses `scripts/perf/bgfillprobe_ab.sh` (A/B template), `scripts/perf/comp_attribution.py` (Σruns cross-check).

- [ ] **Step 1: Capture the decomposition metrics (Task 2 instrument)**

Standing map 119, launch with `SOLARUS_GRIDSTATS=1` (GRIDOV already default-on). Pull the log; sum `runs` and `nonempty` across all `GRIDSTATS ... sub=` lines, and read the `[blitter gridov] layer=.. K=.. bytes=..` lines. Also read the residual resident replay count from the `[blitter diag]` `tile_blits` banner (buckets that still fell back).

Deliverables:
- **Σ grid runs + residual resident tile_blits (GRIDOV on)** vs **11,764 (baseline)** — the coalescing win.
- **Σ GRID_BUF bytes** vs **2 MiB (`GRID_BUF_BYTES`)** — the budget cost. If any bucket logs `GRID_BUF full mid-decompose`, note that decomposition is being starved (a GRID_BUF-size follow-up, not a blocker).

- [ ] **Step 2: fps A/B — GRIDOV off vs on**

Two standing map-119 legs, same everything but the flag (use `bgfillprobe_ab.sh` as the harness; add a `GRIDOV`/`SOLARUS_GRIDOV=0` injection branch mirroring its existing `PROBE` branch):
- Leg A: `SOLARUS_GRIDOV=0` (resident replay baseline).
- Leg B: GRIDOV on (default).
Read `comp`, `fabric_hw`, `fps` from each leg's last `[blitter hwperf]` sample. `Δcomp = comp_A − comp_B` is the realized lever.

- [ ] **Step 3: Combination A/B — GRIDOV + bgfill**

Add the bgfill lever (`SOLARUS_BGFILLPROBE=1`, PR #140's ~3.8 ms fabric cut) on top of GRIDOV-on; read `fabric_hw`/`fps`. This is the stacked path toward 60 fps.

- [ ] **Step 4: Decision gate**

- GRIDOV-on pixel-correct (Task 4 PASS) AND (alone or with bgfill) `fabric_hw` crosses / meaningfully approaches 16.7 ms (60 fps) → **keep default-on, ship.** Update the map119 perf memory with the realized Δcomp and fps.
- Correct but a net win short of 60 fps → keep default-on if a clear net win; document the residual against the wall.
- Garbage on any Task-4 scene, or an fps regression → **revert Task 3** (restore the `getenv` opt-in gate) but KEEP Task 1 (the mux fix) and Task 2 (instrument); document a NO-GO with the failing scene / the Σruns that didn't coalesce.

- [ ] **Step 5: Record outcome + update memory**

Write the realized numbers (Δcomp, fps, Σruns win, GRID_BUF bytes) into `docs/superpowers/data/stage5/` and update the relevant map119 memory (`solarus-map119-bgfill-attribution` / a new gridov entry). Note whether the 60 fps wall was crossed.

---

## Cross-refs

- Spec: `docs/superpowers/specs/2026-07-23-map119-gridov-productize-design.md`.
- Prereq fix: `6be6a28` (on origin/master via PR #142 `fix/tilemap-grid-sdram-source`); bug memory `solarus-tilemap-grid-sdram-mux-bug`.
- GRIDOV code: `mister_blitter_renderer.cpp` `res_arm_()` (`:3298-3436`), `BLT_GRIDOV_MAXK`=8 (`:718`), `mister_flag_default_on` (`:100`), `blt_grid_decompose` (`grid_decompose.h`), `blt_grid_stats` (`grid_stats.h`).
- Phase-0 attribution/sizing: `docs/superpowers/specs/2026-07-23-map119-comp-attribution-phase0-design.md`; runbook `docs/superpowers/plans/2026-07-23-map119-comp-attribution-runbook.md`.
- A/B harness + single-engine launch: `scripts/perf/bgfillprobe_ab.sh`, `scripts/perf/stage5_device_launch.sh`.
- Visual-validation rule: `solarus-no-self-declared-visual-validation` memory.
