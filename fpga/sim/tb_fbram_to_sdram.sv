`timescale 1ns/1ps
module tb_fbram_to_sdram;
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1;

  localparam integer CELL_ROW_QW = 80; // 320px * 2B / 8
  localparam integer NQW = CELL_ROW_QW*3;  // 3 rows -- exercises 2 stride-jump boundaries
  localparam integer AW  = 15;
  localparam integer STRIDE = 160;     // e.g. a map twice as wide as one cell

  // composite write into the real WORK buffer (comp_fbram), one pixel/lane per cycle
  reg          wr_en=0; reg [AW-1:0] wr_qw=0; reg [1:0] wr_lane=0; reg [15:0] wr_pix=0;
  // work read port: DUT drives it directly (single reader, no mux needed in this TB)
  wire         rd_en; wire [AW-1:0] rd_qw; wire [63:0] rd_qword;
  // unused comp_fbram ports (scan/snapshot side) -- tied off
  wire [63:0]  scan_rd_qword;

  reg          start;
  wire         busy;
  wire         sdram_wr_en;
  wire [23:0]  sdram_wr_addr;
  wire [63:0]  sdram_wr_data;

  comp_fbram #(.FB_QWORDS(NQW), .AW(AW)) u_fbram (
    .clk(clk),
    .wr_en(wr_en), .wr_qw(wr_qw), .wr_lane(wr_lane), .wr_pix(wr_pix),
    .rd_en(rd_en), .rd_qw(rd_qw), .rd_qword(rd_qword),
    .scan_rd_en(1'b0), .scan_rd_qw({AW{1'b0}}), .scan_rd_qword(scan_rd_qword),
    .snap_we(1'b0), .snap_qw({AW{1'b0}}), .snap_qword(64'd0)
  );

  fbram_to_sdram #(.FB_QWORDS(NQW), .AW(AW), .CELL_ROW_QW(CELL_ROW_QW), .CELL_ROWS(3)) dut (
    .clk(clk), .rst(rst), .start(start), .dst_stride_qw(STRIDE[23:0]), .busy(busy),
    .rd_en(rd_en), .rd_qw(rd_qw), .rd_qword(rd_qword),
    .sdram_wr_en(sdram_wr_en), .sdram_wr_addr(sdram_wr_addr), .sdram_wr_data(sdram_wr_data)
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

  initial begin
    errors = 0; seen = 0; start = 0;
    for (i = 0; i < NQW; i = i + 1) captured_v[i] = 0;

    @(negedge clk); rst<=0; @(negedge clk);

    // Fill the WORK buffer with a known per-lane pattern via the real write port.
    for (q = 0; q < NQW; q = q + 1)
      for (l = 0; l < 4; l = l + 1)
        wr1(q, l);

    // Pulse start on the negedge (avoids the same-edge race fixed earlier).
    @(negedge clk); start <= 1; @(negedge clk); start <= 0;

    for (i = 0; i < NQW*3 && busy; i = i + 1) begin
      @(posedge clk);
      if (sdram_wr_en) begin
        captured[seen] = sdram_wr_data;
        captured_addr[seen] = sdram_wr_addr;
        captured_v[seen] = 1;
        seen = seen + 1;
      end
    end
    repeat (4) @(posedge clk);

    if (seen != NQW) begin
      $display("FAIL: wrote %0d qwords, expected %0d", seen, NQW); errors = errors + 1;
    end
    for (i = 0; i < NQW; i = i + 1) begin
      row = i / CELL_ROW_QW; col = i % CELL_ROW_QW;
      expect_addr = row*STRIDE + col;
      expect_qword = {vexp(i,3), vexp(i,2), vexp(i,1), vexp(i,0)};
      if (!captured_v[i]) begin
        $display("FAIL: qword %0d never written", i); errors = errors + 1;
      end else if (captured[i] !== expect_qword) begin
        $display("FAIL: qword %0d data mismatch: got %h want %h", i, captured[i], expect_qword);
        errors = errors + 1;
      end else if (captured_addr[i] !== expect_addr) begin
        $display("FAIL: qword %0d addr mismatch: got %0d want %0d (row=%0d col=%0d)",
                  i, captured_addr[i], expect_addr, row, col);
        errors = errors + 1;
      end
    end
    $display("RESULT: %s", (errors == 0) ? "PASS" : "FAIL");
    $finish;
  end
endmodule
