// comp_fbram.sv — on-chip framebuffer for the FB-in-BRAM compositor.
//
// 4 lane-banks × 16-bit × FB_QWORDS (= FB_W*FB_H/4, see fb_geom.vh).
//   qword index = y*FB_ROW_QW + (x>>2);  lane = x[1:0].
//
// WORK-ONLY framebuffer (Stage 5 Phase 2, Task 2). A single 1W1R buffer built from four
// lane banks (bank0-3): the composite write (wr_*, lane-selected, 1 px/cyc) and the
// compositor's RMW dst read (rd_*). PERSISTS across frames, so Solarus's incremental/
// persistence draw model needs no carry-forward — the prior frame is already here.
//
// The SCAN buffer (former sbank0-3, scan_*/snap_* ports) has been REMOVED: scanout now
// reads the framebuffer from DDR3 instead of a second on-chip snapshot copy, so the
// on-chip snapshot mirror is no longer needed. This is the ~160 M10K win (half the prior
// ~320 M10K footprint) — 4 banks only.
`default_nettype none
`include "fb_geom.vh"
module comp_fbram #(
    // Defaults track fb_geom.vh, so the many testbenches that instantiate this with
    // no parameter overrides stay in step with the fabric automatically.
    parameter integer FB_QWORDS = `FB_QWORDS,
    parameter integer AW        = $clog2(`FB_QWORDS)
)(
    input  wire          clk,
    // composite write: one pixel (one lane) per cycle
    input  wire          wr_en,
    input  wire [AW-1:0] wr_qw,            // qword index 0..FB_QWORDS-1
    input  wire [1:0]    wr_lane,          // x[1:0]
    input  wire [15:0]   wr_pix,           // RGB565
    // composite RMW read: returns all 4 lanes, registered (1-cyc latency)
    input  wire          rd_en,
    input  wire [AW-1:0] rd_qw,
    output wire [63:0]   rd_qword          // {lane3,lane2,lane1,lane0}
);
    // composite-read copy (rd_*) of the four lane banks
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank0 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank1 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank2 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank3 [0:FB_QWORDS-1];

    // composite writes exactly one lane per cycle into the WORK buffer only
    wire we0 = wr_en & (wr_lane == 2'd0);
    wire we1 = wr_en & (wr_lane == 2'd1);
    wire we2 = wr_en & (wr_lane == 2'd2);
    wire we3 = wr_en & (wr_lane == 2'd3);

    always @(posedge clk) if (we0) bank0[wr_qw] <= wr_pix;
    always @(posedge clk) if (we1) bank1[wr_qw] <= wr_pix;
    always @(posedge clk) if (we2) bank2[wr_qw] <= wr_pix;
    always @(posedge clk) if (we3) bank3[wr_qw] <= wr_pix;

    // composite RMW read port (clean registered read → clean M10K inference).
    // NOTE on read-during-write: the blend RMW reads the dest qword for a pixel AHEAD in
    // comp_pipeline while the composite write commits a pixel BEHIND it; mid-row those can
    // share a qword. But the read LANE used by the blend (= read pixel's x[1:0]) is offset
    // from the simultaneously-written lane by the mixer latency, so they never coincide —
    // the only same-address read-during-write hits an UNUSED lane, whose value is discarded.
    // (An explicit write-forward bypass was tried and REVERTED: it gave no functional change
    // and regressed the HDMI PLL path into negative slack. The placement-sensitive path is
    // the fb_rd address mux; the pinned fitter seed gives it margin.)
    reg [15:0] q0, q1, q2, q3;
    always @(posedge clk) if (rd_en) begin
        q0 <= bank0[rd_qw]; q1 <= bank1[rd_qw];
        q2 <= bank2[rd_qw]; q3 <= bank3[rd_qw];
    end
    assign rd_qword = {q3, q2, q1, q0};

endmodule
`default_nettype wire
