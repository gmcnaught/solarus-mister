# Map 119 fabric-throughput — tiled-pattern-fill op (design)

**Date:** 2026-07-22
**Status:** CLOSED — Phase 0 measured, **NO-GO** on the Phase-1 tiled-fill op
(`docs/superpowers/2026-07-22-map119-bgfillprobe-attribution.md`). The "~15 ms non-comp
slice" premise below came from a **regressed intermediate Phase-2 capture**; the actual ship
runs map 119 at 29.5 fps **vsync-paced at 30**, fabric_hw 20.63 ms with comp = 72%. The probe
cut fabric 3.8 ms for **0 fps** (savings → sleep); the wall is the **compositor**, not the
per-cell fill walk. Kept for the record; do not build Phase 1.
**Scope:** improve map-119 fps without impacting visual correctness
**Predecessors:** Stage 5 Phase 1 (source cache, PR #136), Phase 2 (FB→DDR3, PR #138)

## Problem

Map 119 (the quest's only real parallax scene) is **fabric-bound** at ~19.6 fps
after Stage 5 Phase 1/2. The starting premise for this investigation was that the
parallax layer is "treated as an animated tileset instead of static tiles with a
camera offset." That premise is **already half-solved** and must not be re-litigated:

- The #52 camera-independent work records parallax tiles **once** as a resident
  bucket with a per-frame bias (`cam/ratio − camera`); a camera move never rebuilds
  the list. The list-level "static tiles with a camera offset" architecture ships.

What remains is a different, measured bottleneck.

## Evidence (HW A/B captures, `docs/superpowers/data/stage5/ab-*-map119.txt`)

Standing on map 119, from the fabric's own `clk_sys` counters (`[blitter hwperf]`):

| Build | comp (pixel blend) | non-comp fabric | fabric_hw | fps |
|---|---|---|---|---|
| Baseline (512 B src cache) | 54.4 ms (82%) | ~12 ms | 66 ms | 11.9 |
| **Current ship (128-blk cache)** | **14.9 ms (49%)** | **~15 ms (51%)** | **30 ms** | **19.6** |

Phase 1 crushed the compositor cost (54→15 ms). The residual **~15 ms non-comp
fabric slice** — command / tile-list / grid **walking** plus per-cell **FRT/CFT
pattern resolution + SRCFILL** — was always present and is now **half the frame**.

This is per-**cell** fabric overhead, not per-**command** host overhead. That is
exactly why `SOLARUS_GRIDOV` (which collapses host command *count* but leaves the
fabric's per-cell walk intact) measured **perf-neutral** on 119. Any lever that only
reduces host emit will also be neutral; the lever must reduce the fabric's per-cell
work.

### Map-119 layer-0 structure (decoded from `zsdx/data`)

Layer 0 is covered opaquely by **two single-pattern repeating tiles**:

- **Ground** = pattern **7**, an **8×8 fully-opaque** tile, one `tile{}` tiled across
  **640×504** (5040 whole-map cells; not parallax, grids normally).
- **Sky** = pattern **1201**, an **8×8 fully-opaque parallax** tile, one `tile{}`
  tiled across **640×248** (2480 whole-map cells; separate parallax bucket).

Per frame the fabric re-resolves these same 1–2 patterns across ~1200 visible cells.
All five parallax patterns are opaque or binary (1201/1147/1150/1151 fully opaque,
1146 binary — verified by decoding `1.tiles.png` alpha), yet **the parallax path is
excluded from the opaque fast-copy path** (patch 0006), so the opaque sky pays the
alpha-**BLEND** + dst-read tax for no visual reason.

## Strategy — two phases

### Phase 0 — Attribute the non-comp slice (engine-only, NO RTL)

Prove or refute that the per-cell walk of the two big opaque background fills is the
dominant non-comp cost **before** committing to new RTL.

- **Probe:** env flag `SOLARUS_BGFILLPROBE=1`. At record time, detect the two large
  single-pattern tiles (ground 7 over 640×504; sky 1201 over 640×248) and emit each
  as **one existing `BLT_OP_FILL`** (solid color) instead of tiled tile draws.
  Deliberately visually wrong (flat color) — this measures fabric time, not
  correctness. A solid fill is resolve-free and cheaper than a real tiled-fill, so
  its `fabric_hw` delta is an **upper bound** on the Phase-1 payoff.
- **Measure (HW A/B, existing counters):** `fabric_hw`, `comp`, non-comp
  (= fabric − comp), and the `p0` BLEND count, standing on map 119. Compare probe-on
  vs probe-off on the current ship RBF (no rebuild needed — engine-only).
- **Confounder to verify:** confirm whether `BLT_OP_FILL` routes through
  `comp_pipeline` (counted in `comp`) or a separate fill unit, so the comp-vs-non-comp
  attribution is not muddied. Note the answer in the results doc.

**Decision gate:**
- Non-comp drops **≥ 3–4 ms (~10%+ fps)** → per-cell walk confirmed → build Phase 1.
- Delta small → walk is not the cost → pivot (revisit blend-vs-copy, or accept map 119
  is near its fabric floor). Cheap lesson, one hour spent instead of an RTL cycle.

### Phase 1 — Tiled-pattern-fill COPY op (RTL, CONTINGENT on Phase 0)

- **New opcode** — a fresh number, **never** the reserved `OP_BGPLANE_WRITE = 8`.
  Header carries: dst rect, one 8×8 pattern src ref, parallax/camera offset
  `(ox, oy)`, opaque COPY.
- **Fabric:** `comp_pipeline` resolves the pattern **once**, then streams it tiled
  across the rect with modulo addressing at II=1 — no per-cell FRT/CFT resolve.
- **Host:** renderer detects a single-pattern opaque "fill tile" (dst ≫ pattern) at
  record time and emits the tiled-fill op for both the static ground and the parallax
  sky (parallax supplies the biased offset the bucket already computes).
- **Why no seam:** live tiling means no baked plane and no plane extent to clip, so
  none of the deleted-bake seam class (#122/#123) applies. The #122/#123 seams came
  from plane-extent clipping, not from tiling.

### Validation discipline

- Every claim **measured**, not asserted; HW A/B against the current ship RBF.
- Visual correctness confirmed by the **operator**, never self-declared
  (per `solarus-no-self-declared-visual-validation`).
- Phase 1 additionally: host tests + a bit-exact sim (tiled output vs a software
  reference) before HW.

## Non-goals / rejected

- **Reject: cache the background composite.** The `paramstab` counter exists to
  measure frame-to-frame stability, but scrolling thrashes any cached plane and this
  is essentially the deleted per-layer plane bake — real seam-correctness risk.
- **Not sufficient alone: opaque-COPY for parallax** (remove the fast-copy
  exclusion). Trims only the comp half; the fabric still walks every cell, so it
  cannot touch the ~15 ms non-comp slice. May be folded into Phase 1 as the COPY
  mode of the tiled-fill op, but is not a standalone lever.
- Do **not** re-open the parallax list-rebuild question — already solved (#52).
- Do **not** reuse reserved wire constant `OP_BGPLANE_WRITE = 8` / `BLT_F_BGCOV`.

## Open questions (resolve during execution)

1. Exact `fabric_hw` delta from Phase 0 (sets Phase-1 go/no-go and expected ceiling).
2. Does `BLT_OP_FILL` count under `comp` or separately? (attribution confounder)
3. Phase 1 opcode number and header byte layout (pick a fresh op; update
   `blitter_ref.h` + `test_wire_constants.py`).
4. Whether the static ground (non-parallax) and parallax sky share one op path or
   need distinct offset handling.
