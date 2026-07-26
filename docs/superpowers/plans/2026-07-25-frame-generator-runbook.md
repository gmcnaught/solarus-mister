# Frame generator — operator runbook

**Binary:** `build/armhf/frame_gen` (built by `scripts/build_frame_gen.sh`).
**Source:** `patches/mister/frame_gen/frame_gen.c`.
**Device:** `root@192.168.20.81` (key-authed SSH, no password).
**Core:** `_Other/Solarus_20260724.rbf`.

**Purpose.** Since PR #151 retired the host-side vblank barrier, the free-running
cap in `present()` (`mister_pace_sleep_us()`, `patches/mister/mister_pace.h`) is
the **sole** guard against the producer overwriting a buffer the scanout is still
reading. No game scene is fast enough to make that cap actually clamp anything,
so until this generator existed the cap had never been shown to hold, and the
over-production detector built on `vctrl`/`vsync_count` had never been shown to
fire at all. `frame_gen` drives the fabric compositor directly — no engine, one
producer, a chosen rate — to settle both. **Both have now been run successfully
on hardware; see `docs/superpowers/data/pacing-ab/frame-gen-validation-2026-07-25.md`
for the full results this runbook is built from.**

**This document's numbers are the measured ones, not the pre-run predictions.**
An earlier design predicted a calibration ratio of ~2.0 assuming the producer
would hit its requested rate exactly. It does not: pacing sets a MINIMUM period,
and the generator's own submit-plus-handshake overhead (~1206 µs, measured
identically in both modes below) adds on top of that. `--rate 120` therefore
achieves ~105 fps, not 120, and the calibration ratio is **~1.75**. A runbook
that stated 2.0 would make a future operator read a *correct* run as a failure.

---

## Prerequisites

- Solarus core loaded from `_Other/Solarus_20260724.rbf`.
- Engine **not running** — the binary refuses to run otherwise (verbatim, from
  `frame_gen.c`):

  ```
  REFUSING: solarus-run is alive. Two producers on one command ring
  corrupt it. Stop the engine first: kill -9 $(pidof solarus-run)
  ```

  busybox on the device has **no `pkill`**; the kill command above is the one
  to use.
- Binary deployed:

  ```bash
  scp build/armhf/frame_gen root@192.168.20.81:/tmp/
  ssh root@192.168.20.81 chmod +x /tmp/frame_gen
  ```

- **Confirm the scanout is alive before spending a 60 s run.** Sample the
  scanout counter twice, a couple of seconds apart, and check it advances:

  ```bash
  ssh root@192.168.20.81 'busybox devmem 0x3A070000; sleep 2; busybox devmem 0x3A070000'
  ```

  A dead scanout makes the run uninterpretable — the binary's own
  `displayed == 0` guard will reject it (exit 1, `FAIL: displayed=0 — the
  scanout counter never advanced...`) but that costs a full run to discover.
  Check first.

---

## The two modes, and why their pass conditions are deliberately opposite

`frame_gen` has exactly one code path; the two modes differ **only** in the
pacing target passed into it (`frame_gen.c` top-of-file comment, verbatim):

```
MODES (one code path; they differ ONLY in the pacing target):
  --paced      target = MISTER_PACE_TARGET_US. THE GATE.  PASS iff published <= displayed.
  --rate N     target = 1e6/N (default 120).   CALIBRATION. PASS iff published >  displayed.
```

- **`--paced`** (the gate) drives at the shipped cap, `MISTER_PACE_TARGET_US`
  (16689 µs, ~59.92 fps — the same constant `present()` uses). It **PASSES**
  when it does **NOT** over-produce: `published <= displayed`.
- **`--rate N`** (calibration, default `N=120`, max 240) drives deliberately
  faster than the scan rate. It **PASSES** when it **DOES** over-produce:
  `published > displayed`.

This inversion is intentional, not a typo to "fix": if driving faster than the
scanout does *not* over-produce, the over-production detector itself is broken,
and any `--paced` pass on that build is meaningless — it could just as easily
mean "the cap is holding" or "the counters can't see over-production at all."

**A gate pass only counts if a calibration run passed first on the same
build.** "We never observed over-production" is worthless evidence if we have
never observed over-production under *any* condition — the calibration run is
what proves the counters are capable of catching it before you trust a gate
pass that says they didn't.

`--paced` and `--rate` are mutually exclusive; passing both is refused (exit 2)
rather than silently discarding `--rate`.

---

## Step 1 — calibration (MUST run first)

```bash
ssh root@192.168.20.81 /tmp/frame_gen --rate 120 --seconds 60
```

**Expected output** (measured 2026-07-25, `--seconds 25` run; a `--seconds 60`
run scales the counts linearly — rates and the ratio are what to check, not the
absolute counts):

```
target=8333 us (120.00 fps)
submits=2621 handshake_timeouts=0
published=2621 (104.84 fps)   displayed=1498 (59.92 Hz)   difference=+1123
ratio published/displayed = 1.75
PASS (calibration)
```

- `target=8333 us (120.00 fps)` — the requested rate.
- `published=... (104.84 fps)` — actual achieved rate is **lower** than
  requested; ~105 fps against a requested 120, because pacing sets a minimum
  period and ~1206 µs of submit-plus-handshake overhead is added on top (see
  "Why this proves a clamp" below).
- `displayed=... (59.92 Hz)` — the scanout's own rate, independent of what the
  producer does.
- `ratio published/displayed = 1.75` — **this is the expected value, not
  ~2.0.**
- Exit code **0**, printed verdict `PASS (calibration)`.

**OPERATOR: confirm the tear is visible.** This is the one and only time the
visual is tied to the counters; record it. If the tear is *not* visible while
the counters report over-production, stop — either the observation or the
measurement is wrong, and the gate cannot be trusted until that is resolved.

**What you are looking at, and why it's a bar, not a flash.** The screen shows
a static dark background with a single bright 24 px bar sweeping left to right
at 3 px/frame (a ~1 s sweep at this build's ~105 fps). **Do not simplify this
back to a full-screen flash.** The first implementation alternated the whole
framebuffer between two colours every frame; at ~105 fps that is a 105 Hz
strobe — unpleasant, and it *hid* tearing rather than revealing it, because
every frame already differed from the last, so the eye had no stable reference
to notice a split against. The operator could not see the tear at all under
the flash, and saw it immediately after switching to the moving bar.

**What a tear looks like on this pattern:** a clean **horizontal step** in the
bar — the bar's x-position disagrees between the rows above and below some
horizontal line, i.e. the bar appears **split into two segments at different
x positions simultaneously**. This is visible on every frame it occurs on, not
just at a colour transition.

---

## Step 2 — the gate

```bash
ssh root@192.168.20.81 /tmp/frame_gen --paced --seconds 60
```

**Expected output** (measured 2026-07-25):

```
target=16689 us (59.92 fps)
submits=3353 handshake_timeouts=0
published=3353 (55.88 fps)   displayed=3595 (59.92 Hz)   difference=-242
ratio published/displayed = 0.93
PASS (gate): the cap held the producer under the scan rate.
```

Exit code **0**.

### Judder is expected here, and it is NOT tearing

The producer runs at ~55.88 fps against a 59.92 Hz display — a 4.04 Hz beat.
The `difference=-242` above is 242 frame-repeats over 60 s, i.e. 4.03/sec:
roughly four times a second the display has no new frame to show and repeats
the previous one, so the bar's motion **hitches** periodically. This is a real,
expected artifact of a rate cap that is not phase-locked to the display, and it
is easy to mistake for a gate failure if you don't know to expect it.

**Discriminate TEAR from JUDDER explicitly:**

- **TEAR** — the bar is **split**: two segments at different x positions on
  screen *at the same time*, with a horizontal boundary between them. This is
  a spatial artifact, visible as a single frozen image.
  - Only ever expected on `--rate` (calibration). Its presence on `--paced` is
    a gate failure.
- **JUDDER** — the bar stays **whole** (one segment, one x position); its
  *motion* hitches periodically as it sweeps. This is a temporal artifact —
  you need to watch it move to see it.
  - Expected on `--paced` (the gate) whenever the achieved fps beats against
    the display rate, as it does here. Do **not** report it as a gate failure.

This is exactly what the validation run observed: the operator saw the tear on
the calibration run and the judder on the gate run — which is the *correct*
outcome for each. A future operator who sees judder on the gate run and reports
it as a failure is misreading an expected artifact.

---

## Interpretation

A gate pass counts **only** on a build whose calibration passed (same build —
see the pass-condition section above for why). State this plainly to anyone
reading a result: **the counters can never prove a frame is untorn.** A torn
frame is still exactly one published frame; the counter pair (`published`,
`displayed`) cannot distinguish a torn publish from a clean one, only an
*excess* of publishes over displays. This is why the calibration run's visual
confirmation matters — it is the one point where a human eye ties the tear to
the counters, and that single observation is what licenses the counter verdict
to substitute for the visual on all later regression runs.

---

## Failure routing

- **Gate FAIL** (`FAIL (gate): OVER-PRODUCED by N frames — the sole rate guard
  did not hold. Tearing is expected. Do not ship this pacing.`, exit 1) — the
  sole rate guard is not holding. Do not ship that pacing.
  `SOLARUS_VSYNC_BARRIER=1` restores the old vblank-gated barrier as an escape
  hatch.
- **Calibration FAIL** (`FAIL (calibration): drove N fps but did NOT
  over-produce. The detector is not calibrated...`, exit 1) — the
  over-production detector itself is broken. Fix that before reading any gate
  result; a gate pass on an uncalibrated build proves nothing.
- **Handshake timeouts** (`FAIL: N handshake timeouts — the fabric did not
  complete a frame. Result is not interpretable; check the core is loaded.`,
  exit 1) — core not loaded, or the fabric is wedged. Not interpretable as a
  pacing result either way.
- **Refused to run** (`REFUSING: solarus-run is alive...`, exit **2**) — stop
  the engine (`kill -9 $(pidof solarus-run)`) and retry. Exit 2 is also used
  for bad arguments (`--paced` + `--rate` together, `--rate` out of `1..240`,
  `--seconds < 1`) and for `submits=0` — none of these are pacing results,
  they're refusals to run at all.

Summary of exit codes: **0 = PASS**, **1 = FAIL** (ran to completion, verdict
failed, or result was uninterpretable due to a runtime condition like
handshake timeouts or a dead scanout), **2 = refused to run** (bad invocation,
engine still alive, or degenerate run parameters).

---

## Aftermath

`--rate` **deliberately tears** and leaves the display mid-pattern; relaunch
the engine afterwards. No persistent state is left by either mode — the next
`blt_begin_frame` resets the command ring, so there is nothing to clean up on
the fabric side.

---

## Recording results

Record results in `docs/superpowers/data/pacing-ab/`, following the format of
`frame-gen-validation-2026-07-25.md` (the run this document is based on) —
mode, raw banner output, operator visual verdict (tear/judder/clean), and a
verdict line per run.
