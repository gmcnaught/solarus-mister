`timescale 1ns/1ps
module tb_fbram_to_sdram;
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1;

  localparam integer NQW = 19200;      // 320x240 @ 16bpp WORK buffer
  localparam integer CELL_ROW_QW = 80; // 320px * 2B / 8
  localparam integer STRIDE = 160;     // e.g. a map twice as wide as one cell
  reg [63:0] mem_model [0:NQW-1];

  reg          start;
  wire         busy;
  wire         rd_en;
  wire [14:0]  rd_qw;
  reg  [63:0]  rd_qword;
  wire         sdram_wr_en;
  wire [23:0]  sdram_wr_addr;
  wire [63:0]  sdram_wr_data;

  fbram_to_sdram #(.FB_QWORDS(NQW), .AW(15), .CELL_ROW_QW(CELL_ROW_QW), .CELL_ROWS(240)) dut (
    .clk(clk), .rst(rst), .start(start), .dst_stride_qw(STRIDE[23:0]), .busy(busy),
    .rd_en(rd_en), .rd_qw(rd_qw), .rd_qword(rd_qword),
    .sdram_wr_en(sdram_wr_en), .sdram_wr_addr(sdram_wr_addr), .sdram_wr_data(sdram_wr_data)
  );

  reg [14:0] rd_qw_q; reg rd_en_q;
  always @(posedge clk) begin
    rd_qw_q <= rd_qw; rd_en_q <= rd_en;
    if (rd_en_q) rd_qword <= mem_model[rd_qw_q];
  end

  integer i, errors, seen, row, col;
  reg [23:0] expect_addr;
  reg [63:0] captured [0:NQW-1];
  reg [23:0] captured_addr [0:NQW-1];
  reg captured_v [0:NQW-1];

  initial begin
    for (i = 0; i < NQW; i = i + 1) begin
      mem_model[i] = {32'hCAFE_0000 + i, i[31:0]};
      captured_v[i] = 0;
    end
    start = 0; errors = 0; seen = 0;
    repeat (4) @(posedge clk); rst = 0;
    repeat (2) @(posedge clk);
    start = 1; @(posedge clk); start = 0;
    @(posedge clk);

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
    // Verify the STRIDED address pattern: qword k (0-indexed) -> row=k/80,
    // col=k%80 -> expected addr = row*STRIDE + col.
    for (i = 0; i < NQW; i = i + 1) begin
      row = i / CELL_ROW_QW; col = i % CELL_ROW_QW;
      expect_addr = row*STRIDE + col;
      if (!captured_v[i]) begin
        $display("FAIL: qword %0d never written", i); errors = errors + 1;
      end else if (captured[i] !== mem_model[i]) begin
        $display("FAIL: qword %0d data mismatch: got %h want %h", i, captured[i], mem_model[i]);
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
