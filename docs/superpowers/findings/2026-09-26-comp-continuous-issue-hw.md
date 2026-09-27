# Continuous issue + fill chase: map 119 on hardware (2026-09-26, .62)

Branch `perf/comp-continuous-issue`. D = counters-only RBF (run 36285746960, RTL
of build C + the profile block). E = D + continuous issue + fill chase (run
36287242739). Same engine, same device boot, parked at 119/from_dungeon_10,
standing, no dialog, `scripts/perf/fabric_prof.sh` (40 frames).

| per frame | D | E |
|---|---|---|
| fabric frame | 17.74 ms | 16.11 ms |
| compositor busy (pipe) | 11.69 ms | 8.86 ms (-24 %) |
| - pixel issue | 5.67 | 5.67 |
| - pipeline bubble | 2.44 (9.0 cyc/span) | 0.29 (1.1 cyc/span) |
| - source-fill wait | 1.98 | 2.32 |
| - span control | 1.20 (4.4 cyc/span) | 0.18 (0.7 cyc/span) |
| - span collect | 0.38 | 0.38 |
| outside compositor | 6.05 ms | 7.25 ms |
| cyc/px (pipe) | 2.06 | 1.56 |

26,68x spans and 2,722 blits per frame in both; 20.9 px/span.

The compositor is now fill-bound (source-fill wait is the largest non-issue
bucket). "Outside compositor" grew by 1.2 ms. Inferred, not yet measured: the
ring-dbuf tear guard (S_SNAP_GATE) holds a frame that finishes faster until
the reader opens a new vblank window, and frame cycles include that wait. The
next profile iteration should split the outside-compositor time (snap gate,
snapshot drain, DDR read waits, stage).

Displayed smoothness, fpsdip `TOUR=119:from_dungeon_10`, 120 s, seed 1, full
v1.2.0 launcher (mem_wc, CPU isolation), 2 runs each:

| build | osd windows < 55 fps | long frames | p50 / p99 period ms | 60-fps 1-s windows |
|---|---|---|---|---|
| A old line buffer | 5.2 %, 6.5 % | 7.44 %, 7.65 % | 16.9 / 22.1-22.3 | 42, 41 of 76 |
| C registered RAM + drain 3 | 2.5 %, 2.5 % | 4.07 %, 4.54 % | 16.8 / 21.8 | 48, 47 of 77 |
| E continuous issue + chase | 1.2 %, 1.2 % | 2.77 %, 4.00 % | 16.7 / 20.1-20.2 | 63, 61 of 77 |

Pixels: parked screenshots golden-identical between D and E (dozens of shots),
tinted hero (`set_color_modulation{255,96,96}`) identical 3/3. A wandering
entity occasionally enters the bottom-left corner. It appears in both builds
(D 2/30, E 1/30), so it is game content, not a compositor error.

Timing (E, seed 3): no compositor violations; clk_sys fails only SDRAM DQ
capture (WNS -0.144); pll_hdmi -0.090 (ascal). ALMs 15,085 (+435 vs build C),
RAM blocks unchanged.

Harness note: `m119ab.sh` must zero both fabric control blocks at MENU before
loading the core. A killed engine leaves C_SUBMIT != C_DONE, and the next core
chases that stale ring and hangs the engine in preload. That happened twice
here before the harness zeroed them (the known stale-control mode, not a new
defect). During those runs the arbiter health word showed 34k orphan read
beats.
