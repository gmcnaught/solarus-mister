# Part A — over-production probe (objective tear-hazard test), 2026-07-25

Engine `libsolarus.so.1.6.5` sha1 `769e0953…`, RBF `Solarus_20260724.rbf`,
branch `perf/pacing-barrier-and-region-blend-capture`, default pacing
(`SOLARUS_VSYNC_BARRIER` unset → barrier OFF, `present()` cap active).

## What this measures

The retired barrier guarded exactly one hazard: the fabric publishing two frames
inside one scanout window, so the snapshot overwrites the buffer the reader is
still scanning. That is directly observable without eyeballs:

- `vctrl` @ `0x3A000000` — `((frame_counter+1)<<2)|active_buf`; `>>2` = frames PUBLISHED.
- `vsync_count` @ `0x3A070000` — frames DISPLAYED by the reader.

published > displayed ⇒ the hazard occurred. Non-invasive (reads only), so it
runs against a live play session.

## Results (operator playing; 60 fps overworld + map 119)

**60 s aggregate:** published 3550 (59.17 fps), displayed 3598 (59.97 Hz),
difference **−48**. Producer stayed 1.3 % below the scan rate throughout.

**90 s fine probe** (359 windows @ 250 ms, raw in
`overproduction-fine-probe-2026-07-25.txt`):

| per-window (published − displayed) | windows |
|---|---|
| −3 | 6 |
| −2 | 31 |
| −1 | 107 |
| 0 | 164 |
| **+1** | **51** |

Sum −136, mean −0.379, **max excursion +1 — never ≥ +2**.

The `+1` windows are sampling skew, not double-publishes: `vctrl` and
`vsync_count` are read by two separate `devmem` invocations milliseconds apart,
so a ±1 boundary misattribution in a ~17-frame window is expected. A genuine
double-publish would appear as ≥ +2; none does.

## Why it holds structurally (stronger than the statistics)

`mister_blitter_renderer.cpp:4521` timestamps `last` **after** the pacing sleep
(`:4514`), so successive submits are ≥ `target_us` = 16689 µs apart *by
construction*. Scan period is 16687.9 µs (15,700 Hz / 262 lines). Two publishes
therefore cannot fall in one scan window unless HPS↔FPGA clock drift exceeds
~66 ppm. Measured periods land at ~16901 µs — **212 µs of real margin, ~190× the
1.1 µs nominal** — which swamps any plausible drift.

## Operator visual

PASS — image correct on the 60 fps overworld and on map 119.

## KNOWN GAP

At 59.17 fps the engine is *below* the 59.92 Hz target, so `dus > target_us` and
the cap **is barely firing**. This proves no over-production occurs; it does NOT
exercise the cap's clamping. Safety in these scenes comes from the engine not
being fast enough, not from the mechanism under test. Still owed: a
`SOLARUS_BLITTER_DIAG=1` run reporting `[blitter timing] sleep=`, to establish
whether the cap ever engages. If `sleep ≈ 0` everywhere the cap is latent and its
first real exercise is deferred to a future faster scene.
