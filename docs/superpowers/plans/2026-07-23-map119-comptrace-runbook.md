# Map 119 `COMPTRACE` capture + combination A/B — operator runbook

**Device:** `root@192.168.20.81` (key-authed SSH, no password).
**Repo root (host):** `/Users/gmcnaught/MisterFPGA-Projects/solarus-mister`.
**Purpose:** capture one settled `COMP_FRAME … COMP_END` block on map 119 with the
`SOLARUS_COMPTRACE=1` engine trace, run it through the offline analyzer
(`scripts/perf/comp_overdraw.py`), and — once an overdraw fix exists — run the
additive combination A/B against `SOLARUS_BGFILLPROBE` (PR 140) to see whether the
pair crosses the 16.7 ms / 60 fps threshold that neither lever crosses alone.

This is an **engine-only** exercise. No RTL/RBF change; everything here ships on
the current `Solarus_20260723.rbf` (Stage 5 Phase 2, FB→DDR3).

---

## 0. Prerequisites

- Solarus core loaded from `_Other/Solarus_20260723.rbf` (already the ship RBF —
  see `stage5_device_launch.sh`, which pins this filename).
- Quest `mystery_of_solarus_dx.sol` + `save1.dat` present in
  `/media/fat/games/Solarus/quests/` and `/media/fat/saves/Solarus/` respectively.
- The map-119 fixed teleport spot is `("119", "from_dungeon_10")` — see
  `scripts/perf/README-stage5.md` and `scripts/perf/capture_map119.sh`.
- Only **one** `solarus-run` at a time (auto-launch daemons + a manual launch
  wedge the host — see the two-engines memory). Every launch below kills
  `quest_manager.sh` / `core_watch.sh` / `solarus_daemon.sh` / `solarus-run`
  first.

---

## 1. Build (engine-only, no RBF), avoiding the flaky in-docker `git am`

Host-apply the patch series (reliable), then compile-only in Docker
(`SOLARUS_SKIP_APPLY=1` skips `build_engine.sh`'s own apply step, which is the
flaky one under the container's git):

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/solarus-mister
scripts/apply_patch_series.sh
SOLARUS_SKIP_APPLY=1 scripts/docker_run.sh scripts/build_engine.sh
```

**Verify the built lib actually carries the new trace symbol and is fresh** — two
prior probe builds on this branch falsely exited 0 without checking this:

```bash
strings build/armhf/libsolarus.so.1.6.5 | grep -c COMP_FRAME   # expect >= 1
ls -l build/armhf/libsolarus.so.1.6.5                          # confirm mtime is NOW, not stale
```

If the count is 0, the container compiled a stale/pre-Task-2 source tree — re-run
`apply_patch_series.sh` and rebuild before going further.

**Deploy staleness trap:** `deploy.py` ships from `deploy/`, **not**
`build/armhf` — refresh `deploy/` from the fresh build first, then deploy
engine-only (no RBF; the current ship RBF already matches):

```bash
cp build/armhf/solarus-run deploy/solarus-run
cp build/armhf/libsolarus.so.1.6.5 deploy/libs/libsolarus.so.1.6.5
./deploy.py --no-rbf
```

`deploy.py` sha1-verifies each artifact device-side and link-probes the lib
closure (`solarus-run -help`) as part of its own post-deploy checks — a second
manual sha1 check is redundant (see `fpga-deploy-refresh-from-build-armhf`
memory) but doesn't hurt if you're unsure the refresh above actually ran.

---

## 2. Capture the attribution frame (map 119 standing)

Use the Stage 5 detached-launch template
(`scripts/perf/stage5_device_launch.sh`) as-is for the core-load / FIFO /
single-engine setup, with two changes: add `SOLARUS_COMPTRACE=1` to the launch
env, and log to a comptrace-specific path under `/media/fat/logs` (not `/tmp` —
`/tmp` does not survive an ssh disconnect the way a file under `/media/fat`
does, and matches the existing convention).

```bash
HOST=root@192.168.20.81
LOG=/media/fat/logs/Solarus/comptrace-map119.log
FIFO=/tmp/sol_in

# adapt the shared launch template: same RBF, same FIFO/quest-dir setup,
# just add SOLARUS_COMPTRACE=1 and repoint the log file.
sed -e 's#stage5-boot.log#comptrace-map119.log#g' \
    -e 's#SOLARUS_BLITTER_DIAG=1 \\#SOLARUS_BLITTER_DIAG=1 SOLARUS_COMPTRACE=1 \\#' \
    scripts/perf/stage5_device_launch.sh > /tmp/comptrace_launch.sh
scp -q /tmp/comptrace_launch.sh "$HOST:/tmp/comptrace_launch.sh"
```

Launch **detached** so it survives ssh disconnect — the launch script's own
`setsid ./solarus-run … < "$FIFO" > "$LOGDIR/…" 2>&1 &` already backgrounds and
detaches the engine, but drive the *launch script itself* the same way so a
dropped ssh session doesn't kill the boot sequence mid-flight:

```bash
ssh "$HOST" 'setsid sh /tmp/comptrace_launch.sh >/media/fat/logs/Solarus/comptrace-launch.log 2>&1 </dev/null &'
sleep 20   # boot + fabric settle (core load + engine + FIFO)
```

Start the save and teleport to the fixed map-119 spot over the held FIFO:

```bash
ssh "$HOST" "printf 'sol.main.game = sol.game.load(\"save1.dat\"); sol.menu.stop_all(sol.main); sol.main:start_savegame(sol.main.game)\n' > $FIFO"
sleep 6
ssh "$HOST" "printf 'sol.main.game:get_hero():teleport(\"119\",\"from_dungeon_10\")\n' > $FIFO"
sleep 6
```

Confirm the map, then let a few frames settle (COMPTRACE arms/dumps ONE frame per
resident-build; it re-arms on any subsequent scene rebuild, e.g. re-teleport —
see caveat in §5):

```bash
ssh "$HOST" "printf 'print(\"CURMAP=\"..sol.main.game:get_map():get_id())\n' > $FIFO"; sleep 2
ssh "$HOST" "grep -o 'CURMAP=[0-9]*' $LOG | tail -1"   # must print CURMAP=119
```

Pull the full log (it contains the one `COMP_FRAME … COMP_END` block from scene
entry, plus the ongoing `[blitter …]` diag banners):

```bash
scp -q "$HOST:$LOG" comptrace-map119.log
```

**Grab the steady-state `[blitter hwperf]` line** for the analyzer's cross-check
(let the hero stand idle another ~10 s so the /60fr rolling window is
steady-state, then re-pull or tail the live log):

```bash
ssh "$HOST" "grep -E '\[blitter hwperf\]' $LOG | tail -1"
```

This prints (exact ship format, `mister_blitter_renderer.cpp:4011-4013`):

```
[blitter hwperf] /60fr: fabric_hw=<fh>ms comp=<c>ms comp%=<p>% (<fabric_cyc> cyc/frame) | A9-or-fabric-bound: <FABRIC|A9>
```

**Note the parenthesized `cyc/frame` is `fabric_hw`'s cycle count, not `comp`'s** —
derive `comp`'s cycles for the analyzer either way (they agree):

- `comp_cyc = comp_ms * 98437.5` (fabric runs at `FABRIC_HZ = 98.4375e6` Hz;
  `mister_blitter_renderer.cpp:4008`), or
- `comp_cyc = fabric_cyc_from_paren * (comp% / 100)`.

On the current ship baseline (`docs/superpowers/2026-07-22-map119-bgfillprobe-attribution.md`):
`fabric_hw=20.63ms comp=14.89ms comp%=72%` → `comp_cyc ≈ 14.89 * 98437.5 ≈ 1,465,734` cyc/frame.

---

## 3. Analyze offline

```bash
python3 scripts/perf/comp_overdraw.py comptrace-map119.log \
  --comp-cyc 1465734 --heatmap > report.txt
```

(Substitute the `comp_cyc` you actually derived in §2 for the run you captured —
1,465,734 above is the ship-baseline example, not a fixed constant.)

**How to read `report.txt`:**

- **Header line** — `map=119 cam=(cx,cy) fb=(320,240) records=<N>`: sanity-check
  the map id and record count are non-zero/plausible.
- **Total + mean/max overdraw** — `composited px total = … (mean overdraw
  <M>x, max <K>)`. `M` is the average number of times each on-screen pixel got
  written this frame (1.0 = no overdraw at all); `K` is the worst single pixel —
  a large `K` with a much smaller `M` means the waste is localized (heatmap will
  show a hot spot), not a uniform across-the-board tax.
- **Per-category %** — one line per `{fill, blit, sprite, tilemap, overlay}` with
  clipped composited px and the % of the frame's total. This is the attribution:
  whichever category dominates is where an overdraw cull should target first.
  Recall `overlay` is always exactly one full-screen entry (320×240, see §5) —
  if it reads as a large % share that's expected, not a bug; the lever there
  (content-identity skip) is already shipped (`SOLARUS_OVERLAYSKIP`) and is
  about the A9 upload cost, not this fabric-pixel accounting.
- **Cross-check ratio** — `cross-check: hwperf comp=<c> cyc / <r> cyc-per-px =
  <modeled> modeled px` then `traced/modeled = <ratio>`:
  - **≈ 1.0** → the traced dst-area total actually accounts for `comp`'s
    fabric-cycle cost at the assumed `--cyc-per-px` (default 2.38, from
    `cache-knee.md`) — an overdraw cull (reducing traced px) is a legitimate,
    trustworthy lever for cutting `comp`.
  - **< 1.0** → the fabric is spending *more* per composited pixel than the
    dst-area model predicts (traced px is smaller than what `comp`'s cycle
    budget implies) — some of `comp`'s cost is NOT captured by dst-area alone
    (e.g. per-pixel blend read-modify-write cost, `BLEND_MULTIPLY`/`ADD` RMW,
    or per-cell FRT resolution overhead). In that case the overdraw model
    under-attributes the real cost, and blend-RMW efficiency is a **separate**
    RTL lever from "draw fewer/smaller overlapping rects" — don't expect an
    overdraw-only fix to fully close the gap; say so explicitly in whatever
    fix design follows this attribution.
  - **> 1.0** → also expected and benign, not an error. The fabric can
    early-out on fully-transparent source pixels (skip the write entirely)
    while this analyzer sums the *whole* dst rectangle regardless of per-pixel
    source alpha — so traced dst-area over-counts the pixels the fabric
    actually wrote. A ratio above 1.0 just means some traced rects had
    transparent regions the fabric skipped; it is not evidence the model or
    the trace is wrong.
- **ASCII heatmap** (`--heatmap`, 80×48 downsampled) — `shades = " .:-=+*#%@"`
  from cold to hot; look for concentrated `@`/`%` regions (localized overdraw,
  e.g. stacked parallax layers or a full-screen fill under a full-screen
  overlay) vs a uniform low-density map (overdraw is evenly spread, harder to
  cull with one targeted fix).

---

## 4. Combination A/B (additive-lever test — run AFTER an overdraw fix exists)

This section is **symbolic** until an overdraw-cull fix is designed from §3's
attribution — there is no such fix yet, by design (this runbook produces the
attribution that informs it, not the fix itself). `<fix flag>` below stands in
for whatever env-gated flag that future fix ships behind (following the
`SOLARUS_COMPTRACE` / `SOLARUS_BGFILLPROBE` / `SOLARUS_FETCHTRACE` convention:
default-off, cached-getenv, no behavior change unset).

Reuse `scripts/perf/bgfillprobe_ab.sh` as the harness template — it already
does the "load core once, hold a FIFO, teleport to map 119
`from_dungeon_10`, settle 12 s, grab the last `[blitter …]` banners" dance for
exactly this kind of additive-flag A/B. Adapt it per leg (either pass
`PROBE=1`-style env into its `sed` injection, or add a second flag the same
way):

```bash
# leg 1: baseline (no flags)
TAG=baseline scripts/perf/bgfillprobe_ab.sh

# leg 2: overdraw-fix only
TAG=overdraw FIXFLAG=1 scripts/perf/bgfillprobe_ab.sh     # inject <fix flag>=1

# leg 3: bgfill only (re-confirms PR 140 in isolation)
TAG=bgfill PROBE=1 scripts/perf/bgfillprobe_ab.sh         # existing SOLARUS_BGFILLPROBE=1 leg

# leg 4: BOTH together (the success test)
TAG=both PROBE=1 FIXFLAG=1 scripts/perf/bgfillprobe_ab.sh # inject BOTH env vars
```

> **`FIXFLAG` is illustrative, not yet real.** `bgfillprobe_ab.sh` today only
> recognizes `TAG` and `PROBE` (the `SOLARUS_BGFILLPROBE` leg). Legs 2 and 4
> require FIRST teaching the script to inject the real overdraw-fix env var
> (whatever `<fix flag>` turns out to be) the same way it injects `PROBE` —
> pasting `FIXFLAG=1` as-is is a silent no-op until you do. No overdraw fix
> exists yet, so wire this only after one is designed from the attribution.

Each leg's output (`docs/superpowers/data/stage5/ab-bgfill-<TAG>-map119.txt`)
has the `[blitter hwperf]` (`fabric_hw`, `comp`) and `[blitter timing]` (`fps`)
last-3-lines banners — read `fabric_hw` and `fps` from the final sample of
each.

| leg | env | expect |
|---|---|---|
| baseline | (none) | fabric_hw 20.63 ms, fps 29.5 |
| overdraw-fix | `<fix flag>=1` | Δcomp (record whatever the fix actually delivers) |
| bgfill | `SOLARUS_BGFILLPROBE=1` | fabric_hw ~16.83 ms, fps 29.5 (re-confirms PR 140 — no fps move alone, per `docs/superpowers/2026-07-22-map119-bgfillprobe-attribution.md`) |
| **both** | `<fix flag>=1 SOLARUS_BGFILLPROBE=1` | **fabric_hw < 16.7 ms AND fps → 60?** |

**Why neither lever alone is expected to move fps:** map 119's ship baseline is
**vsync-paced at 30 fps, not fabric-saturated** — its `pipeline_ceiling` is
~45 fps, well above the 29.5 fps it actually runs at (see the bgfillprobe
attribution doc). The engine targets 60 fps; when the compositor pipeline can't
fit inside the 16.7 ms budget it falls back to the 30 fps vsync submultiple.
That's why the bgfill probe alone cut fabric_hw by 3.8 ms (20.63→16.83 ms) for
**zero** fps change — the saving went straight into `sleep` (8.8→12.4 ms) because
16.83 ms is still above the 16.7 ms line. The same will happen to an
overdraw-fix-alone leg unless it happens to close the remaining gap by itself.

**Success criterion:** the **both** leg's `fabric_hw` reads under 16.7 ms AND
`[blitter timing]`'s `fps` jumps toward 60 (not just more `sleep` — check the
`sleep=` field in the same `[blitter timing]` line stays roughly flat or drops,
it should NOT be absorbing the saving the way it did in the bgfill-alone leg).
If both hold: **productionize BOTH together** (the corrected/real bgfill op +
the overdraw cull) — this is an additive-lever result, not an either/or choice;
each lever alone reads as "+0 fps" purely because 16.7 ms is a hard threshold
the pipeline must cross, not a continuum either lever individually reaches.

---

## 5. Caveats

- **One build frame ≈ steady state, not exact.** `COMPTRACE` arms for exactly
  one resident-build frame (scene entry / teleport) and disarms after the
  overlay composite closes `COMP_END`. Sprites animate slightly frame to frame,
  so if the `sprite` category's % share in `report.txt` looks material relative
  to the rest, re-teleport (which re-arms the trace) and re-capture a couple of
  frames, then average the per-category numbers by hand rather than trusting
  one sample.
- **The block closes only if `emit_overlay_composite` reaches its
  `blt_blit(...PALPHA...)` — it has FOUR early returns that would leave the
  block unclosed.** Those are: `!overlay_touched` (nothing drawn to the root
  this frame), `!root` (no tagged root surface), a root size-mismatch, and
  `!ref.valid` (an upload failure). Any of the four means
  `comptrace_rec("overlay", …)` + the disarm never fire, so the block never
  sees its `COMP_END`. For a map-119 standing capture the overlay channel is
  default-ON (`SOLARUS_OVERLAY`, no flag needed) and composites every frame
  (HUD etc. keeps the root touched, tagged, correctly sized, and the upload
  valid), so all four early-outs are unreachable and the one-frame block is
  guaranteed to terminate with `COMP_END` on any ordinary captured frame. **If
  a capture ever shows a `COMP_FRAME` with no matching `COMP_END`, this is
  why** — one of the four early-outs fired; re-capture rather than trying to
  analyze the incomplete block.
- **Single-engine discipline.** Every launch step above kills
  `quest_manager.sh`/`core_watch.sh`/`solarus_daemon.sh`/`solarus-run` first —
  do not skip this even for a "quick" recapture; two engines on the fabric
  wedges the host (see the two-engines memory).

---

## Cross-refs

- Analyzer: `scripts/perf/comp_overdraw.py`, `scripts/perf/test_comp_overdraw.py`.
- Engine trace sites: `patches/mister/mister_blitter_renderer.cpp` (`g_comptrace_on`,
  `comptrace_rec`, five call sites — fill/blit/sprite/two tilemap paths — plus the
  `COMP_FRAME`/`COMP_END` markers).
- PR 140 background-fill probe + numbers cited above:
  `docs/superpowers/2026-07-22-map119-bgfillprobe-attribution.md`,
  `scripts/perf/bgfillprobe_ab.sh`.
- Detached single-engine launch template: `scripts/perf/stage5_device_launch.sh`,
  `scripts/perf/README-stage5.md` (fixed map-119 spot).
- Build/deploy scripts: `scripts/apply_patch_series.sh`, `scripts/docker_run.sh`,
  `scripts/build_engine.sh`, `deploy.py`.
- Implementation plan this runbook is Task 4 of:
  `docs/superpowers/plans/2026-07-23-map119-comp-overdraw-attribution.md`.
