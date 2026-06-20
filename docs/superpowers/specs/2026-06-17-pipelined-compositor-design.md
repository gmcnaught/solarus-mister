# Pipelined compositor — design (Spec A)

**Status:** design / awaiting review
**Date:** 2026-06-17
**Scope:** the fabric 2D blitter (`fpga/rtl/blitter_top.sv` + memory path). Spec A of a
two-spec effort. **Spec B** (Barycentric triangle front-end + parallel compositors,
for gmloader/OpenGL) is deferred and is explicitly designed *toward* by this spec.

Origin: this design distills the transferable ideas from Beasley, Clarke & Watson,
*"An OpenGL Compliant Hardware Implementation of a GPU Using FPGA-SoC Technology"*
(ACM TRETS 2020) — specifically the **issue-interval-1 pipelined compositor** — and
applies them to the existing, HW-validated CV1000-style blitter. The paper's
floating-point/GLSL/DPR machinery is deliberately **not** adopted (see §3).

---

## 1. Context & problem

The blitter offloads Solarus's 2D compositing from the Cortex-A9 onto the fabric: the
A9 emits a per-frame display list into a DDR command ring; the fabric walks it and
composites into the double-buffered framebuffer; the unchanged `openbor_video_reader`
scans it out. This is validated on real hardware.

**But on the heavy overworld the fabric is the bottleneck.** Measured
(`fpga/docs/60fps-bottleneck-hunt.md`, P2, readcache RBF, 60-frame windows):

| Quantity | Measured |
|---|---|
| Frame period | ~49 ms (20.4 fps) |
| Fabric composite | **44 ms (90%)** |
| A9 emit | 5 ms (10%) |
| Composited pixels/frame | 320×240 × ~6 overdraw ≈ 460k |
| **Effective fabric throughput** | **~10.5 Mpix/s** |
| f2h clock | ~100 MHz |

So the fabric spends **~9–10 cycles per composited pixel**. The cause is structural:
the compositor in `blitter_top.sv` is a **multi-cycle FSM** that walks
`S_BLIT_RDSRC → S_BLIT_GOTSRC → S_BLIT_GOTDST → S_BLIT_BLEND1 → S_BLIT_BLEND2 →
S_BLIT_WR → S_PIX_ADV` per pixel/qword. Heavy latency-amortisation already exists
(source-qword read cache, dst-qword write-coalesce, 2-stage blend split for timing),
but those make a multi-cycle-per-pixel FSM *fewer*-cycle-per-pixel — they do not make
it stream.

For comparison, the Beasley pipeline hits **179 Mpix/s on the same Cyclone V** because
every stage runs at **issue interval 1: one valid pixel out per clock, back-to-back**.
The project's own finding agrees that *blend/interp is the per-pixel cost, not fetch*
(`[[blitter-compute-bound]]`); the paper quantifies the same thing — its flat shader is
issue-interval 1, its interpolating shader issue-interval 5.

### The binding constraint: the arbiter forbids per-pixel DDR traffic

`fpga/rtl/ddr_blitter_arb.sv` makes the blitter a **guest** on the single f2h DDR port:
the video reader is the default owner, and the blitter "borrows the bus for a single
transaction only in a genuine reader-idle gap, then yields." A 1-px/clock compositor
therefore **cannot** issue a DDR beat per pixel. An on-chip working buffer fed/drained
by **bursts** is not an optimisation here — it is a precondition for the pipeline to
exist. (This is the same wall the parked `origin/burst-dma` branch hit: sim-validated,
timing not met at ~−0.385 ns.)

## 2. Goals & success criteria

| # | Goal | Measure (how verified) |
|---|---|---|
| G1 | Composite at ~1 px/clock steady-state | `tb_profile.sv` cyc/px for COPY/COLORKEY/CONST_ALPHA/PALPHA drops from ~7–10 to ~1–2 |
| G2 | Solarus overworld reaches ~60 fps with **no engine-side change** | `[blitter timing]` diag: fabric ≤ ~16.67 ms on the 6× overworld; `escape=0` |
| G3 | **Bit-exact** to the existing golden | `fpga/sim/` Icarus equivalence (`tb_blitter_*`) passes unchanged against `blitter_ref` |
| G4 | Zero-risk rollback | New datapath is selectable; the proven FSM remains the default until G1–G3 are met on HW |
| G5 | Timing closure at the f2h clock | Quartus STA: worst-case setup slack ≥ 0 on the new path |

Non-goal metrics: A9 emit time (already 5 ms / negligible — the paper's "don't
optimise non-bottleneck stages" discipline says leave the front-end alone).

## 3. Scope

**In (Spec A):**
- A new **pipelined span compositor** datapath: source span → issue-interval-1
  ColorMixer → dest tile, for the existing **rect** primitives (FILL, BLIT:
  COPY/COLORKEY/CONST_ALPHA/PALPHA), with H/V flip and clipping.
- On-chip **source line buffer** and **destination tile buffer**.
- A **burst memory engine** (source fetch + dest flush as aligned sequential bursts)
  through the arbiter, plus the timing-closure work to make it meet f2h timing.
- A control-word **selector bit** to choose new-pipeline vs legacy-FSM at runtime.

**Out (deferred to Spec B):**
- The Barycentric triangle front-end (rotated/scaled/UV-interpolated textured
  triangles) — the actual gmloader/OpenGL payload.
- Parallel tile compositors (replicating the bottleneck stage).
- Depth buffer / perspective / 3D.
- Floating-point, programmable GLSL-equivalent shaders, dynamic partial reconfiguration
  (all explicitly dropped — fixed-point, fixed-function only).

This spec leaves clean **seams** for Spec B (§7) so it is a refactor, not a rewrite.

## 4. Architecture

Approach **(B): a second, selectable datapath** — mirrors how `C_SRCSEL` (issue #19)
added the SDRAM source path without disturbing the proven DDR3 path. Rejected
alternatives: (A) rewrite the FSM in place (risks the timing-tuned shipping core); (C)
clean new core (discards the validated arbiter/ring/handshake/scanout integration).

```
 cmd ring ─▶ CmdDecode ─▶ SpanSetup ─▶ ┌─────────────── new pipelined datapath ───────────────┐
 (unchanged   (reuse        (per-blit   │                                                       │
  ring +       S_FETCH..     clip/flip   │  SrcFetch ─burst─▶ [SOURCE line buf] ─▶ ColorMixer    │
  handshake)   S_DECODE)     setup,      │                       (1 px/clock pipeline)          │
                             emit spans) │                          │ key/α/palpha/tint         │
                                         │                          ▼                            │
                                         │              [DEST tile buf] ─burst─▶ FB (DDR)        │
                                         └───────────────────────────────────────────────────────┘
                         └─(C_PIPE==0)─▶ legacy per-pixel FSM (unchanged, default until proven)
```

**Module boundaries** (each independently testable, names provisional):

| Module | Does | Depends on |
|---|---|---|
| `comp_span_setup` | Per-blit: clip rect → 320×240, flip-aware source start, decompose into row-spans; emit `(src_addr, dst_addr, len, blend, flags)` span descriptors | decoded `blt_cmd_t` |
| `comp_src_fetch` | Burst-read a span's source row into the source line buffer; serve texels to the mixer in order | burst engine, SDRAM/DDR3 src select (`C_SRCSEL`/`F_SRC_SDRAM`) |
| `comp_mixer` | **Issue-interval-1 pipeline**: per clock take (src texel, dst texel, params) → composited pixel. COPY / COLORKEY skip / CONST_ALPHA / PALPHA, divide-free /255 | source line buf, dest tile buf |
| `comp_dest_tile` | On-chip dest **full-width band** (320 px wide × `BAND_H` rows): serve dst-read for blend RMW from the band (not DDR), accumulate writes with byte-enables, flush by burst | burst engine |
| `comp_burst` | **Fresh** aligned sequential burst read/write master; requests through `ddr_blitter_arb` honouring reader priority | `ddr_blitter_arb` |

The **front-end is reused verbatim**: control-block poll, `submit_seq`/`done_seq`
handshake, ring walk-until-`END`, video-control-word write, double-buffer flip, and the
`C_TARGET==2` off-screen bg-cache route all stay as in `blitter_top.sv`. Only the inner
per-pixel loop is replaced.

## 5. Phase 1 — pipelined span compositor + on-chip buffers

Replace the inner loop with a feed-forward pipeline. The mixer is the Beasley
issue-interval-1 stage: a fixed number of pipeline registers, a new pixel entering and a
finished pixel leaving every clock.

**ColorMixer pipeline (per clock, all modes RGB565 / ARGB4444):**
1. fetch src texel from line buffer; fetch dst texel from dest tile (RMW source for
   blends — served on-chip, never a DDR beat)
2. extract channels + alpha (const = `c_alpha`; PALPHA = `{A4,A4}`); colorkey compare
3. multiply-accumulate `src*a + dst*(255−a)` per channel
4. divide-free /255 reduce (`div(t)=(t+128+((t+128)>>8))>>8`) + RGB565 pack
5. write-enable resolve (skip on keyed / A4==0) → merge into dest-tile lane

Stages 2–4 already exist as `S_BLIT_BLEND1/BLEND2` logic — Phase 1 **converts them from
sequential FSM states into registered pipeline stages** so they overlap across
consecutive pixels instead of being walked per pixel. Semantics stay byte-identical to
`blitter_ref` (this is the whole point of G3).

**On-chip buffers:** source line buffer (one+ source rows, BRAM); dest **full-width
band** buffer — 320 px wide × `BAND_H` rows of dest qwords in BRAM — that absorbs the
blend RMW reads and write-coalescing the FSM does today against DDR. Full-width is
chosen so each band flush is a long, fully-sequential 64-bit burst per row (maximal DDR
efficiency, simplest address generation); `BAND_H` is the one BRAM/throughput tuning
knob, sized in the Quartus fit. Skip-write fast paths (colorkey, A4==0,
fully-offscreen cull) are preserved.

**Backpressure:** if `comp_src_fetch` underruns (burst not yet returned) or
`comp_dest_tile` is flushing, the mixer stalls via a ready/valid handshake — keeping
correctness while the steady-state stays 1 px/clock (AXI-stream-style qualifiers, as the
paper's modules use).

**Exit of Phase 1:** `tb_profile` shows ~1–2 cyc/px in simulation against the existing
single-beat DDR model; `tb_blitter_*` equivalence still passes. (Phase 1 alone, on the
behavioural model, demonstrates the compute pipeline; real throughput needs Phase 2.)

## 6. Phase 2 — burst memory engine + arbiter / timing closure

Phase 1's pipeline is worthless until it can be **fed and drained by bursts** — single
beats through the guest arbiter cap throughput regardless of compute speed.

- `comp_burst` is built **fresh** (not resurrected from `origin/burst-dma`): a clean
  aligned sequential burst read/write master. A full-width band flush is one long
  sequential burst per row (320 px = 80 qwords), so address generation is trivial and
  burst payload amortises DDR read latency without starving scanout (the reader keeps
  priority; the blitter fills genuine idle gaps). `origin/burst-dma` /
  `origin/fabric-4wide-burst` are read for **lessons only** (what hit the −0.385 ns
  wall), not reused.
- Reconcile with `ddr_blitter_arb`: extend the borrow protocol to hold a grant for a
  whole burst (the arbiter already "holds the grant until a read burst's beats have all
  returned" for the reader — generalise that for the blitter master).
- **Timing closure is the hard deliverable of this phase.** The paper's discipline guides
  the fix — protect the lowest-fmax stage (the mixer), add pipeline registers only there,
  and keep burst-control logic off the critical path. Building the burst master fresh
  (rather than inheriting `burst-dma`'s structure) is a deliberate bet that a clean
  design closes timing more easily than patching the parked one.

**Exit of Phase 2:** Quartus STA worst-case setup slack ≥ 0 at the f2h clock; on HW the
overworld is video-correct, `escape=0`, fabric ≤ ~16.67 ms (≈60 fps).

## 7. Contract, interfaces & Spec B seams

- **Host/fabric contract unchanged.** `blt_cmd_t`, opcodes, blend modes, formats, flags,
  the 32-byte ring entry, and the `submit_seq`/`done_seq` handshake
  (`patches/mister/blitter/blitter_ref.h`, `docs/blitter-protocol.md`) are **frozen**.
  The host emitter needs no change to drive the new path.
- **Selector:** add a frame-level control word (next free control-block offset after
  `C_SRCSEL=7`, e.g. `C_PIPE=8`): `0` = legacy FSM (default), `1` = new pipeline. Host
  writes `0` until the pipeline is HW-proven (G4). No aliasing of shipping control words.
- **Spec B seams (designed for, not built):**
  - `comp_span_setup` is the only rect-specific module. Spec B adds a *parallel*
    `tri_setup` (Barycentric edge-function) that emits the **same span/pixel descriptor
    interface** (`src_addr/coverage/interp-weights, dst_addr`) into the **same**
    `comp_mixer`. So triangles reuse the entire Phase-1/2 datapath.
  - The mixer's per-pixel input already carries (src, dst, alpha) — Spec B extends it
    with interpolated `(u,v)` and vertex `rgba` from the S/T weights; reserve those input
    ports now.
  - `comp_burst` + `comp_dest_tile` are primitive-agnostic and are what Spec B
    replicates for parallel tile compositors.

## 8. Verification strategy (refmodel-first, matches house methodology)

1. **Golden unchanged.** `blitter_ref` stays the bit-exact contract; Spec A adds *no*
   new semantics, so the existing golden is the oracle.
2. **Sim equivalence.** Run the new datapath through the existing `fpga/sim/tb_blitter_*`
   (copy, blend, coalesce, palpha, system) against the behavioural DDR model; diff the
   framebuffer qword-for-qword. All must pass with `C_PIPE=1` exactly as with `C_PIPE=0`.
3. **Cycle profile.** `tb_profile.sv` (already reports cyc/px and DDR-wait-vs-compute
   split) quantifies G1 before/after.
4. **Arbiter/burst sim.** `tb_ddr_blitter_arb`, `tb_arb_borrow`, `tb_arb_reader_burst`
   extended for the burst grant; assert the reader never starves.
5. **HW.** Build the RBF; run the heavy overworld; read `[blitter timing]` (fabric ms,
   fps, escape). G2/G5 are HW gates. Keep the device on the legacy-FSM RBF until the
   pipeline RBF passes a visual check (counters can lie about render health —
   established 2026-06-14).

## 9. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Pipeline doesn't meet f2h timing (the −0.385 ns wall) | The whole point of Phase 2; fresh clean burst master (not the parked `burst-dma`); pipeline only the mixer; keep `C_PIPE=0` fallback shipping |
| On-chip buffers exceed BRAM budget | `BAND_H` is the tuning knob — shrink the dest band height (full width is kept for burst efficiency); reuse source-line BRAM; measure in Quartus fit early |
| Blend bit-mismatch vs golden | Reuse the verified divide-free /255 form verbatim; gate on `tb_blitter_*` before HW |
| Reader starvation from blitter bursts | Cap burst length; reader keeps default ownership; assert in `tb_arb_*` |
| Real bottleneck turns out to be DDR bandwidth, not compute | `tb_profile` + HW timing diag distinguish compute-bound vs bandwidth-bound before committing parallelism (that's Spec B anyway) |

## 10. Relationship to the engine-side overdraw cache

Orthogonal and multiplicative. This spec cuts **cycles-per-pixel** on the fabric and
generalises across Solarus / gmloader / OpenBOR; the background-composite cache
(`60fps-bottleneck-hunt.md` P4) cuts **pixel-count** and is engine-specific and
correctness-risky. Either reaches ~60 fps on the static overworld; together they leave
large headroom, and the pipelined compositor is the one that also helps engines without
a cacheable static background. Neither blocks the other.
