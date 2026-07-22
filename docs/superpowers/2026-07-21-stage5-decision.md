# Stage 5 — map-119 baseline + limiter decision

**Date:** 2026-07-21
**Engine:** `libsolarus.so.1.6.5` sha1 `8a56d13f` (origin/master post-Stage-4; TILEMAPCH default-ON,
confirmed `[MiSTer blitter] tilemap channel ENABLED`). RBF `Solarus_20260721.rbf` (B2 tilemap).
**Scene:** MoSDX map 119 (parallax), save1, teleport `from_dungeon_10`, hero idle (standing) and
holding DOWN (moving). Raw log: `data/stage5/stage5-map119-raw.log`; windows:
`data/stage5/stage5-{standing,moving}-window.txt`.

> **Note:** the device was found on a stale Jul-8 pre-migration engine; the correct `8a56d13f`
> engine was deployed (`./deploy.py --no-rbf`, sha1 verified on device) before capture. The plan's
> "no rebuild/deploy needed" Global Constraint was therefore false and is superseded by this note.

## Raw numbers (standing, representative window)

```
[blitter timing]  fps=11.8 period=84.9ms | fabric=45.1ms A9=32.2ms sleep=7.7ms | pipeline_ceiling=19.0fps
[blitter hwperf]  fabric_hw=66.41ms comp=54.41ms comp%=82% (6537268 cyc/frame) | bound: FABRIC
[blitter p0]      draws=1799 fills=60 | blend NONE=120 BLEND=1739 ADD=0 MUL=0 | distinct_tex=17
[blitter engcpp]  eng_cpp=17.6ms = entities=8.0 + hero=1.5 + tileset=2.1 + sound=2.3 + other=3.7 | steps/fr=8.50
[blitter resident] buckets=6 patterns=153 entries=4071 patch_pass=60 tl_used=32568/524288 valid=1 fatal=0
[blitter a9split] A9=32.2ms = lua=21.5ms + emit=4.2ms + present=6.5ms
[blitter cvt]     cold_upload=0 | dyn_reup=4608000 px (8.79 MB, big=60) | sdl_fallback=0
```
Moving window is materially identical (fps 11.7, fabric_hw 66.6ms, BLEND 1721).

## Derived metric (Task 1 tool)

`tilemap cyc/px = 28.37  verdict=FAIL  grid_path_live=False` — **grid_path_live=False**: BLEND draws
present, so map 119 is on the **per-tile replay path, NOT the grid-walk**. "tilemap cyc/px" is
therefore not a meaningful acceptance number for this scene — the grid is not walked.

## Verdict — fork rule applied

- `fabric_hw_ms (66) >> a9_ms (32)`, period 85ms vs 16.7ms budget → **FABRIC-bound, heavily saturated.**
- `[blitter p0] BLEND=1739 ≠ 0` → **grid path NOT live**; the tilemap channel falls back to replay.

**Comparison to the pre-migration Jul-12 baseline** (`solarus-parallax-fabric-bound-perf`): ~14.7fps,
~1500 BLEND/frame, 4071 entries. Now: 11.8fps, ~1739 BLEND, 4071 entries. **The retained-scene
migration (Stages 1–3b) did NOT improve map 119 — it is unchanged-to-slightly-worse.**

**Root cause (the limiter):** the Stage 3b grid-walk (`BLT_OP_TILEMAP`) is for **opaque,
non-overlapping static** tiles. Map 119's parallax layers are **semi-transparent (BLEND) and
overlapping** — an "unbatchable blend/overlap bucket" that `blt_grid_build*` rejects, so every
bucket falls back per-bucket to the per-tile BLEND replay: **1739 BLEND tiles/frame → comp = 54ms**
(82% of the 66ms fabric). This is structural, not a tuning gap: parallax is exactly the case the
grid cannot express.

**Secondary (minor):** `[blitter cvt] dyn_reup=4,608,000 px (8.79 MB) / 60-frame window`. Corrected
arithmetic: the banner is per-60-frames and `g_reup_px += w*h` counts once per dirty surface
(renderer:1791), so this is **one 320×240 surface re-upload per frame** (~0.15 MB/frame) — the
overlay/dirty-surface refresh path (`reupload_in_place`), NOT the parallax source. It is not the
fabric limiter and is deprioritized. (An earlier read of this as "60 reups/frame" was a
per-window/per-frame error.)

## Consequence for the plan

The plan's mechanical fork ("FABRIC-bound → RTL `tilemap_unit` prefetch") is a **category error** for
map 119: prefetching a grid the scene never uses cannot help. The real limiter is *parallax composite
+ dynamic re-upload cost*, which is a genuine design problem, not a prefetch tune.

## Lever — deferred to a data-driven brainstorm (user decision 2026-07-21)

**The limiter is the 1739 BLEND tiles/frame parallax replay (comp = 54ms).** The dyn-reup is minor
(1 overlay surface/frame) and deprioritized. Lever options for the BLEND replay:
- (a) **extend the grid to overlapping/blended parallax** (multi-pid-per-cell + blend support) —
  RTL + host; makes map 119 use the grid path.
- (b) **per-layer parallax plane bake** — the deleted approach; was the prior parallax perf fix but
  caused #122/#123; contradicts the retained-scene no-bake premise.
- (c) **reduce redundant BLEND work** — if overlapping tiles composite the same pixels multiple
  times, cut the redundant passes; or exploit that parallax layers are static-per-frame (only the
  scroll offset changes) to avoid re-BLENDing unchanged coverage.

Next: drill the dyn-reup mechanism, then brainstorm the lever, then re-spec Stage 5's lever.
References: `solarus-parallax-fabric-bound-perf`, `solarus-quest-tilemap-census`, CLAUDE.md tilemap-channel note.
