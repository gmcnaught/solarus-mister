# v2-blitter escape elimination — clip + tint + ADD/MULTIPLY

**Date:** 2026-06-25
**Status:** Design approved; planning phase (parallel agent workstreams)
**Scope owner:** FPGA graphics pipeline

## Problem

`MisterBlitterRenderer::map_blend` (`patches/mister/mister_blitter_renderer.cpp:900`)
is the gate that turns a Solarus draw into a hardware blit command. When it cannot
express an op with the v1 blitter it returns `false`; the caller calls `escape()`
(`:625`) which only sets `frame_escaped = true` and bumps diag counters. **There is
no longer any fallback** — the SDL readback / parallel software composite was
deliberately removed (header comment `:7-10`, "fabric is the sole renderer"). So an
escaped op is **silently dropped**: the pixels never appear; whatever was in the
carry-forward buffer remains.

Today's escape list:

| Escape | `why` | Site | Nature |
|--------|-------|------|--------|
| clip rect | (implicit) | never read in `map_blend` | **silent correctness bug** — clip rects are ignored, not even escaped |
| color-mod / tint | 3 | `:908` (`cr/cg/cb != 255`) | feature gap |
| ADD / MULTIPLY blend | 5 | `:936` (`default`) | feature gap |
| rotation | 1 | `:904` | **out of scope** (deferred affine spec) |
| scale / zoom | 2 | `:905-906` | **out of scope** (deferred affine spec) |

## Decisions (locked)

1. **Fabric-native.** All in-scope escapes become fabric blit commands the
   compositor honors. No CPU composite, no f2h frame pixels — the sole-renderer
   invariant is preserved.
2. **Affine deferred.** Rotation (`why=1`) and non-1.0 scale (`why=2`) need a
   fractional-coordinate sampler that breaks the issue-interval-1 (II=1) span model
   `comp_pipeline` is built on. They keep escaping; they get their own later spec.
3. **Engine + RBF ship together.** No command-format version negotiation, no
   safe-degrade path. Both sides change in lockstep.
4. **No growth of the 32-byte on-wire command** (see ABI section). This is a hard
   constraint: the command ring entry and DDR layout are fixed at 32 bytes / 8×u32
   (`blitter_ref.h:92-120`).

## Reference: proven principles (Beasley/Bath FPGA-SoC OpenGL GPU)

`../openGL-FPGA/reference/3410357.md` — an OpenGL-compliant GPU on the **same
Cyclone V SoC as MiSTer**, ARM-offload model. Transferable, validated principles:

- **Issue-interval / critical-path analysis** (§3.1, §3.6, §5). Stages off the
  critical path may have II>1 and reuse logic "for free" provided they do not drop
  below the system bottleneck. Our bottleneck is SDRAM bandwidth + scanout, not the
  blend ALU — so tint/ADD/MULTIPLY added as per-pixel stages are essentially free
  on throughput. Target II=1 to avoid touching the band-RMW cadence at all.
- **Bounding-box rasterization** (§3.5). Derive a bbox from min/max coords, clamp
  the scan, skip outside pixels. → **clip** = clamp the dst span to the clip rect
  per row. `emit_draw_clipped` (`:986`) already demonstrates the host-side span
  clamp idiom.
- **Fragment-shader analogues** (§4.2). flat shade II=1; gradient "mix"=lerp II=5
  (= our existing CONST_ALPHA). tint/ADD/MULTIPLY are simpler than their lighting
  shader: integer, II=1 feasible, hundreds–low-thousands ALMs.
- **Fixed vs floating point** (§3.2). Float is only for 3D precision; fixed-point
  saves resources. → RGB565 blend math is integer/fixed.
- **Vertex-shader matrix-multiply variants** (§4.1, Table 1: Z-rotate / generic /
  hybrid / resource). → seeds the deferred affine spec (rotation/scale = 2×3 affine
  + sampler) with a ready resource/throughput tradeoff menu. *Not in this spec.*

## Architecture

Four layers, three concurrent workstreams (A=ABI/C++, B=RTL, C=verification).

### 1. ABI / command layer (no command growth)

`blitter_ref.h` `blt_cmd_t` is 32 bytes / 8×u32, on-wire DDR ring entry. Resolution
that avoids growing it:

- **color-mod (cr,cg,cb — 3 bytes)** → packed into the existing reserved
  `_pad[3]` (`blitter_ref.h:119`, already earmarked "future tint/zoom"). Identity =
  `0xFF,0xFF,0xFF`; v1 commands wrote zero, so the **default must be interpreted as
  identity** — Agent A decides the encoding (e.g. store `cr-? ` or document that
  `000000` means "no mod"; simplest: a `BLT_F_COLORMOD` flag bit gates whether the
  pad holds a real tint, keeping zero-pad backward-meaningless). Pick one, make it
  explicit.
- **clip** → new sticky state op `BLT_OP_SET_CLIP`. Carries x0,y0,x1,y1 in the
  existing rect-shaped fields (reuse `dst_x/dst_y` + `w/h` slots; no new fields).
  The compositor latches a clip register; every subsequent BLIT/FILL is masked to
  it until the next `BLT_OP_SET_CLIP`. Matches SDL's persistent
  `SDL_RenderSetClipRect` semantics; per-blit byte cost = 0. A full-FB clip
  (0,0,FB_W,FB_H) is the reset/"no clip" value, emitted when SDL clears its clip.
- **ADD / MULTIPLY** → two new `blend_mode` enum values
  (`BLT_BLEND_ADD`, `BLT_BLEND_MULTIPLY`) after `BLT_BLEND_PALPHA=3`. Free.

### 2. C++ `map_blend` + emitter (Workstream A)

- `blt_emitter`: add `blt_set_clip(e, x0,y0,x1,y1)` emitting `BLT_OP_SET_CLIP`;
  extend `blt_blit` (or add a sibling) to carry the color-mod triple; add the two
  blend-mode constants.
- `map_blend` (`:900`): delete the `why=3` reject → pack color-mod from
  `infos.color`. Delete the `why=5` reject → map `BlendMode::ADD`/`MULTIPLY` to the
  new blend codes. Keep `why=1/2` escaping (affine).
- Clip plumbing: read the SDL clip rect (currently never consulted) and emit a
  `BLT_OP_SET_CLIP` when it changes. Decide the change-detection point (per-draw vs
  on SDL clip-set hook) so we don't spam SET_CLIP every blit.
- Diag: `g_esc_tint` / `g_esc_mode` must reach 0 on exercising content; keep the
  counters for regression detection.

### 3. RTL compositor (Workstream B)

In `comp_pipeline` (the II=1 band-RMW per-pixel datapath) + `blitter_top`
command parse:

- **clip register**: latch the SET_CLIP rect; mask writes (skip-write) for pixels
  outside it. Prefer span-clamp at issue (don't iterate masked pixels) over
  per-pixel write-suppression, mirroring the paper's bounding-box scan.
- **color-mod stage**: per-channel `out = src_ch * mod_ch / 255` (divide-free /255
  reduction, the same idiom as `blt_blend565` / `blt_blend4444`). Applied to the
  source pixel before the blend equation. Identity mod must be a true no-op.
- **ADD**: per-channel saturating `min(src+dst, max)` in RGB565 channel widths.
- **MULTIPLY**: per-channel `src*dst / max` (divide-free reduction).
- All as **II=1** stages; report fmax impact. If any stage threatens fmax below the
  system bottleneck, document the issue-interval tradeoff (paper §3.6) — but the
  expectation is II=1 holds.

### 4. Verification (Workstream C)

This project gates compositor work on **bit-exact sim**. Each op needs:

- A C-reference golden in `blitter_ref.h` (extend the `blt_blend565` /
  `blt_blend4444` family with `blt_tint565`, `blt_add565`, `blt_mul565`, and a
  clip-mask predicate).
- A sim testbench in the `tb_blitter_*_pipe` / `tb_comp_*` family proving the RTL
  matches the C golden bit-for-bit (model on the existing `tb_blitter_blend_pipe`).
- Gating entries in `fpga/sim/run_sims.sh` (respect the fast-gate / nongating
  convention already in that file).
- HW A/B recipe: a quest scene that exercised each escape, diag counters → 0,
  screenshot diff vs expected (use the established devmem screenshot + joypad-inject
  recipe).

## Data flow (one blit, post-change)

```
SDL draw ─▶ map_blend ─▶ [clip changed? emit BLT_OP_SET_CLIP]
                       └▶ emit BLT_OP_BLIT {blend∈{...,ADD,MUL}, colormod in _pad}
DDR ring ─▶ blitter_top parse ─▶ comp_pipeline band-RMW:
   span clamp to clip reg ─▶ src fetch ─▶ color-mod ─▶ blend eq ─▶ RMW write
```

## Out of scope

- Rotation / non-1.0 scale (affine) — deferred spec.
- ARGB8888 source format.
- Any CPU-composite or readback fallback (architecturally retired).
- Growing the 32-byte command (explicitly disallowed).

## Success criteria

1. `map_blend` no longer returns false for clip/tint/ADD/MULTIPLY; `why=3`/`why=5`
   paths removed.
2. Clip rects honored (silent-drop correctness bug fixed).
3. Each new op bit-exact vs its C reference in a gating sim.
4. `g_esc_tint` and `g_esc_mode` = 0 on exercising quests; HW screenshot matches.
5. fmax / II unchanged (II=1 maintained), or the tradeoff is documented and within
   the SDRAM/scanout bottleneck.
6. On-wire command remains 32 bytes.

## Risks

- **color-mod default semantics**: v1 wrote zero into `_pad`; zero must not be
  misread as a black tint. A gating `BLT_F_COLORMOD` flag is the safe encoding.
- **SET_CLIP cadence**: emitting per-blit would bloat the ring; needs change
  detection tied to SDL clip state.
- **MULTIPLY/ADD in RGB565 channel widths**: rounding must match the C golden
  exactly (divide-free reduction), or bit-exact sim fails.
- **clip × carry-forward**: clip must not interfere with the per-frame FB→FB
  carry-forward copy (that BLIT must always run full-FB / clip-reset).
