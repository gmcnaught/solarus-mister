# Map 119 `comp` overdraw attribution — measure-first design

**Date:** 2026-07-23
**Branch:** `feat/map119-tiled-fill`
**Status:** design (awaiting spec review)
**Supersedes the redirect in:** `docs/superpowers/2026-07-22-map119-bgfillprobe-attribution.md`
(attribute `comp` before designing a fix)

## Problem

Map 119 (parallax) ships at **29.5 fps, vsync-paced to 30**. To reach 60 fps the fabric
frame must fit under **16.7 ms**; it currently runs **fabric_hw 20.63 ms = comp 14.89 ms +
non-comp 5.74 ms**, so ~**3.9 ms** must be cut.

Two facts fix the target on `comp`:

1. **Non-comp alone cannot do it.** The Phase-0 `SOLARUS_BGFILLPROBE` A/B collapsed the big
   static fills and bottomed non-comp at 2.95 ms → fabric floor **16.83 ms** (missed 60 fps by
   0.13 ms), *and* delivered **+0 fps** (savings went to `sleep`; the frame is vsync-paced, not
   fabric-saturated). NO-GO recorded.
2. **`comp` is not fetch-bound.** Phase 1 enlarged the P_SRC cache to `SRC_BLOCKS=128`
   (`cache-knee.md`): map119 hit-rate **97.4 %**, cyc/px 9.20→2.38. P_SRC is invalidated every
   vsync (coherency), so the compulsory-miss floor caps hit-rate at ~**98.5 %** (full-assoc
   bound); the max legal size (256) reaches only 98.3 % / 2.32 cyc/px — **~0.4 ms**, a rounding
   error against 3.9 ms. At 97.4 % hit, fetch-stall is **~4 % of comp** (~0.5 ms). A bigger or
   even persistent cache cannot recover the gap.

Therefore `comp` (14.89 ms) is **pixel-work bound**: the compositor writes each 320×240 screen
pixel on the order of **8× per frame** (big background/ground fills + parallax layers + static
tilemap + sprites + the full-screen overlay all stack). The durable 60 fps lever is **overdraw
reduction**. Before designing that fix we must attribute the overdraw: *which* categories stack,
and *where* on screen.

## Non-goals

- No RTL / RBF change in this step (attribution only; ships on current `Solarus_20260723.rbf`).
- No per-pixel blend-cost microarchitecture work yet (that is a possible later lever if the
  cross-check shows large unmodeled per-pixel cost).
- Not re-opening the tiled-fill op (closed NO-GO) or the cache size (closed by `cache-knee.md`).

## Approach

Engine-only trace of every emitted dst rectangle for **one settled frame**, analyzed offline
into a per-category composited-pixel breakdown + an overdraw heatmap. Chosen over a HW
category-ablation suite because: (a) engine-only, one capture vs. 3–4 operator device legs;
(b) Phase 1 proved fetch-stall is ~4 % of comp, so a pure dst-area model has no fetch confound;
(c) the offline heatmap shows *where* overdraw concentrates, which an ablation delta cannot.

### Component 1 — engine trace (`patches/mister/mister_blitter_renderer.cpp`)

A single helper, gated on the env flag, recording the dst rectangle that becomes fabric
composite work at each of five emit sites:

```
void comptrace_rec(const char* cat, int dx, int dy, int w, int h, int blend, int opacity);
```

- Gate: `SOLARUS_COMPTRACE=1` (read once at construction into `bool comptrace_on`, matching
  the existing `SOLARUS_FETCHTRACE` pattern).
- Frame selection: dump for **one frame per scene**, gated exactly like `SOLARUS_FETCHTRACE`
  (a `res_building`/scene marker + a per-scene latch), emitting a `COMP_FRAME <map>` marker
  first, then one `COMP` line per command, then a `COMP_END` line. One frame is steady-state:
  static tiles + fills + parallax composite identically every frame; sprites are a minor
  animated addition (documented caveat).
- Sites and categories (dst already in FB space — alias offset applied where relevant):

  | site (line ref) | category | rect source |
  |---|---|---|
  | `fill()` (~2592) | `fill` | `where` + alias offset, per fill |
  | `emit_draw()` (~2116) | `blit` | clipped dst rect; sub-tag `blit_full` when w×h == FB |
  | `blt_sprite_channel_push()` (~2291) | `sprite` | one line per sprite entry `e` |
  | tilemap grid emit (~2463) | `tilemap` | one line per **on-screen** static tile entry (8×8) |
  | `emit_overlay_composite()` (~1470) | `overlay` | `0,0,FB_W,FB_H` (the last PALPHA) |

- Output format (stderr, one per line, greppable):
  `COMP <cat> <dx> <dy> <w> <h> <blend> <op>`
  where `blend` is the numeric `BLT_BLEND_*` and `op` the 0–255 opacity.

The five call sites are the only edits; the helper is a no-op unless the flag is on and the
one-frame latch is armed, so the shippable path is unchanged (same discipline as
`SOLARUS_BGFILLPROBE` / `SOLARUS_FETCHTRACE`).

### Component 2 — offline analyzer (`scripts/perf/comp_overdraw.py`)

Pure-Python, no deps beyond the stdlib (optional PNG via a tiny PPM writer to stay
dependency-free). Input: a captured log containing one `COMP_FRAME … COMP_END` block.

- Parse `COMP` lines; clip each rect to `[0,FB_W) × [0,FB_H)` (320×240).
- Accumulate a per-pixel coverage grid (`int[FB_H][FB_W]`) and per-category clipped-area sums.
- Report:
  1. Per-category composited-pixel total and **% of total composited pixels**.
  2. Mean overdraw (total composited px / 76 800) and **max overdraw** (hottest pixel).
  3. ASCII heatmap (downsampled to ~80×48, overdraw bucketed to shades); optional `--png`.
  4. **Cross-check line:** given `--comp-cyc <N>` (from the `[blitter hwperf]` capture) and
     `--cyc-per-px 2.38`, print modeled composited px = `N / 2.38` and the ratio to the traced
     sum. Ratio ≈ 1.0 ⇒ attribution trustworthy; ≫ 1.0 ⇒ unmodeled per-pixel comp cost
     (blend RMW / span setup) — itself a finding.

### Capture recipe (operator, one engine-only leg)

1. Host-apply the series + build engine-only:
   `scripts/apply_patch_series.sh` → `SOLARUS_SKIP_APPLY=1 scripts/docker_run.sh scripts/build_engine.sh`
   → verify `strings build/armhf/libsolarus.so.1.6.5 | grep COMPTRACE` and artifact mtime.
2. Refresh `deploy/` from `build/armhf`, `./deploy.py --no-rbf`.
3. On device, launch with `SOLARUS_COMPTRACE=1` (+ existing diag env), teleport to map119
   (`from_dungeon_10`), confirm `CURMAP=119`, capture stderr to a log; also capture a normal
   `[blitter hwperf]` line for `--comp-cyc`.
4. `scripts/perf/comp_overdraw.py <log> --comp-cyc <cyc/frame from hwperf> > report.txt`.

## Combination step (PR 140's dormant 3.8 ms is additive)

PR 140's `SOLARUS_BGFILLPROBE` cut **3.80 ms** of fabric (2.79 non-comp + 1.01 comp) that was
**swallowed by vsync `sleep`** — fps stayed 29.5 because the frame never crossed the 16.7 ms
threshold (probe-only floor 16.83 ms, missed by 0.13 ms). That saving is real but dormant
behind an off-by-default flag. The overdraw cut this spec targets and the bgfill saving are
**additive**, and crossing 16.7 ms is a **threshold** effect: a comp cut that looks like +0 fps
in isolation can unlock the full jump to 60 when stacked on the bgfill saving.

So the implementation MUST include an explicit **combination A/B leg**, run once an overdraw
fix exists:

1. Baseline: overdraw-fix OFF, `SOLARUS_BGFILLPROBE=0`.
2. Overdraw-fix ON alone → Δcomp, fps.
3. `SOLARUS_BGFILLPROBE=1` alone → (re-confirm PR 140's 16.83 ms).
4. **Both ON** → fabric_hw and fps. **Success = fabric_hw < 16.7 ms AND fps jumps toward 60.**

If the combination crosses 16.7 ms and yields real fps (not more `sleep`), the win is the
*pair*, and the follow-up is to productionize both together — turn the `BGFILLPROBE`
upper-bound approximation into a correct shippable fill AND land the overdraw cull — rather than
judging either lever in isolation (which is what made each read as +0 fps). If even the
combination stays above 16.7 ms, the overdraw fix must be deepened before the pair is worth
shipping.

Note the probe is an *upper bound* (cheapest solid fill, over-removed bboxes), so the combined
number is a **ceiling** on what the pair delivers; a correct bgfill would land slightly higher
than the probe's fabric time.

## Decision gate (what this step outputs, not a fix)

The analyzer report + heatmap **name the leading overdraw category and its screen region.**
Expected outcomes and the fix each points to:

- **Background fills + parallax dominate and are largely occluded** by the opaque ground/tilemap
  → design an occlusion cull (skip compositing pixels a later opaque layer fully covers), the
  lead hypothesis. Biggest structural win.
- **Overlay (full-screen PALPHA) is a large flat contributor** → shrink it to a dirty sub-rect
  (HUD/dialog bbox) instead of full-screen every frame.
- **Cross-check ratio ≫ 1.0** (traced px ≪ modeled) → comp is dominated by per-pixel blend cost,
  not overdraw count → the lever is RTL blend/span throughput, a different track.

Each outcome becomes its own measure-first design; this spec commits only to producing the
attribution.

## Risks / caveats

- **One-frame steady-state:** sprites animate; a single frame slightly under-counts sprite
  variability. Mitigation: the marker can be re-armed for K frames if sprite share looks
  material; default is one frame (matches `cache-knee.md` methodology).
- **Fabric transparent-pixel early-out:** if the compositor skips fully-transparent source
  spans, dst-area over-counts sparse sprites/tiles. The cross-check ratio surfaces this; it does
  not affect the fills/parallax/overlay conclusion (those are dense).
- **Tilemap on-screen filtering:** must count only cells intersecting the screen, not the whole
  resident region (camera-independent residency spans beyond 320×240). Use the same clip the
  emit path already applies.

## Cross-refs

- `docs/superpowers/2026-07-22-map119-bgfillprobe-attribution.md` (the redirect this executes)
- `docs/superpowers/data/stage5/cache-knee.md` (closes the cache-size lever)
- `[[solarus-map119-bgfill-attribution]]`, `[[solarus-stage5-fabric-fetch-bound-source-cache]]`,
  `[[solarus-parallax-fabric-bound-perf]]`
