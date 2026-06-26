// comp_fbram.sv — on-chip framebuffer for the FB-in-BRAM compositor.
//
// 4 lane-banks × 16-bit × FB_QWORDS (=19200 for 320×240 RGB565).
//   qword index = y*80 + (x>>2);  lane = x[1:0].
//
// ONE write port (composite, lane-selected, 1 px/cyc) + TWO independent read ports:
//   rd_*   : the compositor's RMW dst read (blend-read during active compositing)
//   scan_* : the scanout reader's line fetch (HBlank burst into the reader linebuf)
// The two readers overlap in time (a blit can run while the reader fetches a line), so
// each gets its OWN read port — a true 1W2R BRAM is built by replicating the four lane
// banks (a composite-read copy + a scanout-read copy), each written identically by the
// one composite write. This is comp_dest_band's proven rd/fl lane-replication pattern
// scaled band→frame; it avoids any read-port arbitration / compositor backpressure.
// Cost: ~2× the 1W1R block count (~320 M10K) — the double-buffer budget, confirmed to
// fit (≈404/553). All eight arrays are clean 1-write/1-read full-width RAMs → M10K.
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
    // composite RMW read: returns all 4 lanes, registered (1-cyc latency)
    input  wire          rd_en,
    input  wire [AW-1:0] rd_qw,
    output wire [63:0]   rd_qword,         // {lane3,lane2,lane1,lane0}
    // scanout read: independent port, full qword, registered (1-cyc latency)
    input  wire          scan_rd_en,
    input  wire [AW-1:0] scan_rd_qw,
    output wire [63:0]   scan_rd_qword
);
    // composite-read copy (rd_*) of the four lane banks
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank0 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank1 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank2 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank3 [0:FB_QWORDS-1];
    // scanout-read copy (scan_*) — identical contents, written in lockstep
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] sbank0 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] sbank1 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] sbank2 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] sbank3 [0:FB_QWORDS-1];

    // composite writes exactly one lane per cycle (both copies get the identical write)
    wire we0 = wr_en & (wr_lane == 2'd0);
    wire we1 = wr_en & (wr_lane == 2'd1);
    wire we2 = wr_en & (wr_lane == 2'd2);
    wire we3 = wr_en & (wr_lane == 2'd3);

    always @(posedge clk) if (we0) begin bank0[wr_qw] <= wr_pix; sbank0[wr_qw] <= wr_pix; end
    always @(posedge clk) if (we1) begin bank1[wr_qw] <= wr_pix; sbank1[wr_qw] <= wr_pix; end
    always @(posedge clk) if (we2) begin bank2[wr_qw] <= wr_pix; sbank2[wr_qw] <= wr_pix; end
    always @(posedge clk) if (we3) begin bank3[wr_qw] <= wr_pix; sbank3[wr_qw] <= wr_pix; end

    // composite RMW read port
    reg [15:0] q0, q1, q2, q3;
    always @(posedge clk) if (rd_en) begin
        q0 <= bank0[rd_qw]; q1 <= bank1[rd_qw];
        q2 <= bank2[rd_qw]; q3 <= bank3[rd_qw];
    end
    assign rd_qword = {q3, q2, q1, q0};

    // scanout read port (independent)
    reg [15:0] s0, s1, s2, s3;
    always @(posedge clk) if (scan_rd_en) begin
        s0 <= sbank0[scan_rd_qw]; s1 <= sbank1[scan_rd_qw];
        s2 <= sbank2[scan_rd_qw]; s3 <= sbank3[scan_rd_qw];
    end
    assign scan_rd_qword = {s3, s2, s1, s0};
endmodule
`default_nettype wire
