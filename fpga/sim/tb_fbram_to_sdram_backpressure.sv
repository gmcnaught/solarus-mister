// tb_fbram_to_sdram_backpressure.sv -- proves fbram_to_sdram's `consumer_ready`
// backpressure input actually freezes/resumes correctly, rather than silently
// dropping or duplicating qwords the way a no-backpressure streamer would.
//
// This is the regression guard for the Quartus M10K fit failure ("needs more
// than 553 [blocks]"): the original fbram_to_sdram had no way to pause, so
// blitter_top paired it with a 32768-entry elastic FIFO sized to survive ch0's
// worst-case cold-miss latency without ever overflowing. That FIFO alone blew
// the fit. The fix makes the streamer pace itself off consumer_ready instead
// (see fbram_to_sdram.sv's header) -- this TB is the proof that pacing is
// actually lossless and glitch-free, not just plausible-looking RTL.
//
// Unlike tb_fbram_to_sdram.sv (which never deasserts backpressure and only
// proves the happy-path walk is correct), this TB drives consumer_ready with
// a repeating stall pattern -- low for STALL_LEN of every STALL_PERIOD cycles
// -- for the ENTIRE run, so the DUT is forced through many multi-cycle
// freeze/resume transitions well before, during, and after the midpoint of
// the stream. It checks two independent properties:
//   (a) FREEZE STABILITY: whenever a presented write (sdram_wr_en=1) was NOT
//       accepted (consumer_ready=0) on a given cycle, the NEXT cycle's
//       sdram_wr_en/addr/data must be bit-for-bit identical -- the DUT must
//       hold, never re-pulse or drift.
//   (b) LOSSLESS/IN-ORDER: exactly FB_QWORDS writes are ever accepted
//       (consumer_ready & sdram_wr_en), and their (addr,data) sequence in
//       acceptance order matches the same per-qword pattern
//       tb_fbram_to_sdram.sv checks -- no qword dropped, none duplicated,
//       none reordered.
`timescale 1ns/1ps
module tb_fbram_to_sdram_backpressure;
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1;

  localparam integer CELL_ROW_QW = 80; // 320px * 2B / 8
`ifdef FBRAM_SDRAM_FULL
  localparam integer CELL_ROWS = 240;  // full 320x240 WORK cell (nightly)
`else
  localparam integer CELL_ROWS = 24;   // reduced default: still crosses many stride wraps
`endif
  localparam integer NQW = CELL_ROW_QW*CELL_ROWS;  // full 320x240 WORK-buffer cell
  localparam integer AW  = 15;
  localparam integer STRIDE = 160;     // e.g. a map twice as wide as one cell

  reg          wr_en=0; reg [AW-1:0] wr_qw=0; reg [1:0] wr_lane=0; reg [15:0] wr_pix=0;
  wire         rd_en; wire [AW-1:0] rd_qw; wire [63:0] rd_qword;
  wire [63:0]  scan_rd_qword;

  reg          start;
  wire         busy;
  wire         sdram_wr_en;
  wire [23:0]  sdram_wr_addr;
  wire [63:0]  sdram_wr_data;

  // ---- backpressure stimulus: repeating stall pattern, low (not-ready) for
  // STALL_LEN of every STALL_PERIOD cycles, for the WHOLE run. This is far
  // more aggressive/frequent than a real ch0 cold-miss (30+ cycles, but not
  // on every write) -- deliberately so, to exercise many freeze/resume edges
  // rather than relying on one lucky stall window.
  localparam integer STALL_PERIOD = 37;
  localparam integer STALL_LEN    = 15;
  reg [31:0] pcyc;
  always @(posedge clk) begin
    if (rst) pcyc <= 32'd0; else pcyc <= pcyc + 32'd1;
  end
  wire consumer_ready = (pcyc % STALL_PERIOD) >= STALL_LEN;

  comp_fbram #(.FB_QWORDS(NQW), .AW(AW)) u_fbram (
    .clk(clk),
    .wr_en(wr_en), .wr_qw(wr_qw), .wr_lane(wr_lane), .wr_pix(wr_pix),
    .rd_en(rd_en), .rd_qw(rd_qw), .rd_qword(rd_qword),
    .scan_rd_en(1'b0), .scan_rd_qw({AW{1'b0}}), .scan_rd_qword(scan_rd_qword),
    .snap_we(1'b0), .snap_qw({AW{1'b0}}), .snap_qword(64'd0)
  );

  fbram_to_sdram #(.FB_QWORDS(NQW), .AW(AW), .CELL_ROW_QW(CELL_ROW_QW), .CELL_ROWS(CELL_ROWS)) dut (
    .clk(clk), .rst(rst), .start(start), .dst_stride_qw(STRIDE[23:0]),
    .argb4444_mode(1'b0), .rd_cov(4'd0),   // opt out of ARGB4444 pack mode -- this TB predates it
    .busy(busy),
    .rd_en(rd_en), .rd_qw(rd_qw), .rd_qword(rd_qword),
    .sdram_wr_en(sdram_wr_en), .sdram_wr_addr(sdram_wr_addr), .sdram_wr_data(sdram_wr_data),
    .consumer_ready(consumer_ready)
  );

  function [15:0] vexp(input integer qq, input integer ll);
    vexp = 16'((qq*4 + ll) ^ 16'h5A3C);
  endfunction

  task wr1(input integer qq, input integer ll);
    begin
      @(negedge clk); wr_en<=1; wr_qw<=qq[AW-1:0]; wr_lane<=ll[1:0]; wr_pix<=vexp(qq,ll);
      @(negedge clk); wr_en<=0;
    end
  endtask

  integer i, errors, seen, row, col, q, l;
  reg [23:0] expect_addr;
  reg [63:0] expect_qword;
  reg [63:0] captured [0:NQW-1];
  reg [23:0] captured_addr [0:NQW-1];
  reg captured_v [0:NQW-1];

  // freeze-stability tracking: snapshot of the DUT's presented output on the
  // PREVIOUS sampled cycle, so we can check "held not accepted -> must not
  // change" one cycle later.
  reg        prev_valid;
  reg        prev_en;
  reg [23:0] prev_addr;
  reg [63:0] prev_data;
  reg        prev_ready;
  integer    freeze_violations;

  initial begin
    errors = 0; seen = 0; start = 0; freeze_violations = 0; prev_valid = 0;
    for (i = 0; i < NQW; i = i + 1) captured_v[i] = 0;

    @(negedge clk); rst<=0; @(negedge clk);

    // Fill the WORK buffer with a known per-lane pattern via the real write port.
    for (q = 0; q < NQW; q = q + 1)
      for (l = 0; l < 4; l = l + 1)
        wr1(q, l);

    // Pulse start on the negedge (avoids the same-edge race fixed in
    // tb_fbram_to_sdram.sv).
    @(negedge clk); start <= 1; @(negedge clk); start <= 0;

    for (i = 0; i < NQW*20 && busy; i = i + 1) begin
      // #1 settling delay: consumer_ready is a continuous assignment off the
      // pcyc counter (itself a register updated via NBA on this same edge), so
      // sampling immediately at the edge (as tb_fbram_to_sdram.sv's always-ready
      // TB safely does) can race the DUT's own NBA-updated sdram_wr_en/data --
      // reading a mix of pre/post-edge values. Waiting 1 time unit lets every
      // NBA update and dependent continuous assignment settle before we read.
      @(posedge clk); #1;

      // (a) FREEZE STABILITY: a write presented-but-not-accepted last cycle
      // must be held BIT-FOR-BIT stable this cycle (no re-pulse, no drift).
      if (prev_valid && prev_en && !prev_ready) begin
        if (sdram_wr_en !== prev_en || sdram_wr_addr !== prev_addr || sdram_wr_data !== prev_data) begin
          $display("FAIL: freeze violation at iter %0d: prev(en=%0d addr=%0d data=%h) now(en=%0d addr=%0d data=%h)",
                    i, prev_en, prev_addr, prev_data, sdram_wr_en, sdram_wr_addr, sdram_wr_data);
          freeze_violations = freeze_violations + 1;
        end
      end

      // (b) LOSSLESS/IN-ORDER: capture only ACCEPTED writes (en && ready) --
      // exactly one entry per qword actually retired, in production order.
      if (sdram_wr_en && consumer_ready) begin
        if (seen < NQW) begin
          captured[seen] = sdram_wr_data;
          captured_addr[seen] = sdram_wr_addr;
          captured_v[seen] = 1;
        end
        seen = seen + 1;
      end

      prev_valid <= 1'b1;
      prev_en    <= sdram_wr_en;
      prev_addr  <= sdram_wr_addr;
      prev_data  <= sdram_wr_data;
      prev_ready <= consumer_ready;
    end
    repeat (4) @(posedge clk);

    if (seen != NQW) begin
      $display("FAIL: accepted %0d qwords, expected %0d (dropped or duplicated)", seen, NQW);
      errors = errors + 1;
    end
    for (i = 0; i < NQW; i = i + 1) begin
      row = i / CELL_ROW_QW; col = i % CELL_ROW_QW;
      expect_addr = row*STRIDE + col;
      expect_qword = {vexp(i,3), vexp(i,2), vexp(i,1), vexp(i,0)};
      if (!captured_v[i]) begin
        $display("FAIL: qword %0d never accepted", i); errors = errors + 1;
      end else if (captured[i] !== expect_qword) begin
        $display("FAIL: qword %0d data mismatch: got %h want %h", i, captured[i], expect_qword);
        errors = errors + 1;
      end else if (captured_addr[i] !== expect_addr) begin
        $display("FAIL: qword %0d addr mismatch: got %0d want %0d (row=%0d col=%0d)",
                  i, captured_addr[i], expect_addr, row, col);
        errors = errors + 1;
      end
    end

    if (freeze_violations != 0) begin
      $display("FAIL: %0d freeze violations (presented output changed while frozen)", freeze_violations);
      errors = errors + freeze_violations;
    end

    $display("RESULT: %s", (errors == 0) ? "PASS" : "FAIL");
    $finish;
  end

  initial begin #200000000 $display("RESULT: FAIL (timeout/hang)"); $finish; end
endmodule
