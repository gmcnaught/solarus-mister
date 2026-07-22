# Stage 5 (A9 track) — full A9-drill capture

Rebuild-free A9 cost attribution on the two A9-bound scenes. Uses the SHIPPED engine
+ `Solarus_20260722.rbf`; every banner is emitted under `SOLARUS_BLITTER_DIAG=1`.

## Fixed spots

- **map 119** (parallax overworld): save1.dat, teleport `from_dungeon_10`. Moving = hold
  DOWN. (Identical to `README-stage5.md`, so A9 numbers line up with the fabric A/B.)
- **map 3** (pattern worst-case interior, per `solarus-quest-tilemap-census`): save1.dat, teleport `out_link_house` (town, outside the hero's house — a
  stable standing spot exercising map 3's dense pattern set). Moving = hold DOWN.

## Run

Sequence around the FPGA-track agent — only ONE engine may run on the fabric.

    MAP=119 DEST=from_dungeon_10 TAG=map119 bash scripts/perf/capture_a9_drill.sh
    MAP=3   DEST=<chosen>        TAG=map3   bash scripts/perf/capture_a9_drill.sh

Each run writes `docs/superpowers/data/stage5-a9/drill-<TAG>.txt` with STANDING then
MOVING windows for the full banner stack. Post-process:

    python3 scripts/perf/a9_decompose.py docs/superpowers/data/stage5-a9/drill-map119.txt

## Choosing the map-3 spot

`sol...:teleport("3","<dest>")` needs a destination that exists on map 3. List them from
the quest, or teleport to map 3's default entrance and confirm via the `CURMAP_NOW=3`
echo the capture script already prints. Pick a standing spot that renders map 3's dense
pattern set (the worst-case tilemap) with the hero idle. Record the chosen `DEST` above
and in the decision doc.

## Reproducibility gate

Two independent runs at the same spot must agree within window jitter. The capture tails
5 windows/banner so >=3 clean 60-frame windows are available for the median.
