`default_nettype none
// bgw_ch0_mux — [Phase 3b bg-plane bake] priority mux for sdram_fb_cache's ch0
// (P_DST) write side, arbitrating between vram_demux (vd_sd_*, the pre-existing
// driver) and blitter_top's new OP_BGPLANE_WRITE bake drain (bgw_dst_*). Both
// are the sole candidate drivers of ch0's write side and can never legitimately
// want the bus in the same cycle in current builds (vram_demux's FB0/FB1 writes
// are dead since FB-in-BRAM moved compositing on-chip; the bake is a rare
// one-time per-map-change event) -- this exists only to avoid a multi-driver
// net, not to perform real arbitration. bgw_active (blitter_top's own
// dr_wr_r drain-pending register) gets priority whenever it is actively
// holding a request, mirroring vram_demux's own "hold sd_wr until sd_ok"
// atomic-request contract (a request, once started, must not be switched out
// from under its driver mid-request).
//
// dst_ok is READ-side/response-side and is NOT part of this mux: it fans out
// unconditionally from sdram_fb_cache to both consumers (wired directly in
// Solarus.sv), since each side only interprets it as "my own outstanding
// request completed" and simply ignores an unrelated pulse it isn't expecting.
// dst_rd/dst_dout are similarly untouched -- the bake is write-only.
module bgw_ch0_mux (
    input  wire        bgw_active,
    input  wire        bgw_dst_wr,
    input  wire [26:0] bgw_dst_addr,
    input  wire [63:0] bgw_dst_din,
    input  wire [7:0]  bgw_dst_wdsn,
    input  wire        vd_sd_wr,
    input  wire [26:0] vd_sd_addr,
    input  wire [63:0] vd_sd_din,
    input  wire [7:0]  vd_sd_wdsn,
    output wire        dst_wr,
    output wire [26:0] dst_addr,
    output wire [63:0] dst_din,
    output wire [7:0]  dst_wdsn
);
    assign dst_wr   = bgw_active ? bgw_dst_wr   : vd_sd_wr;
    assign dst_addr = bgw_active ? bgw_dst_addr : vd_sd_addr;
    assign dst_din  = bgw_active ? bgw_dst_din  : vd_sd_din;
    assign dst_wdsn = bgw_active ? bgw_dst_wdsn : vd_sd_wdsn;
endmodule
`default_nettype wire
