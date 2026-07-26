# Frame generator — first on-device validation, 2026-07-25

Binary `build/armhf/frame_gen` (static armhf), RBF `Solarus_20260724.rbf`, engine
stopped, branch `feat/fabric-frame-generator`.

**This closes the gap recorded in PR #151** (`overproduction-2026-07-25.md`): the
`present()` cap had never actually clamped anything, because no game scene reaches
the scan rate. Both halves are now settled.

## Preconditions verified before the runs

Engine not running; scanout live (`vsync_count` +121 in 2 s = 60.5 Hz sampled);
`vctrl` static, confirming no other producer. Binary reports
`MISTER_PACE_TARGET_US` as 16689 and the 240 fps ceiling.

## Run 1 — CALIBRATION (`--rate 120 --seconds 25`)

```
target=8333 us (120.00 fps)
submits=2621 handshake_timeouts=0
published=2621 (104.84 fps)   displayed=1498 (59.92 Hz)   difference=+1123
ratio published/displayed = 1.75
PASS (calibration)
```

**OPERATOR VISUAL: TEAR CONFIRMED.** The counters detect over-production AND the
tear is real. This pairing is what licenses the counter verdict to substitute for
the visual on later regression runs.

## Run 2 — GATE (`--paced --seconds 60`)

```
target=16689 us (59.92 fps)
submits=3353 handshake_timeouts=0
published=3353 (55.88 fps)   displayed=3595 (59.92 Hz)   difference=-242
ratio published/displayed = 0.93
PASS (gate): the cap held the producer under the scan rate.
```

**OPERATOR VISUAL: no tear.** (Periodic stepping was seen — that is judder, not
tearing; see below.)

## Why this proves the cap CLAMPED, rather than merely being idle

The two runs cross-check exactly:

| mode | target | achieved period | overhead |
|---|---|---|---|
| calibration | 8333 us | 9539 us (104.84 fps) | **1206 us** |
| gate | 16689 us | 17895 us (55.88 fps) | **1206 us** |

Identical submit+handshake overhead in both. The cap slept the full owed amount on
every frame in both modes; the ONLY difference between a run that tore and a run
that did not is the target constant. One variable, opposite outcomes.

Contrast with the engine measurements in `overproduction-2026-07-25.md`, where
`sleep=0.0` and the cap never fired — safety there came from the engine not being
fast enough, not from the guard.

## Independent confirmation of the scan-period constant

`displayed` reports **59.92 Hz** in every run. That matches the corrected
59.9228 Hz derivation of `MISTER_PACE_TARGET_US`, arrived at from a completely
different direction than reading RTL. This constant has been wrong twice (shipped
as 16667 = 60.00 Hz; then a review found the derivation comment implied 16688), so
an independent measurement of it is worth having on record.

## Two corrections to the spec's predictions

1. **Expected calibration ratio is ~1.75, not ~2.0.** The spec predicted `N / 59.92`
   assuming the producer hits its target rate. It does not: pacing sets a MINIMUM
   period and the ~1206 us submit+handshake adds on top, so 120 fps requested yields
   ~105 fps achieved. Not a fault — but a runbook that states 2.0 would have a future
   operator reading a correct run as a miss.

2. **Judder is expected on the gate run and must not be mistaken for tearing.**
   The producer runs 55.88 fps against a 59.92 Hz display — a 4.04 Hz beat, and the
   counters show 242 repeats / 60 s = 4.03 per second. Roughly four times a second
   the display has no new frame and repeats the previous one.

   Telling them apart:
   - **TEAR** — the bar is SPLIT: two segments at different x simultaneously, with a
     horizontal boundary between them.
   - **JUDDER** — the bar stays WHOLE; its motion hitches periodically.

   This is an artifact of the generator's own overhead, not necessarily the engine's:
   the engine measured 59.17 vs 59.97 (a 0.8 Hz beat, ~1 hitch/sec). The general
   point stands though — a software cap that clamps RATE without locking to display
   PHASE trades tearing for judder. Now demonstrated rather than assumed.

## Test-pattern history (why the content is a moving bar)

The first implementation alternated the whole framebuffer between two colours every
frame. At the ~105 fps actually achieved that is a 105 Hz strobe: unpleasant, and it
HID tearing rather than revealing it, because every frame differed from the last so
the eye had no stable reference. The operator could not tell whether a tear occurred
even while the counters proved over-production.

Replaced with the standard pattern: a 24 px bright bar stepping 3 px/frame across a
static dark background (~1 s sweep). A tear then shows as a clean horizontal step in
the bar's vertical edge. The operator confirmed the tear immediately after the
switch. Keep this pattern; do not "simplify" it back to a flash.
