// ddr3_scan_adapter.sv — bridge the scanout reader's P_SCAN cache-ok protocol to
// the DDR3 framebuffer double-buffer [Stage 5 Phase 2 Task 6 un-bridge].
//
// comp_fbram (FB-in-BRAM) is gone (Stage 5 Phase 2 moved the scanout copy back to
// DDR3); this is its replacement, shaped like the retired `fbram_scan_adapter.sv`
// (same reader-facing sibling), but instead of a 1-cycle on-chip read it hides a
// real DDR3 round-trip.
//
// The reader (openbor_video_reader) fetches each scanline qword-by-qword with the
// cache-ok handshake: it pulses/holds scn_rd with a byte address scn_addr and
// captures scn_dout on the rising edge of scn_ok, holding the request until ok
// arrives (so it tolerates arbitrary per-qword latency; see openbor_video_reader.sv
// ST_WAIT_LINE). Paying a full DDR3 round-trip for EVERY one of the 80 qwords in a
// scanline would be needlessly slow and would hammer the shared f2h port with 80
// single-beat commands per line. Instead this adapter issues ONE line-granular
// DDR3 burst read (LINE_QW=80 qwords) per scanline into a small internal line
// buffer, and serves each scn_rd request out of that buffer -- the DDR3 latency is
// paid once (for the line's first qword), not once per qword.
//
// Do NOT add a second read-ahead FIFO here: the reader's own `linebuf` (a plain
// BRAM array, NOT a dcfifo -- see docs/superpowers/data/stage5/phase2-reader-audit.md
// part (a)) already provides the line ping-pong that lets line N+1's fetch overlap
// line N's display. This adapter's internal line buffer is a DIFFERENT, narrower
// thing: it exists purely to convert the reader's per-qword cache-ok requests into
// one DDR3 burst command, the same relationship fbram_scan_adapter had to
// comp_fbram's 1-cycle port, just with the added job of hiding real DDR3 latency.
//
// Addressing: scn_addr stays a SMALL relative byte offset into the DDR3 FB region
// (0 for FB0's beat 0, or +DDR3_SCAN_BUF1_OFF (openbor_video_reader.sv) for FB1) --
// NOT the real ~1GB-space physical address (scn_addr is only 27 bits; the reader's
// buf_base_addr mux already folds active_buffer into this, see
// openbor_video_reader.sv ST_CHECK_CTRL). This adapter adds the fixed `FB_DDR0_QW`
// physical base (vram_defs.vh) to (scn_addr>>3) to get the real DDR3 qword address
// -- `FB_DDR0_QW` + 0x8000 == `FB_DDR1_QW` exactly, so buf0/buf1 both resolve
// correctly through the one addition.
//
// New-line detection: the reader always fetches a scanline as 80 STRICTLY
// SEQUENTIAL qwords (scan_addr += 8 each accepted beat), one request outstanding
// at a time (hold-until-ok), and only starts the next line/frame after the
// current line's LAST beat (offset 79) has been served. A fresh request is a
// new line/frame whenever either (a) its address isn't the previous request's
// address + 8, OR (b) the previous request WAS a line's last beat (offset 79)
// -- (b) matters because lines/frames sit back-to-back in scan_addr space with
// no gap (buf_base_addr + display_line*640), so "line N+1 beat 0" is numerically
// identical to what "line N beat 80" would have been; address alone can't tell
// the two apart. Because the previous line's last beat can only be served once
// its burst has delivered all LINE_QW qwords, any earlier burst is GUARANTEED
// fully drained before a new one starts -- no in-flight burst is ever
// abandoned/overwritten mid-flight.
//
// DDR3 read master: a plain single-outstanding-burst Avalon-MM-style read port
// (ddr_addr/ddr_burstcnt/ddr_rd held until accepted, ddr_dout/ddr_dout_ready
// streamed back, ddr_busy backpressure), shaped like the reader's own ddr_* master
// and the blt_*/rdr_* masters in ddr_blitter_arb.sv. Giving this its own arbiter
// leg + wiring it into ddr_blitter_arb.sv is Task 8's scope, NOT this one's --
// here it connects straight to a DDR3 model in tb_scanout_ddr3.sv.
`default_nettype none
`include "vram_defs.vh"

module ddr3_scan_adapter (
    input  wire        clk,      // ddr_clk domain, same clock as the reader
    input  wire        reset,

    // reader side — P_SCAN cache-ok protocol (unchanged from fbram_scan_adapter)
    input  wire [26:0] scn_addr,
    input  wire        scn_rd,
    output reg  [63:0] scn_dout,
    output reg         scn_ok,

    // DDR3 read master (own arbiter leg, wired in Task 8; read-only, single
    // burst outstanding at a time)
    output reg  [28:0] ddr_addr,
    output reg  [7:0]  ddr_burstcnt,
    output reg         ddr_rd,
    input  wire [63:0] ddr_dout,
    input  wire        ddr_dout_ready,
    input  wire        ddr_busy
);

    localparam integer LINE_QW = 80;   // 320px*2B/8B = one scanline (== reader's LINE_BURST)

    (* ramstyle = "no_rw_check, M10K" *) reg [63:0] linebuf [0:LINE_QW-1];

    reg  [6:0]  fill_count;      // # qwords delivered for the in-flight/latest burst (0..80)
    reg         bursting;        // a DDR3 burst is currently streaming into linebuf
    reg  [26:0] expect_addr;     // byte address expected for the NEXT reader request
    reg         line_active;     // expect_addr is meaningful (a line fetch is under way)
    reg  [6:0]  active_offset;   // offset (0..79) of the outstanding reader request
    reg         active_pending;  // waiting for linebuf[active_offset] to be filled

    reg         scn_rd_d;
    wire        req_rise = scn_rd & ~scn_rd_d;
    // A line is always exactly LINE_QW (80) qwords (the reader's own LINE_BURST
    // contract), and lines/frames are laid out back-to-back in scan_addr space
    // (buf_base_addr + display_line*640) with NO gap -- so a fresh line's beat 0
    // address is numerically indistinguishable from "this line's beat 80" would
    // be (both == prior expect_addr). Address-match alone cannot detect the
    // boundary; also require the previous request NOT have been this line's
    // last beat (offset LINE_QW-1).
    wire        continuing = line_active && (scn_addr == expect_addr)
                              && (active_offset != LINE_QW-1);

    // Physical DDR3 qword target for a fresh burst starting at scn_addr's line.
    // scn_addr[26:3] is the relative qword offset (0 buf0 / 0x8000+ buf1); adding
    // FB_DDR0_QW lands on FB_DDR0_QW (buf0) or exactly FB_DDR1_QW (buf1).
    wire [28:0] burst_qw_addr = `FB_DDR0_QW + {5'd0, scn_addr[26:3]};

    integer li;
    always @(posedge clk) begin
        scn_rd_d <= scn_rd;
        scn_ok   <= 1'b0;

        if (reset) begin
            fill_count     <= 7'd0;
            bursting       <= 1'b0;
            line_active    <= 1'b0;
            expect_addr    <= 27'd0;
            active_offset  <= 7'd0;
            active_pending <= 1'b0;
            ddr_addr       <= 29'd0;
            ddr_burstcnt   <= 8'd0;
            ddr_rd         <= 1'b0;
            scn_dout       <= 64'd0;
        end
        else begin
            // -- DDR3 burst command: hold ddr_rd until the arbiter/memory accepts it --
            if (ddr_rd && !ddr_busy) ddr_rd <= 1'b0;

            // -- DDR3 burst receive: stream beats into the line buffer -------------
            if (bursting && ddr_dout_ready) begin
                linebuf[fill_count[6:0]] <= ddr_dout;
                fill_count <= fill_count + 7'd1;
                if (fill_count == LINE_QW - 1) bursting <= 1'b0;
            end

            // -- reader request handling -------------------------------------------
            if (req_rise) begin
                if (continuing) begin
                    // Same line, next sequential qword -- already prefetched (or
                    // about to be) by the burst kicked off at this line's beat 0.
                    active_offset <= active_offset + 7'd1;
                end
                else begin
                    // New line (first beat of a frame/line, or a re-anchored jump):
                    // (re)start the burst. The previous burst is guaranteed fully
                    // drained by now -- reaching a new ST_READ_LINE requires the
                    // prior line's last beat (offset 79) to have been served, which
                    // requires fill_count==LINE_QW, i.e. that burst already delivered
                    // every qword.
                    active_offset <= 7'd0;
                    fill_count    <= 7'd0;
                    bursting      <= 1'b1;
                    ddr_addr      <= burst_qw_addr;
                    ddr_burstcnt  <= LINE_QW[7:0];
                    ddr_rd        <= 1'b1;
                end
                line_active    <= 1'b1;
                expect_addr    <= scn_addr + 27'd8;
                active_pending <= 1'b1;
            end

            // -- serve the outstanding request once its qword has landed ----------
            if (active_pending && (fill_count > active_offset)) begin
                scn_ok         <= 1'b1;
                scn_dout       <= linebuf[active_offset];
                active_pending <= 1'b0;
            end
        end
    end

`ifdef FABRIC_ASSERT
    // [Stage5 P2 Task6 SVA] Underrun guard: for every beat AFTER a line's first
    // (which necessarily pays the initial DDR3 round-trip), the requested qword
    // must ALREADY be resident in linebuf by the time the reader asks for it --
    // that is the whole point of the line-granular prefetch (pay the DDR3
    // round-trip once per line, not once per qword). iverilog only supports
    // immediate assertions (no concurrent `assert property`); "FAIL" in the
    // message trips run_sims.sh's FAIL_RE.
    wire [6:0] nxt_offset = active_offset + 7'd1;
    always @(posedge clk) if (!reset && req_rise && continuing)
        assert (fill_count > nxt_offset)
        else $display("FABRIC-ASSERT FAIL [ddr3_scan_adapter]: underrun -- beat offset=%0d requested before the line-burst prefetch delivered it (fill_count=%0d) @%0t", nxt_offset, fill_count, $time);
`endif

endmodule
`default_nettype wire
