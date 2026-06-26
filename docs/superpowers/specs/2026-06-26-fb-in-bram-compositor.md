# FB-in-BRAM compositor — design sketch (single-buffer first)

**Status:** SKETCH for review (2026-06-26). Not yet a plan. Branch context: v2-blitter-base.
**Rationale memory:** [[fpga-fb-in-bram-feasibility]] (the ~3-4x lever, fit-report budget,
why latency/contention-bound not bandwidth). Supersedes the prefetch-lane idea
([[fpga-psrc-cache-single-request]]) and the strip-race alternative (considered, rejected —
removes the framebuffer's rate-decoupling which Solarus needs while over-budget).

## Goal

Keep the 320×240 RGB565 dest framebuffer **resident on-chip in M10K**; the compositor
RMWs it directly. Eliminate the WB (44–66% of compositor cycles) + LOAD phases — they
exist only to evict/refill the band to the off-chip SDRAM FB. Sources (4 MB atlas heap)
stay in SDRAM (ch5/P_SRC, unchanged). Net: WB+LOAD → in-place BRAM (1-cyc, true
dual-port → scanout read never contends with composite write). Also dissolves the FB
cache-coherency machinery that caused the #39/#40/#44 wedge class.

## FB BRAM organization (the load-bearing decision)

Mirror `comp_dest_band`'s proven lane-split, scaled from a 320×16 band to the full frame:

```
comp_fbram:  4 lane-banks × 16-bit × 19200 entries  (qword index = y*80 + (x>>2))
             lane = x[1:0];  each bank = simple/true-dual-port M10K
             ~150 M10K total @64-bit-equiv width (fit report: 411 free, fits)
```

Per lane-bank accesses needed: composite-WRITE (mixer out, 1 px/cyc), composite-READ
(blend RMW), scanout-READ. That's 3 against an M10K's 2 ports — resolved by **confining
scanout to HBlank bursts** (below), so during active composite BOTH ports serve the
compositor:

- **Port A = composite write** (mixer output lane, every II=1 cycle).
- **Port B = composite blend-read** (for ALPHA/ADD/MUL/KEY/PALPHA). For opaque COPY the
  read is skipped (the existing `comp_opaque` opaque-skip), so COPY is write-only — port B
  is free. This reuses the opaque-skip logic already on the branch.
- **Scanout** borrows Port B only during HBlank, as a 320-px line burst into the reader's
  existing `linebuf` (see scanout section). Active-scan pixels come from `linebuf`, not the
  FB — so scanout and composite collide only during HBlank (composite is between bands then
  anyway). No per-pixel contention.

## comp_pipeline changes

Today (states in `comp_pipeline.sv`): `P_LOAD_RD/ISS/WAIT` (preload band from SDRAM FB) →
`P_SRCFILL_*` (source from ch5) → `P_PIXEL` (mixer → `comp_dest_band` cw port) →
`P_FLUSH_REQ/DRAIN` (band → flush FIFO) → `P_WB_BASE/SCAN/ISS/WAIT` (FIFO → `comp_burst` →
`mem_*` writeback to SDRAM FB).

After:
- **DELETE** `comp_dest_band` (band_rd/fl banks + dirty[] + flush FSM), the flush FIFO
  (`f_qw/f_be/f_idx`, FIFO_AW=11), and `comp_burst`'s **write** path. The dest no longer
  touches `mem_*` at all.
- **DELETE** states `P_LOAD_*`, `P_FLUSH_*`, `P_WB_*`. The chunk/band loop collapses: a span
  composites straight into `comp_fbram` at `(sp_dst_y, sp_dst_x)`.
- **Composite RMW** = the mixer's dest input reads `comp_fbram` (Port B) at the qword for the
  current pixel (registered, 1-cyc — same shape as today's `band_rd*→mixer` read, so the
  critical path is *swapped not added*: a deeper M10K, same 64-bit width, same registered
  latency). Mixer output writes back via Port A to the same lane. Opaque COPY skips the read.
- **KEEP** unchanged: span collection (`P_SPAN_COLL`/`sp_*` tables), source fetch
  (`P_SRCFILL_*`, ch5/P_SRC, `comp_src_linebuf`), `comp_mixer` (LAT-3 blend ALU), colormod /
  ADD / MULTIPLY, the command-ring walk in `blitter_top`.

The compositor's only remaining `mem_*`/SDRAM traffic is **source reads (ch5)** — the
WB/LOAD half of the bus budget is gone.

## Scanout changes (`openbor_video_reader`)

Today: line-fetch master reads the FB from SDRAM (ch4/P_SCAN) into `linebuf` (M10K
256×64); position-addressed read drives pixels (the 2026-06-17 line-buffer design).

After: **retarget the line-fetch source from SDRAM to `comp_fbram`.** On `new_line` for
line N+1, burst-read 80 qwords from `comp_fbram` (Port B, during HBlank) into the back
`linebuf`; active scan drains `linebuf` exactly as now. Deletes the reader's SDRAM read
master + ch4/P_SCAN entirely. (Alternative considered: direct per-pixel FB read since
ce_pix is 1-in-8 — simpler but holds Port B every active pixel; the HBlank-burst keeps the
compositor's Port B free during active scan, which matters for ALPHA throughput. Prefer the
burst.)

## Deletions / simplifications (robustness win)

- `sdram_fb_cache` **ch0/P_DST cache** (~50 M10K) — gone; reclaimed.
- `sdram_fb_cache` **ch4/P_SCAN** — gone (scanout reads BRAM).
- `vram_demux` dest routing — the FB region no longer decodes to SDRAM.
- **All FB coherency machinery**: `dst_barrier`, vsync ch0 flush, `INVAL_MASK0`, the
  flush/invalidate sequencers. BRAM is always coherent — no cache, no barriers. This removes
  the entire class of FB cache-wedge bugs ([[fpga-coh-busy-barrier-redundant-dbuf-spike]],
  [[fpga-sdram-cache-39-renders]], #44).
- STAGE (ch1) + P_SRC (ch5) coherency for atlas upload **stays** (sources still SDRAM).

## Single-buffer bring-up vs double-buffer production

**Single-buffer first** (this sketch): one `comp_fbram`. Compositor full-redraws it
(carryfwd=0, already the case) while scanout reads it → **tears on moving scenes**. That is
acceptable for bring-up: it validates the pixel datapath, the BRAM fit, the timing closure,
and scanout-from-BRAM on real HW. Static screens (title/menu) render clean immediately.

**Then double-buffer** (cheap, already shown to fit ~69% M10K): two `comp_fbram`,
`target_buf^=1`, publish on present (reuse the existing C_TARGET/double-buffer logic).
Carry-forward = a BRAM→BRAM frame-start copy (or composite-on-prev). Restores tear-free
variable-fps decoupling — the property the strip-race alternative would have lost.

## Timing argument

clk_sys slack is slim (+0.286 ns). The compositor's new critical path (FB BRAM registered
read → mixer) is the **same shape** as today's `band_rd*→mixer` read (registered M10K, 64-bit,
1-cyc) — a deeper M10K has the same access timing (address decode unchanged). We *remove* the
`comp_burst` write FSM + flush-FIFO logic from the dest path. So the change is net-neutral-to-
positive on logic; STA must still confirm after RTL (owed). Trial-synth the `comp_fbram` array
alone first to confirm the ~150 M10K width-packing.

## Validation plan (sim-first, per repo TDD convention)

1. **`tb_fbram`** (new): unit-test the 4-lane BRAM — lane addressing, dual-port read/write,
   scanout-burst vs composite-write non-interference.
2. **`tb_profile`**: re-point the dest model from the SDRAM-latency model to `comp_fbram`;
   confirm WB/LOAD buckets → ~0 and cyc/px drops toward the SRCFILL/comp floor (~1.5 COPY,
   ~1.0 FILL predicted).
3. **`tb_blitter_system_pipe`** (the bit-exact gate): dest → `comp_fbram`; assert pixel-exact
   vs the current SDRAM-FB golden for COPY/ALPHA/ADD/MUL/colormod. This is the correctness bar.
4. **Scanout**: adapt `tb_scanout_linebuf` to source from `comp_fbram` instead of behavioral
   DDR; pixel-exact across frames.
5. RBF build → STA slack check → HW: single-buffer, expect clean static screens + (accepted)
   tearing on motion; read perf counters to confirm WB/LOAD gone and cyc/px at the new floor.
6. Add double-buffer; confirm tear-free; re-measure fps.

## Open risks

- **M10K width-packing**: ~150/FB assumed; confirm by trial synth (step 0).
- **STA**: slim slack; the FB read into the mixer + the scanout burst port must close.
- **ALPHA Port-B contention** during HBlank scanout bursts: composite is between bands at
  HBlank cadence anyway; quantify in `tb_profile`, fall back to a 3rd lane-bank port or a
  scanout shadow copy only if it bites.
- **Single-buffer tearing** is by-design for bring-up; do not ship without the 2nd buffer.
