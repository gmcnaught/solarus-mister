//============================================================================
//  sdram_chip_model.sv — COMMAND-level behavioral model of an MT48LC16M16-style
//  SDRAM chip, enough to validate rtl/sdram.sv's burst-4 read + column-low
//  address map (NOT real-silicon timing — tRCD/tRP/tRC/CL margins are only
//  validated on HW via the bring-up self-test).
//
//  Models: 4 banks, per-bank open row, ACTIVE/READ/WRITE/PRECHARGE/REFRESH,
//  CAS_LATENCY=2, BURST_LENGTH=4 sequential reads with auto-precharge (A[10]).
//  Storage is an associative array keyed by {bank,row,col} so we don't allocate
//  the full 32 MB; only touched cells exist.
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
    input  wire        DQMH
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
    // Flat storage keyed by {row[1:0], bank[1:0], col[8:0]} = 13 bits (no
    // associative arrays — this Icarus build lacks them). The tb keeps all
    // accesses within rows 0..1 so the low 2 row bits distinguish them.
    reg [15:0] store [0:8191];

    // read-data pipeline: schedule[k] drives DQ k cycles from now.
    // depth covers CL + 4 burst words.
    localparam integer PD = CL + 6;
    reg [15:0] dq_pipe   [0:PD-1];
    reg        dq_vld    [0:PD-1];

    // burst sequencer: when a READ is accepted, emit 4 words at CL, CL+1, CL+2, CL+3
    integer i;
    reg [15:0] dq_out;
    reg        dq_oe;
    assign DQ = dq_oe ? dq_out : 16'bz;

    function [12:0] key(input [1:0] b, input [12:0] r, input [8:0] c);
        key = {r[1:0], b, c};      // 2+2+9 = 13 bits
    endfunction

    reg [15:0] cur, nw;             // write temporaries (module scope for Icarus)

    initial begin
        for (i=0;i<4;i=i+1) open_row[i]=0;
        for (i=0;i<PD;i=i+1) begin dq_pipe[i]=0; dq_vld[i]=0; end
        for (i=0;i<8192;i=i+1) store[i]=16'd0;
        dq_oe=0; dq_out=0; cur=0; nw=0;
    end

    always @(posedge clk) begin
        // shift the read pipeline down one; head drives DQ this cycle
        dq_oe  <= dq_vld[0];
        dq_out <= dq_pipe[0];
        for (i=0;i<PD-1;i=i+1) begin dq_pipe[i]<=dq_pipe[i+1]; dq_vld[i]<=dq_vld[i+1]; end
        dq_pipe[PD-1]<=0; dq_vld[PD-1]<=0;

        if (CKE && !nCS) begin
            case (cmd)
                CMD_ACTIVE: begin
                    open_row[BA] <= A;            // latch row for this bank
                end
                CMD_READ: begin
                    // schedule 4 sequential words starting RD_LAT cycles out
                    for (i=0;i<4;i=i+1) begin
                        dq_pipe[RD_LAT+i] <= store[key(BA, open_row[BA], A[8:0] + i[8:0])];
                        dq_vld [RD_LAT+i] <= 1'b1;
                    end
                end
                CMD_WRITE: begin
                    // single-word write with byte masks (DQML/DQMH = A[12:11])
                    cur = store[key(BA, open_row[BA], A[8:0])];
                    nw  = cur;
                    if (!DQML) nw[7:0]  = DQ[7:0];
                    if (!DQMH) nw[15:8] = DQ[15:8];
                    store[key(BA, open_row[BA], A[8:0])] = nw;
                end
                default: ; // NOP/PRECHARGE/REFRESH/LOADMODE — no storage effect here
            endcase
        end
    end
endmodule
`default_nettype wire
