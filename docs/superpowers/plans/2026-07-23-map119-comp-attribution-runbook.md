# Map 119 comp attribution — Phase 0 operator runbook

**Device:** `root@192.168.20.81` (key-authed SSH, no password).
**Repo root (host):** `/Users/gmcnaught/MisterFPGA-Projects/solarus-mister`.
**Purpose:** drive the three Phase-0 HW captures (overlay A/B, grid-stats dump)
and run them through the offline attribution script
(`scripts/perf/comp_attribution.py`) to produce a ranked breakdown of map
119's compositor cost (`comp` ≈ 14.9 ms) into `{overlay-palpha,
tilemap-empty-walk, tilemap-resolve, tilemap-pixels, sprite}`, so Phase 1
knows which slice to cull.

> **THIS DOCUMENT IS NOT EXECUTED AS PART OF THIS TASK.** Task 5 only writes
> this runbook plus the attribution script and its host test. **A concurrent
> session currently owns the device with a different build** — do not run
> any command below, do not build, do not deploy, do not SSH to the device,
> while that session is active. Every step here is written for a *future*
> operator session, after the device is free and the Phase-0 engine
> (Tasks 1 + 3: `SOLARUS_OVERLAYNOCOMP` + `SOLARUS_GRIDSTATS`) has landed.

This is an **engine-only** exercise for the two HW captures (§2–3); the
attribution itself (§4) runs offline on the host, no device needed. No
RTL/RBF change — everything here ships on the current `Solarus_20260723.rbf`
(Stage 5 Phase 2, FB→DDR3).

---

## 0. Prerequisites

- Solarus core loaded from `_Other/Solarus_20260723.rbf` (already the ship
  RBF — see `stage5_device_launch.sh`, which pins this filename).
- Quest `mystery_of_solarus_dx.sol` + `save1.dat` present in
  `/media/fat/games/Solarus/quests/` and `/media/fat/saves/Solarus/`
  respectively.
- The map-119 fixed teleport spot is `("119", "from_dungeon_10")` — see
  `scripts/perf/README-stage5.md` and `scripts/perf/capture_map119.sh`.
- Only **one** `solarus-run` at a time (auto-launch daemons + a manual
  launch wedge the host — see the two-engines memory). Every launch below
  kills `quest_manager.sh` / `core_watch.sh` / `solarus_daemon.sh` /
  `solarus-run` first.
- The Phase-0 engine (Task 1's `SOLARUS_OVERLAYNOCOMP` probe + Task 3's
  `SOLARUS_GRIDSTATS` dump) must be built and deployed per §1 before §2–3
  produce anything meaningful — the flags are no-ops on any older build.

---

## 1. Build + deploy the Phase-0 engine (Tasks 1 + 3)

Host-apply the patch series (reliable), then compile-only in Docker
(`SOLARUS_SKIP_APPLY=1` skips `build_engine.sh`'s own apply step, which is
the flaky one under the container's git):

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
scripts/apply_patch_series.sh
SOLARUS_SKIP_APPLY=1 scripts/docker_run.sh scripts/build_engine.sh
```

**Verify the built lib actually carries the new symbol and is fresh** — the
COMPTRACE runbook's build already burned two prior probe builds that falsely
exited 0 without checking this:

```bash
strings build/armhf/libsolarus.so.1.6.5 | grep -c GRIDSTATS   # expect >= 1
ls -l build/armhf/libsolarus.so.1.6.5                         # confirm mtime is NOW, not stale
```

If the count is 0, the container compiled a stale/pre-Task-3 source tree —
re-run `apply_patch_series.sh` and rebuild before going further.

**Deploy staleness trap:** `deploy.py` ships from `deploy/`, **not**
`build/armhf` — refresh `deploy/` from the fresh build first, then deploy
engine-only (no RBF; the current ship RBF already matches):

```bash
cp build/armhf/solarus-run deploy/solarus-run
cp build/armhf/libsolarus.so.1.6.5 deploy/libs/libsolarus.so.1.6.5
./deploy.py --no-rbf
```

`deploy.py` sha1-verifies each artifact device-side and link-probes the lib
closure (`solarus-run -help`) as part of its own post-deploy checks (see
`fpga-deploy-refresh-from-build-armhf` memory).

---

## 2. Overlay A/B — capture `Δcomp` (the `--overlay-ms` input)

Two standing map-119 legs, **same ship RBF, same everything, only the flag
differs**: baseline (no flag) vs `SOLARUS_OVERLAYNOCOMP=1`. `Δcomp` =
baseline `comp` − probe `comp` = the overlay channel's per-frame comp cost.

Reuse `scripts/perf/bgfillprobe_ab.sh` as the harness template — it already
does the load-core / held-FIFO / teleport-to-map-119 / settle / grab-last-3
dance for exactly this shape of additive-flag A/B (`docs/superpowers/2026-07-22-map119-bgfillprobe-attribution.md`
documents the precedent for `SOLARUS_BGFILLPROBE`). Inject
`SOLARUS_OVERLAYNOCOMP=1` the same way that script injects `PROBE`'s
`SOLARUS_BGFILLPROBE=1` — via the `sed` line that rewrites
`SOLARUS_BLITTER_DIAG=1 \` in the launch template:

```bash
# leg 1: baseline (no flags)
TAG=baseline scripts/perf/bgfillprobe_ab.sh

# leg 2: overlay-off probe
TAG=overlaynocomp OVERLAYNOCOMP=1 scripts/perf/bgfillprobe_ab.sh
```

> `bgfillprobe_ab.sh` today only recognizes `TAG` and `PROBE`
> (`SOLARUS_BGFILLPROBE`). Before leg 2 will do anything, add an
> `OVERLAYNOCOMP` branch to its `sed` injection (mirroring the existing
> `PROBE` branch) so it emits `SOLARUS_OVERLAYNOCOMP=1` into the launch env.
> Pasting `OVERLAYNOCOMP=1` as-is without that change is a silent no-op.

Each leg's output (`docs/superpowers/data/stage5/ab-bgfill-<TAG>-map119.txt`)
has the `[blitter hwperf]` banner (`fabric_hw=`, `comp=`) — read `comp` from
the last sample of each leg, then:

```
overlay_ms = comp_baseline − comp_overlaynocomp
```

This `overlay_ms` is the script's `--overlay-ms` argument (§4).

---

## 3. Grid-stats capture — the `<gridlog>` input

One standing map-119 launch with `SOLARUS_GRIDSTATS=1` (no A/B needed — this
is a single dump, not a differential measurement). Adapt
`scripts/perf/stage5_device_launch.sh` the same way the COMPTRACE runbook
adapts it for its own flag, injecting `SOLARUS_GRIDSTATS=1` and repointing
the log:

```bash
HOST=root@192.168.20.81
LOG=/media/fat/logs/Solarus/gridstats-map119.log
FIFO=/tmp/sol_in

sed -e 's#stage5-boot.log#gridstats-map119.log#g' \
    -e 's#SOLARUS_BLITTER_DIAG=1 \\#SOLARUS_BLITTER_DIAG=1 SOLARUS_GRIDSTATS=1 \\#' \
    scripts/perf/stage5_device_launch.sh > /tmp/gridstats_launch.sh
scp -q /tmp/gridstats_launch.sh "$HOST:/tmp/gridstats_launch.sh"
ssh "$HOST" 'setsid sh /tmp/gridstats_launch.sh >/media/fat/logs/Solarus/gridstats-launch.log 2>&1 </dev/null &'
sleep 20
```

Start the save and teleport to the fixed map-119 spot over the held FIFO
(same dance as the COMPTRACE runbook §2):

```bash
ssh "$HOST" "printf 'sol.main.game = sol.game.load(\"save1.dat\"); sol.menu.stop_all(sol.main); sol.main:start_savegame(sol.main.game)\n' > $FIFO"
sleep 6
ssh "$HOST" "printf 'sol.main.game:get_hero():teleport(\"119\",\"from_dungeon_10\")\n' > $FIFO"
sleep 8
```

Let a few frames settle, confirm the map, then pull the log:

```bash
ssh "$HOST" "printf 'print(\"CURMAP=\"..sol.main.game:get_map():get_id())\n' > $FIFO"; sleep 2
ssh "$HOST" "grep -o 'CURMAP=[0-9]*' $LOG | tail -1"   # must print CURMAP=119
scp -q "$HOST:$LOG" gridstats-map119.log
```

Also grab the steady-state `comp` for the script's `--comp-ms`:

```bash
ssh "$HOST" "grep -E '\[blitter hwperf\]' $LOG | tail -1"
```

`gridstats-map119.log` (containing the `GRIDSTATS layer=... nonempty=...
empty=... runs=...` lines, one per static layer bucket) is the script's
`<gridlog>` positional argument (§4).

---

## 4. Attribute (offline, host-only, no device)

The Task-4 calibration (`fpga/sim/tb_tilemap.sv`'s CALIB line, S6 scenario):

```
CALIB grid: empty_state_cyc=78 resolve_cyc=3 wait_cyc=287 n_runs=1 n_empty_known=38
```

gives `--empty-cyc = 78/38 ≈ 2.05` and `--run-cyc ≈ 156` (see the derivation
in `scripts/perf/comp_attribution.py`'s module docstring). **For
`--px-cyc-per-col`, use `wait_cyc / run_width_px = 287 / 16 ≈ 18`, NOT the
placeholder's `8`** (1 cyc/px) — the single-run S6 scenario can't separate a
fixed per-run cost from a per-pixel-column cost, so dividing the run's whole
`wait_cyc` by its pixel-column width is the better-supported estimate until a
second, multi-run calibration scenario exists. The script's own docstring
carries this correction and the CAVEAT it depends on; do not silently revert
to `8` because it looks like a "rounder" number.

```bash
python3 scripts/perf/comp_attribution.py gridstats-map119.log \
  --comp-ms <c> --overlay-ms <overlay_ms from §2> \
  --empty-cyc 2.05 --run-cyc 156 --px-cyc-per-col 18
```

Read the ranked `slice <name> <ms> <pct>` lines (highest first) and the
`SUM check: modeled=... vs measured comp=... (ratio ...)` line.

---

## 5. Gate — the SUM check validates the constants, not just the ranking

**The `SUM check` line is what actually validates `--empty-cyc`,
`--run-cyc`, and `--px-cyc-per-col` against real hardware data** — Task 4's
constants come from one synthetic sim scenario (single run, 38 empty
cells), so until this ratio has been checked against a real map-119
capture, treat them as unproven, not just "approximate."

- **Ratio near 1.0** (say, roughly 0.7–1.4 — this is an order-of-magnitude
  sanity check, not a tight tolerance, per the calibration's own single-scenario
  caveat): the model and constants are good enough to trust the ranking.
  Proceed — the **top slice** names the Phase-1 lever, per the decision
  table below.
- **Ratio far from 1.0** (well under ~0.5 or well over ~2): **STOP.** Do not
  proceed to Phase 1 on this data. Reconcile first — likely candidates are
  (a) the `px_cyc_per_col` estimate is still wrong (needs a second,
  multi-run `tb_tilemap` calibration scenario to fit fixed-vs-per-pixel cost
  independently, per the CAVEAT in `comp_attribution.py`), (b) the model is
  missing a cost category entirely (e.g. FRT/CFT pattern-table upload, which
  the Task-4 scenario didn't isolate), or (c) the grid-stats capture and the
  `--comp-ms` sample weren't from the same steady-state window. Re-derive or
  re-capture before trusting the ranked slices for a lever decision.

### Decision table (top slice → Phase-1 lever)

| top slice | candidate Phase-1 lever |
|---|---|
| `overlay-palpha` | overlay-shrink (reduce the full-screen PALPHA composite's cost — e.g. dirty-rect instead of full-screen, building on the existing `SOLARUS_OVERLAYSKIP` content-identity precedent) |
| `tilemap-empty-walk` | empty-run-skip (coalesce/skip empty-cell fetch+decode cycles in the grid walk, `blitter_top.sv`'s `S_GRID_FETCH`/`S_GRID_DECODE`) |
| `tilemap-resolve` | resolve-cache (cache FRT/CFT pattern resolution across frames/runs so `S_GRID_SLICE`/`S_TLR_CFT`/`S_TLR_FRT` dispatch isn't repeated for static content) |
| `tilemap-pixels` | occlusion-cull (reduce composited/overdrawn pixel count — see `scripts/perf/comp_overdraw.py`'s per-category overdraw attribution for a complementary view of this same slice) |
| `sprite` | (no candidate lever yet named in the Phase-0 design doc; if sprite dominates, that itself is a new finding worth a fresh spec rather than picking from this table) |

Otherwise the top slice's row above is the Phase-1 spec's starting point —
see "After Phase 0" in `docs/superpowers/plans/2026-07-23-map119-comp-attribution-phase0.md`
for what that spec must additionally do (own default-off flag, combination
A/B against `SOLARUS_BGFILLPROBE`, 16.7 ms/60 fps threshold, or a documented
NO-GO if the slice is too small to matter).

---

## 6. Caveats

- **Single-scenario calibration.** Every constant fed to `--empty-cyc`
  /`--run-cyc`/`--px-cyc-per-col` traces back to ONE `tb_tilemap` scenario
  (S6, one run, 38 empty cells) — order-of-magnitude only. The SUM check
  (§5) is the check that this order-of-magnitude estimate survives contact
  with real map-119 data; it is not a rubber stamp.
- **Grid-stats is a single dump, not an A/B** — unlike the overlay probe,
  `SOLARUS_GRIDSTATS` doesn't need a baseline/probe pair; it just prints the
  built grid's own composition. Capture it from the same standing window as
  the `--comp-ms` sample so the two numbers describe the same frame.
- **Single-engine discipline.** Every launch step above kills
  `quest_manager.sh`/`core_watch.sh`/`solarus_daemon.sh`/`solarus-run` first
  — do not skip this even for a "quick" recapture; two engines on the
  fabric wedges the host (see the two-engines memory).
- **This runbook does not itself run anything.** Re-read the banner at the
  top before executing any command here on real hardware — confirm the
  device is free (no concurrent session) and the Phase-0 engine (§1) is
  actually the build on the device before trusting any capture.

---

## Cross-refs

- Attribution script + host test: `scripts/perf/comp_attribution.py`,
  `scripts/perf/test_comp_attribution.py`.
- Overlay A/B harness template: `scripts/perf/bgfillprobe_ab.sh`,
  `docs/superpowers/2026-07-22-map119-bgfillprobe-attribution.md`.
- Detached single-engine launch template: `scripts/perf/stage5_device_launch.sh`,
  `scripts/perf/README-stage5.md` (fixed map-119 spot).
- Build/deploy scripts: `scripts/apply_patch_series.sh`, `scripts/docker_run.sh`,
  `scripts/build_engine.sh`, `deploy.py`.
- Fabric calibration source: `fpga/sim/tb_tilemap.sv` (CALIB counters, Task 4).
- Sibling runbook this one is modeled on (same build/deploy/single-engine/
  teleport shape, different capture): `docs/superpowers/plans/2026-07-23-map119-comptrace-runbook.md`.
- Implementation plan this runbook is Task 5 of:
  `docs/superpowers/plans/2026-07-23-map119-comp-attribution-phase0.md`.
