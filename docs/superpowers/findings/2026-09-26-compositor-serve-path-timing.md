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

## Result: levers 2 + 3 implemented (RBF run 36279437327)

Timing, committed seed 3, same seed as the failing build:

| | old line buffer (run 36277013948) | registered mixed-width RAM (run 36279437327) |
|---|---|---|
| clk_sys WNS / TNS | -0.148 / -2.139 | -0.148 / -0.264 (DQ capture only) |
| violated paths into comp_pipeline | 12 | 0 |
| worst s3 product path | -0.140 (launch: linebuf M10K) | +1.763 (launch: `c_opcode`, RAM no longer on it) |
| pll_hdmi WNS | -0.180 | +0.085 |
| RAM blocks / ALMs | 337 / 14,650 | 337 / 14,649 |

Seed sweep on the OLD RTL, for reference: seed 1 and seed 2 also had no compositor
violations (seed 1 pll_hdmi +0.071). Seeds 4-9 were cancelled once the new RTL was
ready.

Map 119 fabric cost (.62, parked at 119/from_dungeon_10, standing, no dialog,
`SOLARUS_BLITTER_DIAG` `[blitter hwperf]`, legs alternated on one boot):

| leg | fabric_hw ms | comp ms | cycles/frame |
|---|---|---|---|
| A0 old | 17.945 | 12.201 | 1,766,373 |
| B0 new | 18.226 | 12.460 | 1,794,015 |
| A1 old | 17.955 | 12.203 | 1,767,358 |
| B1 new | 18.231 | 12.463 | 1,794,590 |

+27.4k cycles/frame (+1.56 %), repeatable to 0.03 %: the +1 cycle per span. The
host-side rate on this rig was 44-47 fps in both legs (no mem_wc / CPU isolation in
this launcher, so the A9 dominates the period). The A/B is the fabric numbers, not
that fps.

Pixel check: MiSTer screenshots of the parked frame, 2 per leg, are byte-identical
across A and B (md5 d5b6c14a...). The frame has PAL8 tiles, sprites and the ARGB4444
overlay, so the mixed-width lane order is correct on silicon. A tinted (colormod)
draw was not in frame.

## Map 119 regression and the drain fix (RBF run 36282381951)

The +1 cycle per span did show on map 119, whose fabric time already exceeds the
16.7 ms frame budget. fpsdip (`TOUR=119:from_dungeon_10`, 120 s, seed 1, v1.2.0
launcher with mem_wc + CPU isolation, .62), two runs per build:

| build | osd windows < 55 fps | long frames | p50 / p99 period ms |
|---|---|---|---|
| A old line buffer | 5.2 %, 6.5 % | 7.44 %, 7.65 % | 16.9 / 22.1-22.3 |
| B registered RAM (PIPE_DEPTH 6) | 16.9 %, 18.2 % | 13.08 %, 12.88 % | 17.0-17.1 / 22.2-22.4 |
| C registered RAM + PIPE_DEPTH 3 | 2.5 %, 2.5 % | 4.07 %, 4.54 % | 16.8 / 21.8 |

Fabric cycles/frame, parked and standing: A 1,769,146, B 1,794,300, C 1,725,840
(C is -2.45 % vs A; comp 12.20 -> 11.69 ms).

Why C is faster: P_DRAIN (PIPE_DEPTH+1 cycles) starts only after P_PIXEL has emptied
s1..s3, and a span's last write-back lands at drain_cnt = PIPE_DEPTH-2. At the old
PIPE_DEPTH=6 that left 4 idle cycles per span. MIX_LAT (3) keeps one spare. A new
FABRIC_ASSERT check (nightly tier) fails the sims on any write-back outside
P_PIXEL/P_DRAIN; it fires at PIPE_DEPTH=1.

C timing (seed 3): no compositor violations, clk_sys WNS -0.144 (DQ only), pll_hdmi
+0.209. Screenshots of the parked frame are byte-identical to A.

The fpsdip driver now accepts `map:destination` tour stops. Map 119's default entry
left a dialog open for ~78 of 120 s (flags 0x7), so frames.py counted almost no
active 119 frames.

## Build C on .81 (platform install, main=MiSTer_hybrid)

- Core switch with a runaway fabric: 0/6 frozen. Idle reloads: 0/10 frozen, health word 0.
- main= boot, OSD-style pick, engine to "Simulation started", fabric gate, switch to MENU
  mid-game: 5/5.
- Tint: hero sprite `set_color_modulation({255,96,96})` parked on map 119 changes 223 px,
  all inside the hero box (x 153-168, y 105-126; sample (74,73,74) -> (66,24,24)). The
  tinted frame is byte-identical between A (old line buffer, seed 3, whose tint path
  failed timing) and C.
