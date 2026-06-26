# v2-blitter escape elimination — IMPLEMENTATION PLAN (3 subagents)

**Date:** 2026-06-25
**Design:** `2026-06-25-v2-blitter-escape-elimination-design.md`
**Status:** Planning → ready to dispatch. Clip already shipped (see below).

## What changed vs the design

1. **Clip is DONE, host-side, engine-only** — branch `fix/intro-host-side-clip`
   (commit `5cce663`), HW-validated. `emit_draw` now clamps each 1:1 blit's dst to
   `[0,FB_W)×[0,FB_H)` (flip-aware src shift) via `clip_to_fb()`. This fixed the
   actual intro regression (clouds-over-bars + flashing from OOB SDRAM writes).
   **Therefore clip is REMOVED from Workstreams B (RTL) and C (sim).** No
   `BLT_OP_SET_CLIP`, no clip register, no clip-mask C golden. If an arbitrary
   sub-FB SDL clip rect ever needs honoring, it's a host-side follow-up in `emit_draw`,
   not fabric work.
2. **Remaining v2 scope = tint (color-mod) + ADD + MULTIPLY**, BLIT path only.
   Diag confirms these are NOT hit by the intro (`escape: tint=0 mode=0`) — proactive
   escape elimination, not a live bug.
3. **ADD/MULTIPLY also apply to FILL** (folded in per user 2026-06-25). The `fill()`
   path (renderer `:1180`) currently escapes ADD/MULTIPLY fills; v2 makes them
   `BLT_OP_FILL` commands carrying `blend_mode` (COPY/ADD/MULTIPLY), so `g_esc_mode`
   reaches 0 across fills + blits. No ABI growth: FILL reuses the `blend_mode` byte
   (today ignored on FILL); the "source" channel for the blend is `cmd.color`.
4. **Out of scope (unchanged):** rotation/scale (affine, deferred), ARGB8888 source,
   any CPU composite, growing the 32-byte command.

## FROZEN ABI (locked by orchestrator — do not renegotiate)

All three workstreams build against these exact definitions in
`patches/mister/blitter/blitter_ref.h`. They are added by the orchestrator before
dispatch so the header is a stable contract; agents treat the *values* as fixed.

### Blend modes (`cmd.blend_mode`, append after `BLT_BLEND_PALPHA=3`)
```
BLT_BLEND_ADD       = 4   /* per-channel saturating: out = min(src+dst, chan_max)        */
BLT_BLEND_MULTIPLY  = 5   /* per-channel: out = src*dst / chan_max (divide-free reduction) */
```
Channel widths are RGB565 (R5,G6,B5); `chan_max` = 31/63/31. `src` is the (optionally
color-modulated — see below) source pixel; `dst` is the framebuffer pixel.

### Color-mod / tint — a FLAG, orthogonal to blend_mode (not a blend mode)
```
#define BLT_F_COLORMOD 0x40u   /* next free bit (0x01..0x20 taken) */
```
- When `BLT_F_COLORMOD` is SET, `_pad[0]=cr, _pad[1]=cg, _pad[2]=cb` (u8 each) carry
  the modulation. The source pixel is modulated per-channel **before** the blend
  equation: `src_ch' = src_ch * mod_ch / 255` (computed at the dest channel width after
  the standard R4/G4/B4 or R5/G6/B5 expansion; divide-free /255 reduction, same idiom
  as `blt_blend565`).
- When CLEAR, no modulation — the color-mod stage is a true no-op (skip it). v1 commands
  wrote `_pad=0` with the flag clear, so they remain correct (no accidental black tint).
- Host only SETS the flag when `(cr,cg,cb) != (255,255,255)`.
- Color-mod composes with ANY blend_mode (COPY/COLORKEY/CONST_ALPHA/PALPHA/ADD/MULTIPLY):
  modulate source, then run the blend. This matches Solarus (color-mod ⟂ blend mode).

### Command stays 32 bytes / 8×u32
`_pad[3]` (was reserved "future tint/zoom") now holds cr,cg,cb. No struct growth. ✓

### C-reference golden DECLARATIONS (bodies = Workstream C, in blitter_ref.c)
```
uint16_t blt_tint565(uint16_t src565, uint8_t cr, uint8_t cg, uint8_t cb);  /* color-mod */
uint16_t blt_add565 (uint16_t src565, uint16_t dst565);                     /* saturating add */
uint16_t blt_mul565 (uint16_t src565, uint16_t dst565);                     /* multiply */
```
`blt_execute` (the C model) must apply color-mod (when `BLT_F_COLORMOD`) before the
blend, and handle blend_mode 4/5 — so sim TBs compare RTL vs this model.

## Workstreams (parallel, against the frozen ABI)

### Agent A — ABI / C++ emitter + map_blend
- **Owns:** `patches/mister/blitter/blt_emitter.{c,h}`,
  `patches/mister/mister_blitter_renderer.cpp` (map_blend only).
- **Tasks:**
  - Emitter: add a colormod-carrying blit (sibling `blt_blit_mod(...,cr,cg,cb)` OR an
    optional setter); existing `blt_blit` stays colormod-free (flag clear). Pack cr,cg,cb
    into `_pad`, set `BLT_F_COLORMOD`. Existing callers must be untouched in behavior.
  - `map_blend` (`:900`): delete the `why=3` reject → when `cr/cg/cb != 255`, set
    `BLT_F_COLORMOD` + pass the triple (keep the existing alpha/colorkey logic). Delete
    the `why=5` reject → map `BlendMode::ADD→BLT_BLEND_ADD`, `MULTIPLY→BLT_BLEND_MULTIPLY`.
    Keep `why=1/2` (rotation/scale) escaping.
  - Wire the colormod triple from `map_blend` through `emit_draw` to the emitter (note:
    `emit_draw` already clips — colormod must ride alongside, post-clip).
- **Deliverable:** engine compiles (armhf Docker), `g_esc_tint`/`g_esc_mode` reachable=0.
- **Branch:** off `fix/intro-host-side-clip` (so it has the clip change).

### Agent B — RTL compositor
- **Owns:** `fpga/rtl/comp_pipeline.sv`, `comp_mixer.sv`, `blitter_top.sv`,
  `comp_defs.vh`, `blitter_defs.vh` (mirror the new enum/flag values).
- **Tasks:**
  - Parse: blend_mode now 0..5; flags include `BLT_F_COLORMOD=0x40`; read `_pad` bytes.
  - **color-mod stage** (II=1): `src_ch * mod_ch / 255` per channel, gated by the flag
    (identity = true no-op), applied to the source before the blend.
  - **ADD** (II=1): per-channel saturating `min(src+dst, chan_max)`.
  - **MULTIPLY** (II=1): per-channel `src*dst / chan_max` (divide-free reduction).
  - Report fmax/II; expectation is II=1 holds (blend ALU is off the SDRAM/scanout
    bottleneck). If a stage threatens fmax, document the tradeoff (design §3.6).
- **Deliverable:** builds; bit-exact to C goldens in sim (coordinate with C).
- **Branch/worktree:** isolated (RTL files disjoint from A/C).

### Agent C — Verification
- **Owns:** `patches/mister/blitter/blitter_ref.c` (golden bodies + `blt_execute` modes),
  `fpga/sim/tb_*` (new TBs), `fpga/sim/run_sims.sh`.
- **Tasks:**
  - Implement `blt_tint565`/`blt_add565`/`blt_mul565` (divide-free, bit-exact intent) +
    extend `blt_execute` to apply color-mod + blend 4/5.
  - Sim TBs modeled on `tb_blitter_blend_pipe` proving RTL == C golden bit-for-bit for
    COLORMOD, ADD, MULTIPLY (incl. colormod×{COPY,CONST_ALPHA,PALPHA} composition).
  - Gating entries in `run_sims.sh` (respect fast-gate/nongating convention).
- **Deliverable:** gating sims green vs the model.
- **Branch/worktree:** isolated (`blitter_ref.c` disjoint from A's `blt_emitter.c`).

## Sequencing & dependencies

```
orchestrator: freeze ABI in blitter_ref.h (enum/flag/_pad/decls)  ── must precede all
   │
   ├── A (emitter + map_blend)        ─┐
   ├── B (RTL ops)                     ├─ parallel, disjoint files, frozen ABI
   └── C (goldens + model + sim TBs)  ─┘
                                        │
orchestrator: integrate — A+C land first (engine+sim, no RBF). B lands with an RBF
   build; A+B ship in LOCKSTEP (design decision #3) since engine emits the new
   blend codes the RBF must understand. Gate the merge on C's bit-exact sims + an HW
   A/B that drives content exercising tint/ADD/MULTIPLY (diag tint=0 mode=0 + screenshot).
```

Key contract risks (from design, still live): colormod default semantics (the
`BLT_F_COLORMOD` flag is the safeguard); ADD/MULTIPLY RGB565 rounding must match the C
golden exactly. Clip×carry-forward risk is GONE (clip is host-side, never touches the
FB→FB copy).

## Success criteria
1. `map_blend` no longer returns false for tint/ADD/MULTIPLY (`why=3`/`why=5` removed).
2. Each new op bit-exact vs its C reference in a gating sim.
3. `g_esc_tint` + `g_esc_mode` = 0 on exercising content; HW screenshot matches.
4. II=1 maintained (or tradeoff documented within the SDRAM/scanout bottleneck).
5. On-wire command remains 32 bytes.
