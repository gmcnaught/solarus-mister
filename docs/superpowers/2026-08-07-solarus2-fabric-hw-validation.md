# Solarus 2.x fabric line — first HW validation (.81, 2026-08-07)

Closes item 1 of `docs/solarus2.md` §"Not yet done" ("Nothing here has run on the
device"). Run after rebasing the 2.x branch onto master at `ddf043f`, i.e. with
the SDRAM_CLK phase fix (5079 → 2540 ps, `65f0be1`), the write-combining DDR
mapping (`c2a146d`) and the jtframe re-vendor (`ddf043f`) all in.

## Setup

| | |
|---|---|
| device | `192.168.20.81` |
| bitstream | `Solarus_20260807.rbf` (master CI run `31194793632`), sole `_Other/Solarus_*.rbf` on the device |
| 1.6 engine | `deploy.py --diag`, `libsolarus.so.1.6.5` sha1 `0b431b1a…` |
| 2.x engine | `build_engine2.sh` (default = fabric: `patches/series2` + `patches/mister`) + `deploy_engine2.sh`, upstream pin v2.1.0 |
| quest | `mystery_of_solarus_dx.sol` (1.6-format, unchanged, run by both engines) |
| selection | `SOLARUS_ENGINE=2` added to / removed from the device's `diag.env` between legs — the only thing that varied |
| DDR mapping | `[blitter] ddr mapping: write-combined (/dev/mem_wc)` on **both** legs |

Both legs launch through the deployed `solarus_run.sh` (not a direct binary
invocation), so the engine selection, the `mem_wc` allowlist check and the
blitter exports are the real shipping paths.

## Leg 1 — title screen, objective judge

`scripts/debug/shot_capture.sh` + `shot_score.py`, golden =
`docs/superpowers/data/wc-ab/shots/1-title.png` (the operator-confirmed .81
capture from the write-combining gate).

| engine | textmatch | altratio | oddzero | verdict |
|---|---|---|---|---|
| 1.6.5 | **100.0 %** | 0.78–0.81 | 0.39 | PASS |
| 2.1.0 fabric | **100.0 %** | 0.78–0.81 | 0.39 | PASS |

`textmatch` is the gate (the footer band; the title cycles day/night so
whole-frame `match%` is not a gate). The two engines land on the same three
metric values to two decimals.

## Leg 2 — gameplay, 1.6 vs 2.x on the same parked scene

The title screen does not exercise the riskiest 2.x delta — the camera scroll
moving into a per-surface `View`, which `mister_dst_view_offset()` compensates
for. That only shows in-game. So both engines were driven to the *same* place
via the lua-console-over-held-FIFO recipe: load `save1.dat`, teleport to map
119 / `from_dungeon_10`, `set_position(424, 600, 0)`, `freeze()`, screenshot.
Map identity confirmed on the live engine: `CURMAP=119`.

**Exact-pixel agreement between the 1.6 and 2.x frames: 99.92 %** (best of 3×3
frame pairs; the 3×3 matrix spans 99.58–99.92 %, and the spread is frame-phase
of the animated tiles — the same spread appears comparing 1.6 frames to each
other). Captures: `data/solarus2-hw/shots/v{16,2}-map119.png`.

A wrong view offset does not produce a 99.9 % match; it composites the map at
map coordinates. This is the evidence that the `SOLARUS_MAJOR_VERSION >= 2`
switch in the shared renderer is right.

Frame rate on that scene, from the `[blitter …]` banners
(`data/solarus2-hw/v{16,2}-map119-banners.txt`):

| | 1.6.5 | 2.1.0 fabric |
|---|---|---|
| fps | 40.6 | 39.4 |
| bound | A9 | A9 |
| A9 total | 22.6 ms | 22.3 ms |
| … lua | 6.9 ms | 6.0 ms |
| … emit | 5.1 ms | 5.5 ms |
| … present | 10.6 ms | 10.8 ms |
| `fabric_hw` | 20.25 ms | 18.41 ms |
| `dfq_drop` | 0 | 0 |

Read that carefully: it is **one scene with a frozen hero and a dialog box up**,
which is dominated by the overlay/dialog cost that both lines share. It is
**not** evidence that the missing 1.6 perf series costs nothing — that series
targets entity/Lua/draw-walk work that a frozen scene barely exercises. The
honest claim is "same order, A9-bound in both, no gross regression on this
scene".

## What this does and does not close

Closes: the 2.x fabric line boots, preloads the whole-quest atlas, composites
the title and a real gameplay scene through the FPGA compositor, and agrees with
the shipping engine pixel-for-pixel on a matched scene, on the current
bitstream, with write-combining active.

Still open:

1. **Motion.** Both legs park a frozen hero. Scrolling, map transitions and the
   scroll-fabric path are unmeasured on 2.x.
2. **Soak.** Single ~4-minute runs per leg. No teleport soak, no long play.
3. **Perf under load.** See the caveat above; a moving overworld and a
   script-heavy scene are the scenes that would size the missing perf series.
4. **Audio.** Not evaluated (screenshot judge only).
