`default_nettype none
// Address-decode demux: routes the vendored blitter's mem_* to the DDR3
// arbiter (blt_* port).
//
// [Stage 5 Phase 2, Task 3 — 2026-07-22] The FB0/FB1 region used to remap to
// the on-chip-superseded SDRAM P_DST cache: a write/read FSM (S_IDLE /
// S_WOKWAIT / S_RDLAT) that byte-masked writes and walked burst reads one
// qword at a time via a cache-ok (sd_rd/sd_wr/.../sd_ok) protocol, remapping
// the FB's DDR qword address down to `SDRAM_FB0_BASE`/`SDRAM_FB1_BASE`
// (vram_defs.vh) via `fb_base`/`qw_byte`. The framebuffer's scanout copy is
// moving off-chip to DDR3, and FB writes/reads already carry a DDR-relative
// qword address (`FB_DDR0_QW`/`FB_DDR1_QW` + offset, blitter_defs.vh/
// vram_defs.vh) -- so routing the FB region to DDR needs no remap at all,
// same as the non-FB traffic that already passed straight through.
//
// That SDRAM leg (the `sd_*` ports, the FSM, `acc_qw`, the `fb_base`/
// `qw_byte`/`off_qw` remap) is DELETED. This module is now a stateless
// pass-through: every blt_* signal wires straight to the matching ddr_*
// signal, for FB and non-FB addresses alike. `clk`/`reset` and `blt_burstcnt`
// are kept as ports for interface stability (Solarus.sv still connects them;
// `blt_burstcnt` was only ever consumed by the now-deleted SDRAM read FSM --
// the real burst count reaches `ddr_blitter_arb` directly via a separate wire
// in Solarus.sv, not through this module) but are otherwise unused here.
module vram_demux (
  input  wire        clk, reset,
  // blitter mem_* (qword-addressed, [31:0] carrying a 29-bit range)
  input  wire [31:0] blt_addr,
  input  wire        blt_rd, blt_wr,
  input  wire [63:0] blt_din,
  input  wire [7:0]  blt_be,
  input  wire [7:0]  blt_burstcnt,   // unused (see header note)
  output wire [63:0] blt_dout,
  output wire        blt_dout_ready,
  output wire        blt_busy,
  // DDR side (ddr_blitter_arb blt_* port)
  output wire [28:0] ddr_addr,
  output wire        ddr_rd, ddr_wr,
  output wire [63:0] ddr_din,
  output wire [7:0]  ddr_be,
  input  wire [63:0] ddr_dout,
  input  wire        ddr_dout_ready,
  input  wire        ddr_busy,
  // DEBUG: the SDRAM FSM this reported is gone; tied off.
  output wire  [3:0] dbg
);
  // ---------------------------------------------------------------------------
  // Pure combinational pass-through: FB and non-FB regions both target DDR3.
  // ---------------------------------------------------------------------------
  assign ddr_addr = blt_addr[28:0];
  assign ddr_rd   = blt_rd;
  assign ddr_wr   = blt_wr;
  assign ddr_din  = blt_din;
  assign ddr_be   = blt_be;

  assign blt_dout       = ddr_dout;
  assign blt_dout_ready = ddr_dout_ready;
  assign blt_busy       = ddr_busy;

  assign dbg = 4'b0;

endmodule
`default_nettype wire
