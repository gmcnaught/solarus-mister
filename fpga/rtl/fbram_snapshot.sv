// fbram_snapshot.sv — vblank work->scan copy controller for the double-buffered
// comp_fbram. On a `start` pulse it streams the entire WORK buffer (comp_fbram rd_*)
// into the SCAN buffer (comp_fbram snap_*), one qword per cycle, then drops `busy`.
//
// The controller borrows comp_fbram's work read port (rd_*) — so a mux must route rd_*
// from this module while `busy`, and the caller must keep the compositor idle during the
// copy (it runs in vblank, between frames). comp_fbram's work read is registered (1-cyc),
// so the snapshot write of address k lags its read-issue by TWO cycles (this module's
// registered rd_* output is one cycle, comp_fbram's registered read is the second).
//
// Cost: ~FB_QWORDS+1 cycles (19200+1 ≈ 0.2ms @96MHz) — easily inside the ~1.4ms vblank.
// Copyright (C) 2026 — GPL-3.0
`default_nettype none
module fbram_snapshot #(
    parameter integer FB_QWORDS = 19200,
    parameter integer AW        = 15
)(
    input  wire          clk,
    input  wire          rst,
    input  wire          start,        // 1-cyc pulse: begin a work->scan copy
    output reg           busy,         // high for the duration of the copy
    // work-buffer read port (mux onto comp_fbram rd_* while busy)
    output reg           rd_en,
    output reg [AW-1:0]  rd_qw,
    input  wire [63:0]   rd_qword,      // registered, valid 1 cyc after rd_qw/rd_en
    // scan-buffer snapshot write port (comp_fbram snap_*)
    output reg           snap_we,
    output reg [AW-1:0]  snap_qw,
    output reg [63:0]    snap_qword
);
    localparam [AW:0] NQW = FB_QWORDS[AW:0];

    reg [AW:0] rptr;        // next work address to read (0..NQW)
    reg [AW:0] wcnt;        // qwords written so far (0..NQW)
    // 2-stage read pipeline: stage1 = read issued this cycle (addr on rd_qw next cycle);
    // stage2 = its data on rd_qword (one more cycle later) → write then.
    reg        v1, v2;
    reg [AW-1:0] a1, a2;
    localparam [AW:0] ONE = {{(AW){1'b0}},1'b1};

    always @(posedge clk) begin
        if (rst) begin
            busy<=1'b0; rd_en<=1'b0; snap_we<=1'b0;
            rptr<={(AW+1){1'b0}}; wcnt<={(AW+1){1'b0}}; v1<=1'b0; v2<=1'b0;
        end else begin
            rd_en<=1'b0; snap_we<=1'b0;
            if (!busy) begin
                v1<=1'b0; v2<=1'b0;
                if (start) begin
                    busy<=1'b1; rptr<={(AW+1){1'b0}}; wcnt<={(AW+1){1'b0}};
                end
            end else begin
                // write the qword whose read was issued two cycles ago (data valid now)
                if (v2) begin
                    snap_we<=1'b1; snap_qw<=a2; snap_qword<=rd_qword;
                    wcnt<=wcnt+ONE;
                end
                // issue the next work read, if any remain
                if (rptr < NQW) begin
                    rd_en<=1'b1; rd_qw<=rptr[AW-1:0];
                    v1<=1'b1; a1<=rptr[AW-1:0];
                    rptr<=rptr+ONE;
                end else begin
                    v1<=1'b0;
                end
                // advance the second pipeline stage
                v2<=v1; a2<=a1;
                // done once every qword has been written
                if (wcnt == NQW) busy<=1'b0;
            end
        end
    end
endmodule
`default_nettype wire
