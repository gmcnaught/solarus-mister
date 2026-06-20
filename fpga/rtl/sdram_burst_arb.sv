// sdram_burst_arb.sv — single-client scan read-burst arbiter over jtframe_burst_sdram.
//
// Task 2: implements the P_SCAN read-burst path.  P_DST and P_SRC are stubbed
// (tied idle) and will be wired in later tasks.
//
// Address mapping (AW=23, 16-bit words, 2-bit bank):
//   ba   = scan_addr[26:25]
//   addr = scan_addr[23:1]   (23-bit word address; bit[0] is the byte select,
//          ignored for 16-bit words). NOTE scan_addr[24] is NOT used — this
//          addresses a 16 MB window per bank (8M words). TODO(JT-T6): confirm no
//          real client (FB/atlas) drives scan_addr[24] before integration.
//
// 16→64 assembly: every 4 consecutive dok beats are packed little-endian into
// scan_dout64: first word → [15:0], second → [31:16], ..., fourth → [63:48].
// scan_dready pulses for one cycle per assembled 64-bit qword.
//
// Refresh: internal counter fires rfsh every 640 clk cycles (~6.4 µs @ 100 MHz),
// matching the smoke testbench convention.
//
// Quartus constraint: one always-block per reg (Error 10028).
//
// Task 2 scope: READ path only. jtframe's wr/din are tied off here; the P_DST
// write-burst path is added in Task 3. The unit test seeds SDRAM by preloading
// the mt48lc16m16a2 model's bank array directly (jtframe's own read-test
// methodology — see ver/sdram/burst_sdram_64mb), so no write-through is needed.
`default_nettype none

module sdram_burst_arb #(
    parameter integer AW       = 23,
    parameter integer HF       = 1,
    parameter integer MISTER   = 0,
    parameter integer PROG_LEN = 64
)(
    input  wire        clk,
    input  wire        rst,

    // jtframe_burst_sdram init flag (high during SDRAM power-on init)
    output wire        init,

    // ---- P_SCAN client -------------------------------------------------------
    input  wire [26:0] scan_addr,    // byte address (little-endian)
    input  wire        scan_rd,      // assert to start a burst read
    input  wire [ 7:0] scan_burst,   // number of 64-bit qwords to fetch
    output wire        scan_busy,    // high while a transaction is in flight
    output reg  [63:0] scan_dout64,  // assembled 64-bit output (valid when scan_dready)
    output reg         scan_dready,  // one-cycle strobe per assembled qword

    // ---- SDRAM physical pins ------------------------------------------------
    inout  wire [15:0] sdram_dq,
    output wire [12:0] sdram_a,
    output wire        sdram_dqml,
    output wire        sdram_dqmh,
    output wire [ 1:0] sdram_ba,
    output wire        sdram_nwe,
    output wire        sdram_ncas,
    output wire        sdram_nras,
    output wire        sdram_ncs,
    output wire        sdram_cke
);

// ---------------------------------------------------------------------------
// Refresh counter — pulse every 640 cycles (~6.4 µs @ 100 MHz)
// ---------------------------------------------------------------------------
localparam integer RFSH_PERIOD = 640;

reg [$clog2(RFSH_PERIOD)-1:0] hcnt;
wire rfsh = (hcnt == 0);

always @(posedge clk or posedge rst) begin
    if (rst)
        hcnt <= 0;
    else
        hcnt <= (hcnt == (RFSH_PERIOD - 1)) ? 0 : hcnt + 1;
end

// ---------------------------------------------------------------------------
// jtframe_burst_sdram consumer signals
// ---------------------------------------------------------------------------
reg  [AW-1:0] jt_addr;
reg  [ 1:0]   jt_ba;
reg            jt_rd;
wire           jt_wr  = 1'b0;   // Task 2 is read-only; write path added in Task 3
wire [15:0]   jt_din = 16'd0;

wire [15:0]   jt_dout;
wire           jt_ack;
wire           jt_dst;
wire           jt_dok;
wire           jt_rdy;

// ---------------------------------------------------------------------------
// jtframe_burst_sdram instance
// ---------------------------------------------------------------------------
jtframe_burst_sdram #(
    .AW      ( AW       ),
    .HF      ( HF       ),
    .MISTER  ( MISTER   ),
    .PROG_LEN( PROG_LEN )
) u_jt (
    .rst        ( rst       ),
    .clk        ( clk       ),
    .init       ( init      ),

    .addr       ( jt_addr   ),
    .ba         ( jt_ba     ),
    .rd         ( jt_rd     ),
    .wr         ( jt_wr     ),
    .din        ( jt_din    ),
    .dout       ( jt_dout   ),
    .ack        ( jt_ack    ),
    .dst        ( jt_dst    ),
    .dok        ( jt_dok    ),
    .rdy        ( jt_rdy    ),

    .prog_en    ( 1'b0            ),
    .prog_addr  ( {AW{1'b0}}      ),
    .prog_rd    ( 1'b0            ),
    .prog_wr    ( 1'b0            ),
    .prog_din   ( 16'h0000        ),
    .prog_dsn   ( 2'b00           ),
    .prog_ba    ( 2'b00           ),
    .prog_dst   (                 ),
    .prog_dok   (                 ),
    .prog_rdy   (                 ),
    .prog_ack   (                 ),

    .rfsh       ( rfsh      ),

    .sdram_dq   ( sdram_dq  ),
    .sdram_a    ( sdram_a   ),
    .sdram_dqml ( sdram_dqml),
    .sdram_dqmh ( sdram_dqmh),
    .sdram_ba   ( sdram_ba  ),
    .sdram_nwe  ( sdram_nwe ),
    .sdram_ncas ( sdram_ncas),
    .sdram_nras ( sdram_nras),
    .sdram_ncs  ( sdram_ncs ),
    .sdram_cke  ( sdram_cke )
);

// ---------------------------------------------------------------------------
// FSM states
// ---------------------------------------------------------------------------
localparam [2:0]
    S_IDLE   = 3'd0,   // waiting for scan_rd
    S_START  = 3'd2,   // latch scan params, assert rd, wait for ack
    S_READ   = 3'd3;   // reading: count dok beats, assemble qwords; → IDLE on completion

reg [2:0] state;

// ---------------------------------------------------------------------------
// Word counter: tracks remaining 16-bit words (initialised to scan_burst*4)
// ---------------------------------------------------------------------------
reg [ 9:0]   word_cnt;    // up to 256 qwords * 4 = 1024 words

// ---------------------------------------------------------------------------
// Beat assembler: beat_pos = 0..3 (position within current qword)
// ---------------------------------------------------------------------------
reg [ 1:0]   beat_pos;    // 0-3

// ---------------------------------------------------------------------------
// 64-bit assembler shift register
// ---------------------------------------------------------------------------
reg [63:0]   asm_reg;

// ---------------------------------------------------------------------------
// scan_busy: high while NOT in IDLE
// ---------------------------------------------------------------------------
assign scan_busy = (state != S_IDLE);

// ---------------------------------------------------------------------------
// State register
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        state <= S_IDLE;
    else begin
        case (state)
            S_IDLE: begin
                if (scan_rd && !init)
                    state <= S_START;
            end
            S_START: begin
                // ack arrives when jtframe accepts the read command
                if (jt_ack)
                    state <= S_READ;
            end
            S_READ: begin
                // Back to IDLE once we've dropped rd (after the last word is counted)
                // and jtframe signals burst completion.
                if (!jt_rd && jt_rdy)
                    state <= S_IDLE;
            end
            default: state <= S_IDLE;
        endcase
    end
end


// ---------------------------------------------------------------------------
// word_cnt register — tracks remaining 16-bit words to receive
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        word_cnt <= 10'd0;
    else if (state == S_IDLE && scan_rd && !init)
        word_cnt <= {scan_burst, 2'b00};  // scan_burst * 4
    else if (state == S_READ && jt_dok && word_cnt != 0)
        word_cnt <= word_cnt - 1;
end

// ---------------------------------------------------------------------------
// beat_pos register — 0..3, cycles per qword
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        beat_pos <= 2'd0;
    else if (state == S_IDLE && scan_rd && !init)
        beat_pos <= 2'd0;
    else if (state == S_READ && jt_dok)
        beat_pos <= beat_pos + 1;
end

// ---------------------------------------------------------------------------
// asm_reg — shift in each 16-bit word little-endian
// On beat_pos=0 load dout into [15:0]; on 1 into [31:16]; etc.
// We use a right-shift: new word goes into the MSB slot, then shift down.
// Actually: little-endian pack means beat 0 → [15:0], beat 1 → [31:16], ...
// Easiest: shift right — each new word goes into top [63:48] and shifts down.
// After 4 beats the sequence [w3,w2,w1,w0] is in asm_reg as {w3,w2,w1,w0}
// but with w0 ending at [15:0].
//
// Alternatively: build from bottom up using beat_pos as shift amount.
// Use beat_pos to mux into the right 16-bit slot:
//   asm_reg[beat_pos*16 +: 16] <= jt_dout
// But multiple-driver rule says one always block per reg — so we must do it
// via the single always block here.  Use a case on beat_pos:
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        asm_reg <= 64'd0;
    else if (state == S_READ && jt_dok) begin
        case (beat_pos)
            2'd0: asm_reg <= {asm_reg[63:16], jt_dout};        // word→[15:0]
            2'd1: asm_reg <= {asm_reg[63:32], jt_dout, asm_reg[15:0]};  // word→[31:16]
            2'd2: asm_reg <= {asm_reg[63:48], jt_dout, asm_reg[31:0]};  // word→[47:32]
            2'd3: asm_reg <= {jt_dout, asm_reg[47:0]};         // word→[63:48]
        endcase
    end
end

// ---------------------------------------------------------------------------
// scan_dout64 register — latch assembled qword when beat_pos reaches 3
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        scan_dout64 <= 64'd0;
    else if (state == S_READ && jt_dok && beat_pos == 2'd3)
        // On the 4th beat, compute the final value including beat 3:
        scan_dout64 <= {jt_dout, asm_reg[47:0]};
end

// ---------------------------------------------------------------------------
// scan_dready register — one-cycle pulse per assembled qword
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        scan_dready <= 1'b0;
    else
        scan_dready <= (state == S_READ && jt_dok && beat_pos == 2'd3);
end

// ---------------------------------------------------------------------------
// jt_rd register — assert when starting a read, drop after last word captured
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        jt_rd <= 1'b0;
    else begin
        case (state)
            S_IDLE: begin
                if (scan_rd && !init)
                    jt_rd <= 1'b1;
            end
            S_START: begin
                // hold rd while waiting for ack
            end
            S_READ: begin
                // Drop rd after the last word counter decrements to 1
                // (i.e., when we're about to receive the last word)
                if (jt_dok && word_cnt == 10'd1)
                    jt_rd <= 1'b0;
            end
            default: jt_rd <= 1'b0;
        endcase
    end
end

// ---------------------------------------------------------------------------
// jt_addr register — latch the scan word address on IDLE→START
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        jt_addr <= {AW{1'b0}};
    else if (state == S_IDLE && scan_rd && !init)
        jt_addr <= scan_addr[AW:1];
end

// ---------------------------------------------------------------------------
// jt_ba register — latch the scan bank on IDLE→START
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        jt_ba <= 2'd0;
    else if (state == S_IDLE && scan_rd && !init)
        jt_ba <= scan_addr[26:25];
end

endmodule
