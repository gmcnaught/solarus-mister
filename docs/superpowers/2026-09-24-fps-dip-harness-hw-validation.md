# FPS dips in active gameplay — harness, causes, fixes (2026-09-24, `.62`)

Question: why does FPS frequently dip below 55 during active gameplay?
Method: the Cash Cow DX stutter process (`cash.cow.dx-mister` PLAN §6.18, §6.25) ported to
Solarus as `scripts/fpsdip/`. Device `.62` (kernel 6.18.38, `Solarus_20260818.rbf`, v1.2.0-rc1
install), Mystery of Solarus DX, `save1.dat`.

## Harness

| Piece | What it does |
|---|---|
| `SOLARUS_FRAMELOG=<path>` (patch 0050, `mister_framelog.h`) | One 64-byte record per `MainLoop::run` iteration: input / update / draw / sleep phases, Lua VM time, renderer fabric wait + measured pace sleep, uploaded pixels, submitted commands, **scanout vblank counter at each submit**, main-thread CPU time, context switches, faults, steps, map, game-state flags. Off = one branch. |
| `scripts/fpsdip/driver.lua` | Loaded through the Lua console. Starts `save1.dat` the way the quest's F1 key does, preloads sounds as the title screen does, **invincible hero** (`hero:set_invincible(true)` + life top-up) with the sword, random play through `game:simulate_command_pressed`, dismisses dialogs, tours 14 maps (40 s each). Never saves. |
| `scripts/fpsdip/run.sh` (device) | Runs the real `solarus_run.sh` with the engine under test swapped in and restored; one run at a time (lock); `PROF=1` main-thread sampling, `SCHED=1` CPU0 scheduler trace. |
| `scripts/fpsdip/frames.py` | On-screen counter windows (the OSD's 30-frame average), presented fps, **displayed** fps (new frames per 60 scanout frames), long-frame attribution, per-map table, CPU0 preemptors. |
| `scripts/fpsdip/capture.sh` (host) | Run + pull + analyse: `capture.sh <tag> <s> <engine dir> [PROF=1] [SCHED=1] [TOUR=...]`. |

Two harness artefacts were found and fixed before any measurement counted: setting `sol.main.game`
after `sol.menu.stop_all` let `main.lua`'s menu chain restart the **title screen under the game**
(full-screen `fill_color` every frame, ~30 fps everywhere), and skipping the title skipped
`sol.audio.preload_sounds()`, so first plays decoded `.ogg` files on the main thread (50–85 ms
spikes real play never sees).

## Results (600 s per leg, ~480 s active gameplay, 20–22 maps, same seed)

| | base2 (rc1 behaviour) | pace1 (+ scanout pacer) | iso2 (+ CPU isolation) |
|---|---|---|---|
| displayed 1-s windows < 55 | **177 / 444 (40%)**, min 43 | 3 / 454, min 38 | **0 / 435** |
| displayed windows at 60 | 60 / 444 | 414 / 454 | **434 / 435** (1 at 59) |
| frames overwritten unseen | 1,933 | 0 | 0 |
| repeated scanout frames | 2,308 | 85 | 1 |
| on-screen counter windows < 55 | 11 / 908 (1.2%), min 46.2 | 6 / 935, min 39.0 | **0 / 902, min 58.0** |
| long frames (> 18.4 ms) | 608 (2.16%) | 384 (1.33%) | 59 (0.21%), max 35 ms |

Summaries: `docs/superpowers/data/fpsdip/{base2,pace1,iso1,iso2,sched47n}.txt`.

## Causes and fixes

**1. The pacer never locked to the scanout (the dominant cause of visible dips).**
`present()` slept to 16,689 µs after the doorbell. Measured paced period: mean 16,822 µs, p99
18,096 — nanosleep overshoot. The submit phase drifted across the vblank boundary and jittered
back and forth while it sat there (non-1 vblank deltas came in 0/2 pairs), so two frames landed
in one scanout frame (the first never shown) and the next scanout frame repeated. The on-screen
counter counts loop iterations, so it read ~59.5 while the screen showed 43–58 new frames per
second in 40% of seconds.
Fix (`3750272`): `SOLARUS_PACE=scanout` (default) waits **before the doorbell** until the
reader's vblank counter (`0x3A070000`) differs from its value at the previous publish: one
publish per scanout frame, just after vblank, so the composite has a full period before the
next latch. 50 ms without a counter change falls back to the wall-clock cap for that frame.
`SOLARUS_PACE=timer` is the A/B leg. Decision logic in `mister_pace.h`, host-tested.

**2. The render thread shared CPU0 with everything.**
Main-thread CPU was ~half the period of the remaining long frames (15–150 involuntary switches
per frame); on map 47 this compounded into a 12 s death spiral (10 catch-up steps per iteration,
11–32 fps, `iso1`). On CPU0: the dwc2 USB IRQ (~8,060/s, all CPU0), engine threads that inherited
the audio code's CPU0 pin, the launcher's polling watchers, and **Zaparoo** — a CPU0 scheduler
trace put 408 ms of Zaparoo inside 58 long frames. Zaparoo re-applies its own affinity (its
threads were back on CPUs 0–1 within 5 s of a `taskset`).
Fix (`8872e7b`, `SOLARUS_CPUISOLATE`, default ON): engine pins the render thread to CPU0 and its
other threads to CPU1 (sweep every 600 frames); launcher moves the USB IRQ and other user
processes (not Main_MiSTer) to CPU1 and execs the engine at **nice −10**, which is what holds
against Zaparoo (408 ms → 1.1 ms in the same trace); `core_watch.sh` restores the saved masks
when the engine exits (verified: IRQ 34 mask 3, state file removed).

## Not fixed (measured, no dip attributed)

- **Sim-step judder:** `MainLoop` runs a 10 ms fixed step, so displayed frames alternate 1 and 2
  steps (mean 1.67). Every frame is now shown, but game time advances 10 or 20 ms per frame.
  Changing it touches `System::timestep` (game timing); needs its own A/B and sign-off.
- **Full-root overlay re-uploads:** 188 of 28,140 iso2 frames re-uploaded the 320×240 root
  (+4.8 ms emit); 42 of them ran long (~21 ms). No window dropped below 59.
- **Memory headroom:** the engine holds ~300 MB anonymous RSS of 491 MB. A long `SCHED=1`
  trace in tmpfs got it OOM-killed twice; keep traced captures ≤ 90 s.
- The map-change hitch (200–800 ms, outside active play) is unchanged.

## Open gate

Pacing changed when frames are published. The fabric's tear-freedom argument is unchanged (the
snapshot writes the inactive buffer; the reader latches once per vblank), but **no visual check
has been done** — operator visual gate pending.
