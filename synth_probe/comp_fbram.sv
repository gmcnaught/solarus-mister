// comp_fbram.sv — on-chip framebuffer for the FB-in-BRAM compositor (TRIAL location).
//
// 4 lane-banks × 16-bit × FB_QWORDS (=19200 for 320×240 RGB565).
//   qword index = y*80 + (x>>2);  lane = x[1:0].
// Each bank is a simple-dual-port M10K: one composite WRITE (lane-selected, 1 px/cyc)
// + one READ (composite blend-read during active scan, scanout burst during HBlank —
// muxed by the caller). Mirrors comp_dest_band's proven lane-split, scaled band→frame.
//
// This is the throwaway-located copy for the resource trial-synth (synth_probe/). The
// real implementation will live in fpga/rtl/comp_fbram.sv when the compositor is cut over.
`default_nettype none
module comp_fbram #(
    parameter integer FB_QWORDS = 19200,   // 320*240/4
    parameter integer AW        = 15       // ceil(log2(19200)) = 15
)(
    input  wire          clk,
    // composite write: one pixel (one lane) per cycle
    input  wire          wr_en,
    input  wire [AW-1:0] wr_qw,            // qword index 0..FB_QWORDS-1
    input  wire [1:0]    wr_lane,          // x[1:0]
    input  wire [15:0]   wr_pix,           // RGB565
    // qword read: returns all 4 lanes, registered (1-cyc latency)
    input  wire          rd_en,
    input  wire [AW-1:0] rd_qw,
    output wire [63:0]   rd_qword          // {lane3,lane2,lane1,lane0}
);
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank0 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank1 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank2 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank3 [0:FB_QWORDS-1];

    // composite writes exactly one lane per cycle
    wire we0 = wr_en & (wr_lane == 2'd0);
    wire we1 = wr_en & (wr_lane == 2'd1);
    wire we2 = wr_en & (wr_lane == 2'd2);
    wire we3 = wr_en & (wr_lane == 2'd3);

    always @(posedge clk) if (we0) bank0[wr_qw] <= wr_pix;
    always @(posedge clk) if (we1) bank1[wr_qw] <= wr_pix;
    always @(posedge clk) if (we2) bank2[wr_qw] <= wr_pix;
    always @(posedge clk) if (we3) bank3[wr_qw] <= wr_pix;

    reg [15:0] q0, q1, q2, q3;
    always @(posedge clk) if (rd_en) begin
        q0 <= bank0[rd_qw]; q1 <= bank1[rd_qw];
        q2 <= bank2[rd_qw]; q3 <= bank3[rd_qw];
    end
    assign rd_qword = {q3, q2, q1, q0};
endmodule
`default_nettype wire
