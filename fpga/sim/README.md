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
