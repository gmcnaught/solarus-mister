# SOLARUS_BGPLANE default-on — design

**Status:** approved (2026-07-13), ready for implementation plan.
**Base:** `origin/master` @ `58d2691` (Paletted composition v1 / PR #120 merged).
**Branch:** `feat/bgplane-default-on`.
**Goal:** flip `SOLARUS_BGPLANE` from opt-in to default-on so the per-layer static
plane bake ships, collapsing the parallax map's per-frame BLEND flood into baked
plane COPYs — the large fabric-side perf win — without reintroducing background
corruption.

## Motivation

HW perf baseline (2026-07-12, `[[solarus-parallax-fabric-bound-perf]]`):

- **Town** — A9-bound (~29 fps, `eng_cpp` limiter). Unaffected by bgplane.
- **Parallax map** — **fabric-bound** (~15 fps, ~68 ms period, fabric ~35 ms).
  `alias_blits ≈ 706,800/60fr`, **~1,500 BLEND draws/frame**: the parallax layers
  are composited per-tile every frame instead of baked. Baking each static layer
  once and compositing ~6 plane COPYs collapses that ~35 ms fabric cost.

The bgplane bake is the lever for that win. It has been opt-in
(`SOLARUS_BGPLANE`, default OFF) because of past background-corruption bugs.

## Background: what changed with PR #120 (the key unblock)

`#84` (background tile corruption after the ~6th distinct tileset) was **not a
bgplane-specific bug**. Its root cause was source-atlas overflow: gameplay
tilesets missed `pal_handles`/`immutable_set` (pointer-identity mismatch), got
staged **mutable** into the 4 MiB INTER region, and the ~6th distinct tileset ran
past the region ceiling → **garbage source atlas**. Any consumer of that atlas
corrupts — the resident tile-list path (bgplane OFF) *and* the bgplane bake path.
The "cumulative, after N transitions, varies by map" symptom is exactly the Nth
distinct tileset overflowing.

PR #120 fixed this in **shared source-staging code** (`res_bucket_params`,
`mister_blitter_renderer.cpp`): a missed tileset is marked immutable → routed to
the 64 MiB PERM region (no overflow), and paletted tilesets stage once as an 8bpp
index atlas + CLUT. **Every** bgplane bake bucket flows through
`res_bucket_params` (via `resident_record_static`, `:3091`), so the bake
structurally inherits the fix. `#84` closes with PR #120 on both paths.

**Consequence for this work:** the scariest historical item — cumulative
multi-transition corruption — is resolved upstream. What remains is small.

## Current state (already in place on the base branch — no work)

The full bgplane × PAL8 datapath already exists as a side effect of the #120
refactor:

- Bake cell-paint (`bake_background_plane_step`, `:2875`) calls the shared
  `res_bucket_emit_tex(...)`, which emits paletted tile-lists (PAL8 + `pal_id`/
  `base` in the header colour field) whenever the tileset is paletted.
- The fabric decodes `COMP_PAL8` → CLUT → `{A4, RGB565}` into the WORK framebuffer
  (`comp_fbram`), then `OP_BGPLANE_WRITE` packs WORK + coverage into the plane.
- `#102` (stale-WORK RGB clear-before-tiles) and `#109` (ring-overflow retry/
  advance) are landed, with `tb_bgplane_maptrans.sv` covering the transition case.

**What has never been done:** bgplane and PAL8 have never been *exercised
together*. The plumbing is present but unproven in that combination, and
bgplane-ON has never been HW-validated post-#120.

## The one genuinely bgplane-specific open defect

**Partial-alpha bake bug** (`tb_bgplane_equivalence.sv:634`, non-gating
KNOWN-DEFECT). It is architectural in the bake→pack path and **orthogonal to
source format / PAL8**:

- `comp_fbram` (WORK) is RGB565 — **no alpha channel**. A translucent tile
  composited into WORK blends `α·src + (1−α)·WORK`; over the cleared-to-black
  WORK that is `α·src` — a *darkened* RGB — and the source `A4` is consumed and
  discarded here.
- `bgplane_coverage.sv` is **1 bit per lane** ("painted" / "not"), not alpha
  (`mem0[wr_qw] <= !wr_clear`).
- `OP_BGPLANE_WRITE` packs ARGB4444 with RGB = darkened WORK pixel, **A = binary
  coverage** → the pixel bakes **opaque, darkened-toward-black**.

PAL8 changes only the front of the pipe (index→CLUT→`{A4,RGB565}`, the same
`{A4,RGB565}` ARGB4444 decode produced); the alpha-less WORK blend + binary-
coverage pack downstream is identical. So PAL8 does not fix it.

**Blast radius is narrow.** The bake only consumes **static (non-animated)**
tiles; animated water is composited per-frame and never baked. Only *static
translucent* tiles (pots/shadows/still-water decorations) trip it. Whether MoSDX
has visible static-translucent content is a HW-observable question.

**Decision (approved): treat it as a HW-gated contingency, not up-front work.**
Flip default-on, HW-validate; only if screenshots show static-translucent
corruption apply the host-side mitigation.

## Design: three pieces

### Piece 1 — Prove bake × PAL8 in sim (correctness gate)

Add a deterministic sim testbench that composes the two proven paths (bgplane
bake + PAL8 CLUT decode) for the first time:

- Upload a small CLUT bank with a known transparent index and a known opaque
  index.
- Bake a PAL8 source layer containing both indices into a plane
  (`OP_TILELIST` cell-paint → `OP_BGPLANE_WRITE`).
- Read the plane back and assert: opaque-index pixels equal `CLUT[index]`
  (resolved RGB565); transparent-index pixels remain the background/lower layer.

Model it on `tb_pal8_tilelist.sv` (PAL8 tile-list decode) and the existing
`tb_bgplane_*` bake/readback scaffolding. Expected to pass with **no RTL change**
(both halves are individually proven); if it fails it localizes a real fabric gap
before any HW cycle. Runs in `fpga/sim` under the standard runner.

**Interface / boundaries:** source read = PAL8 through the CLUT; output plane =
resolved RGB565 (or ARGB4444 for a blended layer) — unchanged plane format, so
scanout/replay are untouched.

### Piece 2 — Partial-alpha bake bug: HW-gated contingency (no up-front work)

No code up front. The mitigation, **only if HW shows static-translucent
corruption**, is host-side and additive:

- In the static-bucket routing, when bgplane is enabled, keep **opaque** static
  buckets on the bake path and route **translucent** static buckets
  (`blend == PALPHA` / per-pixel-alpha) to the per-frame resident tile-list
  (BLEND) instead of baking them.
- This requires the resident-list emit to cover the excluded buckets so they do
  not vanish — the split, not just a skip.

Kept out of scope unless triggered; the RTL 4-bit-alpha-coverage fix (make
`bgplane_coverage` carry `A4` and the pack use it) is a documented future
enhancement, not part of this work.

### Piece 3 — Flip default-on + HW validation

- Flip `SOLARUS_BGPLANE` to default-on via the same `mister_flag_default_on`
  mechanism PR #120 used for `SOLARUS_PALETTE`; `SOLARUS_BGPLANE=0` stays as the
  explicit revert. The default flip commit lands **after** HW validation passes.
- HW validation (device `192.168.20.81`, `deploy.py`; refresh `deploy/` from
  `build/armhf` first). No RBF re-synth expected — bgplane × PAL8 is host-only on
  top of the #120 32-bank RBF — unless Piece 1 surprises us. Confirm:
  - **Objective:** engine healthy; parallax map `[blitter p0]` BLEND draws/frame
    drop sharply (from ~1,500) and fabric period falls; no ring overflow /
    upload-fail escalation in the bake.
  - **Human visual (required — `[[solarus-no-self-declared-visual-validation]]`):**
    walk the `[[solarus-84-luaconsole-teleport-repro]]` route through ≥6 distinct
    tilesets and across several dungeon transitions; backgrounds render clean
    (this is the bgplane-ON confirmation that the shared #84 fix carries). Capture
    screenshots via the mrext ws `kbd:screenshot` recipe.
- **Contingency gate:** if backgrounds are clean → land the default-on flip. If
  static-translucent corruption appears → apply Piece 2, re-validate, then flip.

## Testing strategy

- **Sim (gating):** new bake × PAL8 TB (Piece 1) green; full `fpga/sim` suite
  still green (`tb_bgplane_*`, `tb_pal8_*`, `tb_tilelist*`). The existing
  partial-alpha KNOWN-DEFECT case stays non-gating.
- **HW (gating for the flip):** Piece 3 objective + human-visual gates.
- **Revert:** `SOLARUS_BGPLANE=0` restores the shipping tile-list path at any
  point.

## Out of scope

- RTL re-synth / new RBF (not expected; the #120 32-bank RBF is the target).
- The 4-bit-alpha-coverage RTL fix for partial-alpha (future enhancement).
- Town's A9/`eng_cpp` bottleneck (separate lever,
  `[[solarus-enemy-per-update-cost-simd]]`, `[[solarus-60fps-campaign]]`).
- Double-buffering (fabric-add; does not help either scene).

## Execution note

Implemented **inline**, not via subagents: a short sequential chain (sim TB →
flip → HW-validate → conditional host fix) around a HW-validation loop that only
the operator can drive. No independent file-partitionable parallel work.
