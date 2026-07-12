// comp_fbram.sv — on-chip framebuffer for the FB-in-BRAM compositor.
//
// 4 lane-banks × 16-bit × FB_QWORDS (=19200 for 320×240 RGB565).
//   qword index = y*80 + (x>>2);  lane = x[1:0].
//
// DOUBLE-BUFFERED (snapshot) framebuffer. Two independent 1W1R buffers built from the
// four lane banks each:
//   WORK buffer (bank0-3):  composite write (wr_*, lane-selected, 1 px/cyc) + the
//                           compositor's RMW dst read (rd_*). PERSISTS across frames, so
//                           Solarus's incremental/persistence draw model needs no carry-
//                           forward — the prior frame is already here.
//   SCAN buffer (sbank0-3): the scanout reader's line fetch (scan_*) reads it; it is
//                           refreshed ONLY by the snapshot write port (snap_*), which a
//                           controller drives once per frame during vblank to copy the
//                           completed work buffer across. Because scanout never reads a
//                           buffer being composited, the image is TEAR-FREE.
// Cost: ~2× the 1W1R block count (~320 M10K) — unchanged from the prior lockstep 1W2R
// layout (same M10K, reorganized work/scan + a snapshot copy). Each bank is a clean
// 1-write/1-read full-width RAM → M10K.
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
    output wire [63:0]   scan_rd_qword,
    // snapshot write: full-qword write into the scanout buffer (vblank work->scan copy)
    input  wire          snap_we,
    input  wire [AW-1:0] snap_qw,
    input  wire [63:0]   snap_qword       // {lane3,lane2,lane1,lane0}
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

    // composite writes exactly one lane per cycle into the WORK buffer only
    wire we0 = wr_en & (wr_lane == 2'd0);
    wire we1 = wr_en & (wr_lane == 2'd1);
    wire we2 = wr_en & (wr_lane == 2'd2);
    wire we3 = wr_en & (wr_lane == 2'd3);

    always @(posedge clk) if (we0) bank0[wr_qw] <= wr_pix;
    always @(posedge clk) if (we1) bank1[wr_qw] <= wr_pix;
    always @(posedge clk) if (we2) bank2[wr_qw] <= wr_pix;
    always @(posedge clk) if (we3) bank3[wr_qw] <= wr_pix;

    // SNAPSHOT write into the scanout buffer (all four lanes at once). The scanout buffer
    // is NOT a live mirror of the work buffer — it is refreshed only by this port, which a
    // controller drives once per frame during vblank (work->scan copy). Decoupling the two
    // is what makes scanout tear-free: it never reads a buffer being composited.
    always @(posedge clk) if (snap_we) begin
        sbank0[snap_qw] <= snap_qword[15:0];   sbank1[snap_qw] <= snap_qword[31:16];
        sbank2[snap_qw] <= snap_qword[47:32];  sbank3[snap_qw] <= snap_qword[63:48];
    end

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

    // scanout read port (independent)
    reg [15:0] s0, s1, s2, s3;
    always @(posedge clk) if (scan_rd_en) begin
        s0 <= sbank0[scan_rd_qw]; s1 <= sbank1[scan_rd_qw];
        s2 <= sbank2[scan_rd_qw]; s3 <= sbank3[scan_rd_qw];
    end
    assign scan_rd_qword = {s3, s2, s1, s0};

`ifdef FABRIC_ASSERT
    // [#110 SVA] SCAN read-during-write hazard. The snapshot (snap_*) writes the SCAN
    // buffer while the scanout reader (scan_*) reads it. These banks are "no_rw_check"
    // M10K, so a SAME-CYCLE, SAME-ADDRESS read returns OLD data -> a torn scanline. It is
    // safe ONLY by the timing guarantee that the WORK->SCAN snapshot runs entirely within
    // vblank, where scanout does not fetch. Assert the two ports never collide on a qword.
    // Guard with === 1'b1 so a TB that leaves the scan/snap ports UNCONNECTED (they float
    // to z, and z==z would spuriously trip a plain ==) does not false-fire; only a real
    // driven-high collision on a matching address asserts.
    always @(posedge clk)
      if ((snap_we === 1'b1) && (scan_rd_en === 1'b1))
        assert (snap_qw !== scan_rd_qw)
        else $display("FABRIC-ASSERT FAIL [comp_fbram]: SCAN read-during-write same qword=%0d @%0t -> torn scanout (no_rw_check M10K)", snap_qw, $time);
`endif
endmodule
`default_nettype wire
