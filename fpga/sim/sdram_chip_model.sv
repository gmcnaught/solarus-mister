//============================================================================
//  sdram_chip_model.sv — COMMAND-level behavioral model of an MT48LC16M16-style
//  SDRAM chip, enough to validate rtl/sdram.sv's burst-4 read + column-low
//  address map (NOT real-silicon timing — tRCD/tRP/tRC/CL margins are only
//  validated on HW via the bring-up self-test).
//
//  Models: 4 banks, per-bank open row, ACTIVE/READ/WRITE/PRECHARGE/REFRESH,
//  CAS_LATENCY=2, BURST_LENGTH=4 sequential reads with auto-precharge (A[10]).
//  Storage is a FLAT array keyed by {row[12],row[3:0],bank,col[9:0]}=17 bits so we
//  don't allocate the full 64 MB; the tb must keep touched rows distinct in
//  {row[12],row[3:0]} (this Icarus build lacks associative arrays). 10-bit column
//  (1024) matches the AS4C32M16.
//============================================================================
`default_nettype none

module sdram_chip_model (
    input  wire        clk,
    inout  wire [15:0] DQ,
    input  wire [12:0] A,
    input  wire [1:0]  BA,
    input  wire        nCS,
    input  wire        nRAS,
    input  wire        nCAS,
    input  wire        nWE,
    input  wire        CKE,
    input  wire        DQML,
    input  wire        DQMH,
    // sim-only protocol monitor: counts page-open invariant violations.
    output integer     proto_errors
);
    localparam integer CL = 2;   // CAS latency (matches controller)
    // Read-data presentation latency in the ZERO-DELAY sim. On real silicon the
    // SDRAM_CLK phase + IO round-trip give the controller's CAS pipeline its
    // expected alignment (HW-validated). Here we tune RD_LAT so the 4 burst
    // words land in the controller's data_ready_delay capture window.
    localparam integer RD_LAT = 0;

    // command decode (active-low CS gates everything)
    wire [2:0] cmd = {nRAS, nCAS, nWE};
    localparam CMD_NOP=3'b111, CMD_READ=3'b101, CMD_WRITE=3'b100,
               CMD_ACTIVE=3'b011, CMD_PRECHARGE=3'b010, CMD_REFRESH=3'b001,
               CMD_LOADMODE=3'b000;

    reg [12:0] open_row [0:3];
    // Flat storage keyed by {row[12], row[9:0], bank[1:0], col[9:0]} = 23 bits (no
    // associative arrays — this Icarus build lacks them). 10-bit column (1024) for the
    // AS4C32M16.
    //
    // WIDENED for the Task-5 system regression: the old 17-bit key used only
    // row[3:0], so FB0 (byte 0x400000 -> row 0x200) and FB1 (0x440000 -> row 0x220)
    // ALIASED (both row[3:0]=0). The full-screen FB1->FB0 carry-forward COPY would
    // then corrupt the source while writing the dest. row[9:0] makes every row in
    // the heap (row 0) + FB0 (0x200..0x212) + FB1 (0x220..0x232) span DISTINCT, so
    // source and dest framebuffers never collide. (row[12] retained so a >32MB
    // address never aliases row 0.)
    reg [15:0] store [0:(1<<23)-1];

    // read-data pipeline: schedule[k] drives DQ k cycles from now.
    // depth covers CL + 4 burst words.
    localparam integer PD = CL + 6;
    reg [15:0] dq_pipe   [0:PD-1];
    reg        dq_vld    [0:PD-1];

    // ---- write-burst capture (BL=4, NO_WRITE_BURST=0) -----------------------
    // On a WRITE command the chip latches data on that SAME cycle (word0) and on
    // up to 3 following cycles (words 1..3), each gated by that cycle's DQM. A
    // SINGLE-access write is just a WRITE followed by 3 cycles of DQM=11 (the
    // controller masks the trailing words), so this one path serves both. We run
    // a small countdown: wr_cnt>0 means "still inside a write burst, capture this
    // cycle's DQ into the next sequential column". DQM masks per byte per cycle.
    integer wr_cnt;           // words remaining in the current write burst (incl. word0)
    reg [1:0] wr_bank;        // bank latched at the WRITE command
    reg [12:0] wr_row;        // open row latched at the WRITE command
    reg [9:0]  wr_col;        // running column for the burst (10-bit, AS4C32M16)

    // burst sequencer: when a READ is accepted, emit 4 words at CL, CL+1, CL+2, CL+3
    integer i;
    reg [15:0] dq_out;
    reg        dq_oe;
    assign DQ = dq_oe ? dq_out : 16'bz;

    function [22:0] key(input [1:0] b, input [12:0] r, input [9:0] c);
        key = {r[12], r[9:0], b, c};      // 1+10+2+10 = 23 bits
    endfunction

    reg [15:0] cur, nw;             // write temporaries (module scope for Icarus)

    // ---- sim-only protocol monitor ------------------------------------------
    // Two page-open invariants are checked, each clock, by decoding the command
    // pins:
    //   (a) no AUTO_REFRESH may be issued while a line read is in flight, and
    //   (b) no second ACTIVE may be issued while a line is already in flight.
    //
    // "in flight" rule: SET on any ACTIVE. The controller marks the LAST read of
    // a line by asserting A[10] (auto-precharge) on that READ (per Task 2's
    // design), and a WRITE is always single-access (A[10]=1 auto-precharge), so a
    // READ-with-A[10] or any WRITE ends the access — CLEAR in_flight then. An
    // explicit PRECHARGE is likewise a line boundary and CLEARS in_flight.
    // A page-wrap line read (Task 4) crosses a row boundary by issuing an
    // explicit PRECHARGE (closing the current row) FOLLOWED by a new ACTIVE for
    // row+1, mid-line. Because the PRECHARGE clears in_flight FIRST, that
    // following re-ACTIVE is legal (in_flight==0) and does NOT trip the
    // re-ACTIVE-in-flight check. The check still fires on a TRUE violation: an
    // ACTIVE while in_flight with NO intervening PRECHARGE.
    reg in_flight;
    integer refresh_seen;   // count of AUTO_REFRESH commands (sim-only; chip.refresh_seen)

    initial begin
        for (i=0;i<4;i=i+1) open_row[i]=0;
        for (i=0;i<PD;i=i+1) begin dq_pipe[i]=0; dq_vld[i]=0; end
        for (i=0;i<(1<<23);i=i+1) store[i]=16'd0;
        dq_oe=0; dq_out=0; cur=0; nw=0;
        in_flight=0; proto_errors=0; refresh_seen=0;
        wr_cnt=0; wr_bank=0; wr_row=0; wr_col=0;
    end

    always @(posedge clk) begin
        // shift the read pipeline down one; head drives DQ this cycle
        dq_oe  <= dq_vld[0];
        dq_out <= dq_pipe[0];
        for (i=0;i<PD-1;i=i+1) begin dq_pipe[i]<=dq_pipe[i+1]; dq_vld[i]<=dq_vld[i+1]; end
        dq_pipe[PD-1]<=0; dq_vld[PD-1]<=0;

        // ---- protocol monitor (sim-only; no effect on chip storage/DQ) -------
        if (CKE && !nCS) begin
            case (cmd)
                CMD_ACTIVE: begin
                    if (in_flight) begin
                        proto_errors <= proto_errors + 1;
                        $display("PROTO: re-ACTIVE issued while a line is in flight (row=%h bank=%0d)", A, BA);
                    end
                    in_flight <= 1'b1;            // a line begins at ACTIVE
                end
                CMD_REFRESH: begin
                    refresh_seen <= refresh_seen + 1;   // proves the refresh path is exercised
                    if (in_flight) begin
                        proto_errors <= proto_errors + 1;
                        $display("PROTO: AUTO_REFRESH issued while a line is in flight");
                    end
                end
                CMD_READ: begin
                    // A[10] auto-precharge marks the LAST read of the line.
                    if (A[10]) in_flight <= 1'b0;
                end
                CMD_WRITE: begin
                    in_flight <= 1'b0;            // single-access write (auto-precharge)
                end
                CMD_PRECHARGE: begin
                    in_flight <= 1'b0;            // explicit line boundary
                end
                default: ; // NOP/LOADMODE — no in-flight change
            endcase
        end

        // ---- write-burst trailing-word capture --------------------------------
        // While a write burst is in flight (wr_cnt>0) and THIS cycle is not a new
        // WRITE command (handled below), capture the trailing word from DQ into the
        // next sequential column, DQM-masked per byte. A new command (any non-NOP)
        // does NOT pre-empt mid-burst in practice; the controller drives NOPs for
        // words 1..3. We simply count down on every cycle once a burst started.
        if (wr_cnt > 0 && !(CKE && !nCS && cmd == CMD_WRITE)) begin
            cur = store[key(wr_bank, wr_row, wr_col)];
            nw  = cur;
            if (!DQML) nw[7:0]  = DQ[7:0];
            if (!DQMH) nw[15:8] = DQ[15:8];
            store[key(wr_bank, wr_row, wr_col)] = nw;
            wr_col  <= wr_col + 10'd1;
            wr_cnt  <= wr_cnt - 1;
        end

        if (CKE && !nCS) begin
            case (cmd)
                CMD_ACTIVE: begin
                    open_row[BA] <= A;            // latch row for this bank
                end
                CMD_READ: begin
                    // schedule 4 sequential words starting RD_LAT cycles out
                    for (i=0;i<4;i=i+1) begin
                        dq_pipe[RD_LAT+i] <= store[key(BA, open_row[BA], A[9:0] + i[9:0])];
                        dq_vld [RD_LAT+i] <= 1'b1;
                    end
                end
                CMD_WRITE: begin
                    // word0 is presented WITH the WRITE command. Capture it now
                    // (DQM-masked), latch bank/row/col for the rest of the burst,
                    // and arm the trailing-word capture for words 1..3 (BL=4). A
                    // SINGLE-access write masks words 1..3 via DQM=11, so storage is
                    // identical to the old single-word path for that case.
                    cur = store[key(BA, open_row[BA], A[9:0])];
                    nw  = cur;
                    if (!DQML) nw[7:0]  = DQ[7:0];
                    if (!DQMH) nw[15:8] = DQ[15:8];
                    store[key(BA, open_row[BA], A[9:0])] = nw;
                    wr_bank <= BA;
                    wr_row  <= open_row[BA];
                    wr_col  <= A[9:0] + 10'd1;    // next sequential column
                    wr_cnt  <= 3;                  // 3 trailing words (BL=4)
                end
                default: ; // NOP/PRECHARGE/REFRESH/LOADMODE — no storage effect here
            endcase
        end
    end
endmodule
`default_nettype wire
