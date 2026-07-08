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
// Solarus.sv). This is safe TODAY, but NOT because either side "ignores" or
// "tolerates" an ack it isn't expecting -- vram_demux does not: its S_WOKWAIT
// state (vram_demux.sv) advances to S_IDLE on ANY sd_ok pulse, with no way to
// tell whether the pulse acks its own outstanding write or the bake's. If
// vram_demux ever actually had a write parked in S_WOKWAIT while bgw_active
// also held ch0, it would eat the bake's dst_ok as its own and silently drop
// its own pending write. The fan-out is safe only because vram_demux's SDRAM
// write (and read) path is entirely dead in current builds (its is_fb
// address-range decode is unconditionally false -- see task-3b-report.md), so
// vram_demux is never actually sitting in S_WOKWAIT/S_RDLAT waiting on a real
// dst_ok for this mux to race against.
// dst_rd/dst_dout are similarly untouched -- the bake is write-only.
//
// Revival note: reviving vram_demux's FB0/FB1 write (or read) path while this
// mux exists is NOT just a matter of folding dst_rd into the mux select
// (needed anyway since dst_addr is a shared read/write bus, per
// task-3b-report.md). dst_ok routing would ALSO need to become conditional --
// e.g. gated on which side actually has an outstanding request (vd_sd_rd |
// vd_sd_wr for vram_demux's share, bgw_active for the bake's share) -- or the
// lost-write race described above goes live.
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
