# fpga/sim — arbiter simulation (iverilog)

`tb_ddr_blitter_arb.sv` validates `../rtl/ddr_blitter_arb.sv` against a behavioral
DDRAM with backpressure. It models the REAL reader faithfully: it idles (no
request) then gates its burst read on `!busy` (`if(!ddr_busy) assert rd`). That
pattern is what exposes the chicken-and-egg deadlock — a reader stalled by the
grant can never assert `rd`, so a default-producer arbiter starves it (black
screen on HW). The test asserts the reader always gets the bus within a small
bounded gap, reads correct data, and the producer makes progress.

    iverilog -g2012 -o dl.vvp tb_ddr_blitter_arb.sv ../rtl/ddr_blitter_arb.sv
    vvp dl.vvp   # expect: read errors=0, max grant gap small (no DEADLOCK)

`tb_arb_scanout_strict.sv` is the issue #19 SCANOUT-STRICT regression. It models
the `SOLARUS_SDRAM_SRC=1` load: the blitter requests the bus CONTINUOUSLY (heavy
DDR3->SDRAM staging reads) while the scanout reader periodically wants its 80-beat
burst (gating `rdr_rd` on `!rdr_busy`, like the real reader). The OLD arbiter lent
the freed cycle back to the still-asking blitter before the busy-gated scanout could
claim it, so scanout grant latency tracked the (repeated) blitter read window ->
underflow -> BLACK overworld. The scanout-strict arbiter inserts a one-cycle scanout
window after every blitter loan, bounding scanout latency to ~one in-flight blitter
read; the test asserts (A) scanout latency <= a deadline, (B) the blitter still makes
forward progress (no lockout), (C) no beat misrouting.

    iverilog -g2012 -o ss.vvp tb_arb_scanout_strict.sv ../rtl/ddr_blitter_arb.sv
    vvp ss.vvp   # buggy arbiter: latency 90 > 62 -> FAIL; scanout-strict: PASS
