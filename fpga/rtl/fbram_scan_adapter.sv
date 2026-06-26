// fbram_scan_adapter.sv — bridge the scanout reader's P_SCAN cache-ok protocol to
// comp_fbram's simple 1-cycle scan read port [FB-in-BRAM].
//
// The reader (openbor_video_reader) fetches each scanline qword-by-qword with the
// SDRAM cache-ok handshake: it pulses/holds scn_rd with a byte address scn_addr and
// captures scn_dout on the rising edge of scn_ok. comp_fbram instead has a fixed
// 1-cycle read (scan_rd_en + scan_rd_qw -> scan_rd_qword next cycle) and never
// backpressures. This adapter presents the reader-facing cache-ok interface unchanged
// (so the reader FSM is untouched) and drives comp_fbram's scan port:
//   on the rising edge of scn_rd, issue one comp_fbram read at qword = scn_addr>>3
//   (single-buffer: the reader's buf_base is 0, so scn_addr = line*640 + beat*8 and
//   scn_addr[17:3] = line*80 + beat), then assert scn_ok one cycle later when
//   scan_rd_qword is valid. One ok per request, exactly like the cache model the
//   reader is validated against (tb_scanout_sdram), with SCAN_LAT = 1.
`default_nettype none
module fbram_scan_adapter (
    input  wire        clk,
    // reader side — P_SCAN cache-ok protocol (unchanged from the SDRAM path)
    input  wire [26:0] scn_addr,
    input  wire        scn_rd,
    output wire [63:0] scn_dout,
    output wire        scn_ok,
    // comp_fbram scan read port
    output wire        scan_rd_en,
    output wire [14:0] scan_rd_qw,
    input  wire [63:0] scan_rd_qword
);
    reg scn_rd_d = 1'b0;
    reg ok_r     = 1'b0;
    always @(posedge clk) begin
        scn_rd_d <= scn_rd;
        ok_r     <= scn_rd & ~scn_rd_d;   // one cycle after a fresh request edge
    end

    wire req_rise = scn_rd & ~scn_rd_d;
    assign scan_rd_en = req_rise;          // pulse the comp_fbram read on each request
    assign scan_rd_qw = scn_addr[17:3];    // byte addr >> 3 = qword (single buffer, base 0)
    assign scn_ok     = ok_r;              // comp_fbram data valid this cycle
    assign scn_dout   = scan_rd_qword;
endmodule
`default_nettype wire
