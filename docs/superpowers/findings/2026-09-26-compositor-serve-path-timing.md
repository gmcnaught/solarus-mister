# Compositor serve-path timing: why it is seed-sensitive, and levers (2026-09-26)

Build: `Solarus_20260926.rbf` (seed 3, run 36277013948). Worst clk_sys setup
-0.148 ns, TNS -2.139.

## The path

Every violated clk_sys endpoint except SDRAM DQ capture starts at the source
line-buffer M10K (`comp_src_linebuf|line0_rtl_0 ... PORT_B_WRITE_ENABLE_REG`).
Data delay is 7.895 ns and clock skew -2.073 ns, against a 10.158 ns period.

```
line0/line1 M10K (q0/q1 absorbed as the RAM's read reg; output UNregistered)
  -> serve_bank_q 2:1 mux -> serve_lane_q 4:1 lane mux      (lb_serve_pix)
  -> feed_src mux (palpha/argb4444 expand) -> raw_src mux (is_fill)
  -> DSP multiply (Mult0..4, no input/output regs packed)
  -> s3_cm_pr/pg/pb (tint) | s3_pa_prod (alpha)              fabric regs
     also: lb_serve_pix + c_base_off -> clut_rd_addr (PAL8)
```

The endpoint that fails changes with the seed. This build: `s3_cm_pb`. The
PR #165 sweep: `s3_alpha`/`s3_pa_prod`. They all sit in one logic cone rooted
at the M10K read, so fixing one endpoint moves the violation to the next.
Placement sensitivity comes from three fixed columns — M10K, DSP, and the
s3 fabric registers — and the routes between them. That is also why the
clock skew term is large.

## Levers

Ranked by risk. Each lever is bit-exact. Levers 1 and 3 keep pipeline latency.

1. **LUT multiplies for the s3 products.** Add `(* multstyle = "logic" *)` on
   `cm_pr/pg/pb` and the PALPHA product. They are 5–6 × 8 bits, roughly 30–40
   ALMs each; DSP use is 47/112 and ALMs 35 %. This drops the DSP-column round
   trip, so the placer can put the multiply next to the M10K and the s3
   registers. One-line change, no latency change. It is also the cheapest to
   test: one build, then compare slack across 2–3 seeds.
2. **Register the M10K output** (a second read register in
   `comp_src_linebuf`, packed into the M10K output register). This removes the
   unregistered M10K clock-to-out, the largest single term in the cone, and
   leaves mux + multiply a full cycle. Serve latency goes 1 → 2, so the s1/s2
   metadata, `rd_dst` and the CLUT address need one more alignment stage. This
   has precedent: the tint split did the same (+1 drain cycle per span,
   issue-interval stays 1). Cost is 1 cycle per span. Measure it with
   COMPTRACE on map 119, which is fabric-bound (comp ~14 ms), before shipping.
   The existing `tb_comp_*` bit-exact suites gate the realignment.
3. **Drop the post-RAM muxes.** Merge both banks into one simple-dual-port RAM
   (bank = address MSB) with a 64-bit write and 16-bit read port
   (mixed-width `altsyncram`). The bank mux and 4:1 lane mux disappear with no
   latency change. It needs an explicit `altsyncram` instance and a sim stub
   (as `dcfifo_stub.sv` does), and the M10K count stays the same.
4. **Framework trims** (product decisions, not compositor fixes).
   `MISTER_DISABLE_YC` removes `yc_out`, which is among this build's
   violators (pll_hdmi domain), and drops composite/S-video out.
   `MISTER_DISABLE_ADAPTIVE` and `MISTER_SMALL_VBUF` shrink ascal, the
   violator in the 0818 build. All three reduce congestion for every
   domain.
5. **Sweep process.** `seed_sweep.sh` only runs on the NAS runner, which is not
   registered, so sweeps are serial single-seed dispatches on the Windows
   runner. Its "timing met" stop never fires, because SDRAM DQ capture fails
   on every build (IO timing, not placement). Gate on the clk_sys core paths,
   or use `-l`, rather than on global WNS.

Not recommended: LogicLock floorplanning. It is brittle across RTL changes,
and levers 1–3 remove the cause instead of fixing a placement.

`build_solarus.sh` now reports the worst clk_sys path and the s3 product paths
in full, so the next build shows how the 7.9 ns splits between RAM, muxes
and DSP.
