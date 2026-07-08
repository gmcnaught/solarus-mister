// fbram_to_sdram.sv -- one-time WORK-buffer -> SDRAM strided streamer for the
// Phase 3b background-plane cache. On a `start` pulse it streams the entire
// on-chip comp_fbram WORK buffer (one 320x240 cell, CELL_ROW_QW=80 qwords
// per row x CELL_ROWS=240 rows) out to a caller-supplied SDRAM write port.
// Read side is a straight linear walk of the WORK buffer (comp_fbram itself
// is always flat/contiguous); the WRITE side jumps by `dst_stride_qw`
// (latched at `start`) at every row boundary, so the destination can be a
// wider map-scan-order plane the cell is embedded in (Task 1's layout) --
// `sdram_wr_addr` output is RELATIVE, the caller adds the cell's absolute
// plane base on top (Task 3).
//
// Read pipeline is a near-verbatim copy of fbram_snapshot.sv's (see that
// file's header for why the 2-stage v1/v2 pipeline exists: comp_fbram's
// read is registered, so a read issued at cycle N has data at cycle N+2
// relative to the read-issue pulse); this module additionally pipelines the
// row/col cursor alongside a1/a2 so the write address is available in step
// with the write-enable pulse.
//
// Cost: ~FB_QWORDS+1 cycles per cell (19200+1 ~= 0.2ms @96MHz), same order
// as fbram_snapshot's vblank copy -- but this runs OUTSIDE vblank (during
// the rare one-time bake), so the caller must keep comp_pipeline idle for
// the duration (same contract as fbram_snapshot's borrow of fb_rd_*).
// Copyright (C) 2026 -- GPL-3.0
`default_nettype none
module fbram_to_sdram #(
    parameter integer FB_QWORDS   = 19200,
    parameter integer AW          = 15,
    parameter integer CELL_ROW_QW = 80,    // one WORK-buffer row = 320px*2B/8
    parameter integer CELL_ROWS   = 240
)(
    input  wire          clk,
    input  wire          rst,
    input  wire          start,           // 1-cyc pulse: begin a work->SDRAM copy
    input  wire [23:0]   dst_stride_qw,   // destination row stride (qwords), latched at start
    output reg            busy,
    // work-buffer read port (mux onto comp_fbram rd_* while busy, same as fbram_snapshot)
    output reg           rd_en,
    output reg [AW-1:0]  rd_qw,
    input  wire [63:0]   rd_qword,        // registered, valid 1 cyc after rd_qw/rd_en
    // SDRAM write port (wired to sdram_fb_cache ch0's write side by the caller);
    // sdram_wr_addr is RELATIVE -- caller adds the cell's plane base offset.
    output reg           sdram_wr_en,
    output reg [23:0]    sdram_wr_addr,
    output reg [63:0]    sdram_wr_data
);
    localparam [AW:0] NQW = FB_QWORDS[AW:0];
    localparam integer COLW = $clog2(CELL_ROW_QW);

    reg [AW:0] rptr;
    reg [AW:0] wcnt;
    reg        v1, v2;
    reg [AW-1:0] a1, a2;
    reg [23:0] stride_q;
    reg [COLW-1:0] col1, col2;
    reg [23:0] row_base1, row_base2;
    reg [23:0] cur_row_base;
    reg [COLW-1:0] cur_col;
    localparam [AW:0] ONE = {{(AW){1'b0}},1'b1};

    always @(posedge clk) begin
        if (rst) begin
            busy<=1'b0; rd_en<=1'b0; sdram_wr_en<=1'b0;
            rptr<={(AW+1){1'b0}}; wcnt<={(AW+1){1'b0}}; v1<=1'b0; v2<=1'b0;
            cur_row_base<=24'd0; cur_col<={COLW{1'b0}};
        end else begin
            rd_en<=1'b0; sdram_wr_en<=1'b0;
            if (!busy) begin
                v1<=1'b0; v2<=1'b0;
                if (start) begin
                    busy<=1'b1; rptr<={(AW+1){1'b0}}; wcnt<={(AW+1){1'b0}};
                    stride_q<=dst_stride_qw;
                    cur_row_base<=24'd0; cur_col<={COLW{1'b0}};
                end
            end else begin
                // write the qword whose read was issued two cycles ago
                if (v2) begin
                    sdram_wr_en<=1'b1;
                    sdram_wr_addr<=row_base2 + {{(24-COLW){1'b0}}, col2};
                    sdram_wr_data<=rd_qword;
                    wcnt<=wcnt+ONE;
                end
                // issue the next work read, if any remain, carrying its row/col
                if (rptr < NQW) begin
                    rd_en<=1'b1; rd_qw<=rptr[AW-1:0];
                    v1<=1'b1; a1<=rptr[AW-1:0];
                    row_base1<=cur_row_base; col1<=cur_col;
                    if (cur_col == CELL_ROW_QW-1) begin
                        cur_col<={COLW{1'b0}};
                        cur_row_base<=cur_row_base+stride_q;
                    end else begin
                        cur_col<=cur_col+1'b1;
                    end
                    rptr<=rptr+ONE;
                end else begin
                    v1<=1'b0;
                end
                v2<=v1; a2<=a1; row_base2<=row_base1; col2<=col1;
                if (wcnt == NQW) busy<=1'b0;
            end
        end
    end
endmodule
`default_nettype wire
