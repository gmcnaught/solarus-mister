# `comp_src_linebuf` → `s3_alpha` is NOT a false path — it is the PALPHA alpha fold

**Date:** 2026-08-17 · **Branch:** `claude/comp-src-linebuf-false-path-fc5e4n` (stacked on #165)
**Question asked:** #165's STA comment left one item open — *"whether `comp_src_linebuf`
write-enable → `s3_alpha` is genuinely a false path remains unanswered, and is the thing
actually worth fixing."* The hope was that constraining it properly would remove a −2.6 ns
phantom that had been masking real timing on every build.
**Answer:** **it is not a false path.** It is a real, fully sensitized, issue-interval-1 data
path, and the "write enable" in the node name is a Quartus naming artifact. Constraining it
false would have hidden the single worst — and essentially only — timing defect in the core.
**Status:** root-caused from the committed STA report; **fix landed, sim-green, STA- and
HW-UNVALIDATED**. RTL changed ⇒ needs a new RBF.

## TL;DR

- **Not false.** The launch node `ram_block1a3~PORT_B_WRITE_ENABLE_REG` is the M10K's port-B
  *internal* register in **Simple Dual Port** mode, where **port B is the read port**. The next
  hop in the path is `portbdataout[6]` — read data, not a write enable. Nothing about the path
  involves writing.
- **What it really is:** `line0[] → serve bank/lane mux → pa_a8*c_alpha → +128 → +(>>8) →
  s3_alpha`. That is the per-pixel PALPHA alpha fold doing an M10K read, a DSP multiply and two
  rounding carry-chains **in one 10.158 ns cycle**.
- **It is the whole problem.** Every one of the 12 worst setup paths on the 98.44 MHz core clock
  ends at `s3_alpha[6]` or `s3_alpha[4]`. TNS on that clock is **−124.512 ns**; no other clock
  domain in the design is meaningfully violated (next worst is pll_hdmi at −0.058).
- **Provenance:** the multiply was added by `bdbb877` (#149, blend-layer). Before it the line
  read `feed_alpha = b_palpha ? pa_a8 : c_alpha` — a bare 2:1 mux off the RAM output.
- **Fix:** split multiply from reduce across T+2/T+3, exactly as the colour-mod stage directly
  above it already does. **Latency-unchanged, bit-identical** (proven exhaustively).

## 1. The evidence — the path, node by node

From the committed CI artifact for PR #165 (`quartus-reports-linux`, run 31993587993, commit
`e8ed2d1`, Quartus Lite 17.0 Linux container, SEED 3), `sta_20260817.log`, section
*CORE 98.44MHz (general[0]) worst setup FULL PATH*, Path #1:

```
From : ...|comp_pipeline:u_pipe|comp_src_linebuf:u_linebuf|altsyncram:line0_rtl_0
           |altsyncram_ugn1:auto_generated|ram_block1a3~PORT_B_WRITE_ENABLE_REG
To   : ...|comp_pipeline:u_pipe|s3_alpha[6]
Relationship 10.158   Clock Skew -2.422   Data Delay 10.124   Slack -2.718 (VIOLATED)
```

The data arrival path, with the increments that matter:

| Total (ns) | Incr | Element | reading |
|--:|--:|---|---|
| 7.785 | 2.303 | `...\|ram_block1a3\|clk0` | clock reaches the M10K |
| 10.257 | 2.472 | `ram_block1a3~PORT_B_WRITE_ENABLE_REG` | **clock insertion *inside* the block** |
| 10.257 | 0.000 | `uTco` | — |
| 10.417 | 0.160 | `ram_block1a3\|portbdataout[6]` | **read data leaves the RAM** |
| 11.572 | 0.220 | `u_linebuf\|Mux12~1\|combout` | bank / lane mux |
| 12.414 | 0.481 | `u_linebuf\|Mux12~2\|combout` | bank / lane mux |
| 16.187 | 2.826 | `u_pipe\|Mult0~mac\|resulta[8]` | **DSP: `pa_a8 * c_alpha`** |
| 18.380 | — | `u_pipe\|Add1~*` carry chain | **`+ 16'd128`** |
| 20.120 | — | `u_pipe\|Add2~*` carry chain | **`+ (m >> 8)`** |
| 20.381 | 0.261 | `s3_alpha[6]` | latch |

Data required 17.663 → **−2.718**.

The decisive line is the fourth: the hop immediately after the launch register is
**`portbdataout[6]`**. Whatever Quartus chose to call the register, what it launches is read
data on its way to the multiplier.

## 2. Why the node name says "WRITE_ENABLE" (and why that is a red herring)

From `Solarus.fit.rpt`, *Fitter RAM Summary*, for `...|comp_src_linebuf:u_linebuf|altsyncram:line0_rtl_0`:

| field | value |
|---|---|
| Type / Mode | M10K block, **Simple Dual Port**, Single Clock |
| Port A / Port B depth × width | 256 × 64 / 256 × 64 |
| Port A Input Registers | yes |
| Port A Output Registers | **no** |
| Port B Input Registers | yes |
| Port B Output Registers | **no** |
| Mixed Width RDW Mode | Don't care |
| M10K blocks | 2 (`M10K_X26_Y23_N0`, `M10K_X14_Y25_N0`) |

Three things follow.

1. **In Simple Dual Port, port A writes and port B reads.** A "port B write enable" is not a
   thing this RAM does; it is the WYSIWYG's generic name for the port-B control register.
   `ram_block1a3~PORT_B_WRITE_ENABLE_REG` is the *only* `~PORT_*_REG` node that appears anywhere
   in the entire STA report (38 occurrences, all of them this path family) — it is the block's
   single representative launch node, not one of several from which a write-enable arc was
   singled out.
2. **`Port B Output Registers: no`.** The RTL writes `if (serve_req) q0 <= line0[xa[9:2]]`, which
   *reads* as an output-registered RAM; Quartus implemented the equivalent
   address-registered/output-combinational form instead. Same 1-cycle latency, but it means the
   launch register is inside the block and the M10K's ~2.6 ns access (2.472 clock insertion +
   0.160 to `portbdataout`) sits **inside** the T+2 cycle rather than ahead of it. That is also
   where the −2.422 ns "clock skew" comes from — most of it is the block's internal clock
   insertion charged as launch latency, not routing imbalance.
3. **The read-during-write reading does not survive.** The tempting story — "WE reaches the read
   data only through the RDW bypass, and `no_rw_check` says we do not care" — would require the
   read data to have *some other* launch node. It has none. There is exactly one, and it is this.

## 3. Mapping the path onto the RTL

`comp_pipeline.sv`, as it stood before this change:

```systemverilog
wire  [3:0] pa_a4 = lb_serve_pix[15:12];          // ← Mux12~1 / Mux12~2 (bank + lane select)
wire  [7:0] pa_a8 = { pa_a4, pa_a4 };
wire [15:0] pa_scaled_m = pa_a8 * c_alpha + 16'd128;              // ← Mult0~mac, Add1
wire  [7:0] pa_scaled   = (pa_scaled_m + (pa_scaled_m >> 8)) >> 8; // ← Add2
wire  [7:0] feed_alpha  = b_palpha ? pa_scaled : c_alpha;
...
s3_alpha <= feed_alpha;                                            // ← the endpoint
```

Every element in the STA path has a named counterpart. `Mult0` is the alpha fold and not the
colour-mod multiply: the colour-mod products `cm_p{r,g,b}` are registered directly into
`s3_cm_p*` with no adder after them (#149's own fmax split), and none of them appear among the
12 worst paths.

## 4. Why it is neither false nor multicycle

Three independent conditions would each have to fail for a relaxation to be honest. None do.

- **Sensitizable?** Yes. `b_palpha = (c_blend == BLEND_PALPHA) && !is_fill` is a per-blit
  constant, so on a PALPHA blit the multiply output is selected for *every* pixel. PALPHA blits
  are not a corner case: the full-screen root overlay composite and every sprite are PALPHA.
- **Exercised every cycle?** Yes. In `P_PIXEL` the issue arm increments `pix_k` unconditionally
  each clock — the compositor is issue-interval-1 — and `s3_alpha <= feed_alpha` sat in the
  unguarded part of the state body, with no enable. Launch and latch happen on consecutive
  edges, back to back, for the length of a span.
- **Result actually consumed?** Yes, one cycle later, at
  `mx_in_alpha <= ... : s3_alpha`.

So there is no `set_false_path` and no `set_multicycle_path` that would be true here. Writing
one would have converted a −2.718 ns violation into a clean report while leaving the silicon
exactly as marginal as it is now — and, because this path accounts for the core's entire TNS, it
would have made the core clock look fully closed.

## 5. Where it came from

`git log -S"pa_scaled"` gives one commit: **`bdbb877`, "perf(render): fabric-offload in-game
dialogs + blend menus (dialog fps ~1.8×)" (#149)**. Its diff on this line is exactly:

```diff
-  wire  [7:0] feed_alpha = b_palpha ? pa_a8        : c_alpha;
+  wire [15:0] pa_scaled_m = pa_a8 * c_alpha + 16'd128;
+  wire  [7:0] pa_scaled   = (pa_scaled_m + (pa_scaled_m >> 8)) >> 8;
+  wire  [7:0] feed_alpha  = b_palpha ? pa_scaled : c_alpha;
```

Before #149 this was a 2:1 mux hanging off the RAM output. #149 put a DSP multiply and two
rounding carry-chains in front of the same register — and split its *sibling* (colour-mod)
multiply-and-reduce across two cycles for precisely this reason, while leaving the alpha fold
single-cycle.

Corroborating, from `docs/superpowers/2026-07-21-stage3b-phaseB2-hw-timing.md` (2026-07-21,
pre-#149): the design closed at **+0.175 ns** on SEED 3, and the only place SEED 1 went negative
was **−0.082 ns on a `comp_pipeline|comp_src_linebuf` altsyncram path** — the same startpoint,
marginal, with no multiply on it. Other commits landed between then and now, so this is
supporting evidence for the trajectory rather than a controlled A/B; the diff above is the direct
evidence.

## 6. How big it is

`Solarus.sta.summary` for the same build:

| clock domain | slack | TNS |
|---|--:|--:|
| **core `general[0]` (98.44 MHz)** | **−2.718** | **−124.512** |
| `pll_hdmi` divclk | −0.058 | −0.058 |
| `h2f_user0_clk` | +2.896 | 0 |
| `clk_pix` `general[2]` | +8.230 | 0 |
| `SDRAM_CLK` | +12.937 | 0 |
| everything else | positive | 0 |

One fold in one stage of the compositor is, to a good approximation, the Solarus core's entire
timing failure.

## 7. The fix

Split multiply from reduce across the two cycles the pipeline already has, the same way the
colour-mod stage twelve lines above does it:

- **T+2** registers only the product: `s3_pa_prod <= pa_a8 * c_alpha`, plus `s3_calpha <= c_alpha`.
- **T+3** does `+128`, the `/255` reduce and the `b_palpha` select combinationally
  (`pa_m_d` → `pa_scaled_d` → `s3_alpha_d`), in the cycle that already consumed `s3_alpha`.

`s3_alpha` stops being a register and becomes the wire `s3_alpha_d`. **Latency is unchanged** —
this is not a new pipeline stage, the reduce simply moved into the cycle that was already there —
so no drain count, no `MIX_LAT`, and no valid/coord shadow pipeline changes.

`c_alpha` must be registered alongside the product. It is a per-blit constant, so sampling it
live at T+3 would apply the *next* blit's alpha to the last pixels of the current one. `b_palpha`
was already carried as `s3_palpha` for the PAL8 work, so the select is aligned for free.

Expected effect: the T+2 path loses `Add1` and `Add2` and ends at the register right after
`Mult0~mac|resulta[8]` (16.187 ns of a 17.663 ns requirement) — roughly **+0.9 ns**, i.e. closure
with a little margin, on this path. The new T+3 path (registered product → two adds → mux) is
shallow. This is an estimate from the reported increments, **not** a measured fit.

### If that is not enough — the second lever this exposed

`comp_src_linebuf`'s header reasons about `q0`/`q1` as output registers ("register EACH bank's
read into its OWN output"), which implies the M10K access happens in the cycle *before* the
consumer. The fit report says otherwise: `Port B Output Registers: no`, i.e. Quartus took the
latency-equivalent form — address registered inside the block, output combinational — so the
~2.6 ns array access lands in the *same* cycle as the mux, the multiply and (previously) the
adds. That is where 2.472 ns of the reported −2.422 ns "clock skew" comes from too: it is the
block's internal clock insertion charged as launch latency, not a routing imbalance anyone can
place away.

Forcing a real output register (`outdata_reg_b`) would move the access back off this cycle and
free ~2.6 ns — but it makes the linebuf read 2-cycle and needs a matching pipeline stage, so it
is a bigger change than the split above and should only be reached for if a fit says the split
did not close it. Recording it here so the next round starts from the fit report rather than
from the header comment.

## 8. Evidence the fix is behaviour-preserving

- **Bit-identical, proven exhaustively.** Deferring `+128` past a register is safe because
  nothing truncates: `pa_a8 * c_alpha ≤ 65025` and `+128 ≤ 65153` both fit the same 16 bits.
  Checked over all 65 536 `(pa_a8, c_alpha)` pairs — including the 240 that `pa_a8`'s
  `{A4,A4}` form cannot produce — **0 mismatches** against the original expression.
- **PR tier: 45 PASS**, 0 gating / 0 non-gating failures, 5 skipped (measurement benches),
  1 deferred — identical to #165's baseline.
- **Nightly tier: 46 PASS**, full geometry, `FABRIC_ASSERT` on, including `tb_comp_replay`.
- The gates that would catch a regression here specifically —
  `tb_blitter_palpha_pipe` (checks the RTL fold against `blitter_ref.c`'s
  `div255_round(a8*c->alpha)`), `tb_blitter_colormod_pipe`, `tb_blitter_cafill_pipe`,
  `tb_blitter_blend_pipe`, `tb_argb4444_blendmodes`, `tb_mixed_format_seq`, `tb_pal8_lookup` —
  all pass, and they compare framebuffer pixels, not cycle counts.

## 9. Not done

- **No fit / STA.** Quartus is not available in this environment; the numbers above are read from
  #165's committed CI artifact, and the +0.9 ns is an estimate from path increments. **A build is
  the first gate**, and it should be run at more than one seed — #165 established that this
  design's fit is seed-sensitive (0.41 ns spread over 3 seeds).
- **No hardware validation.** RTL changed ⇒ new RBF, and per `CLAUDE.md` the engine and RBF ship
  as a matched pair. The scenes to watch are the PALPHA-heavy ones this path serves: the root
  overlay composite, dialogs and blend menus (#149's own targets), and sprites.
- **The `-2.718 → ?` claim is unproven** until that build exists. What *is* proven here is the
  refutation: the path is real, so the constraint that was hoped for must not be written.

## 10. What not to do

Do **not** add `set_false_path` or `set_multicycle_path` from `comp_src_linebuf`'s altsyncram to
`s3_alpha`. If a future report shows this startpoint again, read the hop after the launch node
first: `portbdataout[*]` means read data and a real path. The name of the launch register is not
evidence about what the path carries.
