// sdram_burst_arb.sv — multi-client arbiter over jtframe_burst_sdram.
//
// Task 4: 3-client priority arbitration (scan > dst > src, scan-never-starve).
//   Adds the P_SRC (p0_*) read-only client port and full per-burst arbitration.
//   A grant is issued only from S_IDLE; the granted client holds the bus for the
//   full burst (atomic — no mid-burst preemption).  Scan always wins the next
//   grant boundary, so scan is never starved.
//
// Tasks 2 + 3 paths (scan read, dst write + read) retained unchanged.
//
// Address mapping (AW=23, 16-bit words, 2-bit bank):
//   ba   = client_addr[26:25]
//   addr = client_addr[23:1]   (23-bit word address; bit[0] is byte select,
//          ignored for 16-bit words).
//
// WRITE TIMING CONTRACT — derived from jtframe_burst_ctrl + jtframe_burst_io:
//
//   jtframe_burst_io uses a two-stage register pipeline for SDRAM outputs:
//     Stage-1 (posedge): captures burst_dq_out = din   → next_dq_r
//     Stage-2 (posedge): drives  SDRAM DQ = next_dq_r
//   So data takes 2 posedges from when din changes to when it lands on SDRAM.
//   Commands (burst_cmd) go through the same two stages, maintaining relative
//   alignment between CMD_WRITE and data.
//
//   Key posedges (consumer sees jt_ack=1 at posedge P):
//     P−2: ctrl B_WACK   (burst_ack combinational; Stage-1 registers at P−1,
//                          Stage-2 outputs jt_ack at P)
//     P−1: ctrl B_WDATA  (NOP; dq_oe=0 — data irrelevant)
//     P  : ctrl B_WRITE_CMD (CMD_WRITE issued; Stage-1 at P+1 captures din/oe)
//     P+1: ctrl B_WRITE   (Stage-2 at P+2 sends CMD_WRITE+word[0] to SDRAM)
//     P+2: ctrl B_WRITE   (Stage-2 at P+3 sends word[1] to SDRAM)
//     ...
//
//   Timing for jt_din:
//     Stage-1 captures din at posedge P+1 (B_WRITE_CMD interval).
//     At P+1 evaluation, wr_beat register holds its PRE-P+1 value (0 since
//     wr_beat only increments in S_WR_DATA, and state is S_WR_DATA starting
//     from posedge P's NBA — first S_WR_DATA increment fires at P+1).
//
//     So at P+1 eval: wr_beat=0 → jt_din=word[0].  Stage-1 captures word[0].
//     At P+2 eval: wr_beat=1 (set at P+1) → jt_din=word[1].  Stage-1 → word[1].
//     ...
//
//   jt_din is a WIRE (combinational mux from wr_beat + wr_qword): no
//   extra pipeline stage relative to ack.  A registered jt_din would shift
//   word[0] one cycle late, causing jtframe to capture it twice — the known
//   prior-scaffold bug.
//
//   jt_wr drops on the cycle where wr_word_cnt==1 at eval (i.e., when the
//   last word is presented to Stage-1 with dq_oe=1 still high, since the
//   register update takes effect AFTER the posedge evaluation by all blocks).
//   Ctrl sees wr=0 one posedge later → B_STOP.
//
// QWORD ADVANCE PROTOCOL (dst client → arbiter):
//   dst_wr_accept fires when wr_beat==1 in S_WR_DATA AND wr_word_cnt > 4.
//   The client must have the next qword on dst_din64 by the following negedge.
//   The arbiter latches wr_qword at wr_beat==3 (two cycles after accept),
//   which is always after the client's update.
//   Condition wr_word_cnt > 4 suppresses accept on the last qword's beat-1
//   (where wr_word_cnt ≤ 4).
//
// 16→64 read assembly: every 4 consecutive dok beats are packed little-endian
// into dout64: first word → [15:0], second → [31:16], ..., fourth → [63:48].
// scan_dready / dst_dready / p0_dready pulse for one cycle per assembled qword.
//
// GRANT / CLIENT LATCH:
//   At S_IDLE, on each cycle the arbiter selects the highest-priority asserted
//   request: scan > dst_write > dst_read > p0_read.  The selection is stored
//   in `grant` and held for the full burst (all states until return to S_IDLE).
//   All read assembler outputs (dout64/dready) are steered to the granted client.
//
// Refresh: internal counter fires rfsh every 640 clk cycles (~6.4 µs @ 100 MHz).
//
// Quartus constraint: one always-block per reg (Error 10028).
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

    // ---- P_DST client -------------------------------------------------------
    input  wire [26:0] dst_addr,     // byte address (little-endian)
    input  wire        dst_rd,       // assert to start a burst read (RMW read-back)
    input  wire [ 7:0] dst_burst,    // qwords for dst read burst
    input  wire        dst_we_burst, // assert to start a multi-qword write burst
    input  wire [ 7:0] dst_we_qcnt, // number of 64-bit qwords to write
    input  wire [63:0] dst_din64,    // write data (one qword per accept strobe)
    output wire        dst_busy,     // high while a dst transaction is in flight
    output reg  [63:0] dst_dout64,   // assembled 64-bit output (valid when dst_dready)
    output reg         dst_dready,   // one-cycle strobe per assembled qword
    output reg         dst_wr_accept,// one-cycle pulse: client must present next dst_din64

    // ---- P_SRC client (p0_*) ------------------------------------------------
    // Read-only compositor source path.  Staging-write ports accepted for
    // interface compatibility with Solarus.sv but not exercised internally.
    input  wire [26:0] p0_addr,      // byte address
    input  wire        p0_rd,        // assert to start a read burst
    input  wire [ 7:0] p0_burst,     // number of 64-bit qwords to fetch
    // staging-write ports (interface compatibility only — ignored internally)
    input  wire        p0_we,
    input  wire [15:0] p0_din,
    input  wire [26:0] p0_waddr,
    input  wire        p0_we_burst,
    input  wire [63:0] p0_din64,
    output wire        p0_busy,      // high while a p0 transaction is in flight
    output reg  [63:0] p0_dout64,   // assembled 64-bit output (valid when p0_dready)
    output reg         p0_dready,   // one-cycle strobe per assembled qword

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
reg            jt_wr;     // Task 3: write-burst control

// jt_din is COMBINATIONAL — no extra register stage relative to jt_ack.
// Selects the current 16-bit word from the 64-bit write qword buffer.
// wr_beat indexes [0..3]; each maps to a 16-bit lane in wr_qword.
// At posedge P+1 (B_WRITE_CMD interval, Stage-1 capture), wr_beat=0 (the
// pre-P+1 value, since wr_beat only increments in S_WR_DATA starting at P+1).
reg  [63:0]   wr_qword;   // latched copy of dst_din64 for current burst qword
reg  [ 1:0]   wr_beat;    // 0..3 — which 16-bit lane is currently presented

wire [15:0]   jt_din;

// Combinational mux: present the correct 16-bit word based on wr_beat
assign jt_din = (wr_beat == 2'd0) ? wr_qword[15: 0] :
                (wr_beat == 2'd1) ? wr_qword[31:16] :
                (wr_beat == 2'd2) ? wr_qword[47:32] :
                                    wr_qword[63:48] ;

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
    S_IDLE      = 3'd0,   // waiting for a request
    S_WR_DRAIN  = 3'd1,   // post-write drain: let jtframe finish teardown before next op
    S_START     = 3'd2,   // scan read: latch params, assert rd, wait for ack
    S_READ      = 3'd3,   // scan/p0 read: count dok beats, assemble qwords
    S_WR_START  = 3'd4,   // dst write: assert wr, wait for ack
    S_WR_DATA   = 3'd5,   // dst write: deliver 16-bit words to jtframe
    S_DST_START = 3'd6,   // dst read: latch params, assert rd, wait for ack
    S_DST_READ  = 3'd7;   // dst read: count dok beats, assemble qwords

reg [2:0] state;

// Post-write drain: jtframe sets post_write_read_wait at the end of every write
// (jtframe_burst_ctrl B_TRP1) and only returns to its idle/B_IDLE after a
// teardown (B_STOP→TWR→PRE→TRP1). If the next read is issued before that
// completes, jtframe's first read beat is mis-aligned (dok lags the CAS data by
// one cycle → the first qword is dropped/shifted). jtframe's own burst tests
// leave a post-write gap (repeat(4) @posedge) for this reason. We enforce it in
// hardware so back-to-back contention is correct regardless of client timing.
localparam [3:0] WR_DRAIN_CYCLES = 4'd8;
reg [3:0] wr_drain;

// ---------------------------------------------------------------------------
// Grant register — latches which client won the current burst.
// Encoding:
//   2'd0 = scan  (P_SCAN read)
//   2'd1 = dst_w (P_DST write)
//   2'd2 = dst_r (P_DST read)
//   2'd3 = p0    (P_SRC read)
// ---------------------------------------------------------------------------
localparam [1:0]
    G_SCAN  = 2'd0,
    G_DSTW  = 2'd1,
    G_DSTR  = 2'd2,
    G_P0    = 2'd3;

reg [1:0] grant;

// ---------------------------------------------------------------------------
// Read path shared counters (used by scan, dst, and p0 reads)
// ---------------------------------------------------------------------------
// Word counter: tracks remaining 16-bit words (initialised to burst*4)
reg [ 9:0]   word_cnt;    // up to 256 qwords * 4 = 1024 words

// Beat assembler: beat_pos = 0..3 (position within current read qword)
reg [ 1:0]   beat_pos;    // 0-3

// 64-bit assembler shift register
reg [63:0]   asm_reg;

// ---------------------------------------------------------------------------
// Read-data capture strobe (rd_dv) — DOK-GATED.
//
// jt_dok is jtframe's per-beat data-valid strobe and is the right gate (it
// tracks jtframe's burst timing per beat). rd_dv adds the "words still to take"
// guard so capture stops after word_cnt beats.
//
// SKEW EXCEPTION: the FIRST read after a write (post_write_read_wait → extra
// B_CL2 in jtframe_burst_ctrl) emits dok one cycle LATE relative to the returned
// data, so each dok beat's data is on dout the PREVIOUS cycle (dout_q). This is
// independent of bank/row (jtframe precharges + re-activates every burst). All
// other reads (no preceding write) capture jt_dout directly. See rd_skew below.
// ---------------------------------------------------------------------------
wire rd_dv = (state == S_READ || state == S_DST_READ) && jt_dok && (word_cnt != 10'd0);

// --- post-write read skew detection ---------------------------------------
// jtframe sets post_write_read_wait after every write and consumes it via an
// extra B_CL2 on the next read. EMPIRICALLY (per-case data traces, not just the
// post_write_read_wait flag):
//   - a post-write read of the EXACT (bank,word) address just written reads back
//     ALIGNED (write-data forwarding / RMW): capturing jt_dout is correct;
//     capturing dout_q corrupts it.
//   - ANY OTHER post-write read (different word — same row/diff column, diff row,
//     or diff bank) is skewed: jtframe's dok lags the (contiguous) returned data
//     by one cycle, so each beat's data is on dout the PREVIOUS cycle (dout_q).
// So rd_skew = post_wr AND the read's (bank,word) differs from the last write's.
// Word = byte_addr[AW:1] (AW=23). NOTE the {ba,24'hOFF,1'b0} address convention
// puts OFF in bits[24:1], so byte_addr = OFF<<1, word = OFF (low 23 bits).
reg  [1:0]      lw_ba;    // last-write bank
reg  [AW-1:0]   lw_word;  // last-write word address
reg             post_wr;  // 1 => next granted read is jtframe-post-write
reg             rd_skew;  // latched per read

wire rd_grant = (state == S_IDLE) && !init &&
                (scan_rd || (!dst_we_burst && dst_rd) ||
                 (!dst_we_burst && !dst_rd && p0_rd));
wire [1:0]      rd_ba   = scan_rd                   ? scan_addr[26:25] :
                          (!dst_we_burst && dst_rd) ? dst_addr [26:25] : p0_addr[26:25];
wire [AW-1:0]   rd_word = scan_rd                   ? scan_addr[AW:1] :
                          (!dst_we_burst && dst_rd) ? dst_addr [AW:1] : p0_addr[AW:1];

always @(posedge clk or posedge rst) begin           // last-write bank/word
    if (rst) begin lw_ba <= 2'd0; lw_word <= {AW{1'b0}}; end
    else if (state == S_IDLE && !init && !scan_rd && dst_we_burst) begin
        lw_ba   <= dst_addr[26:25];
        lw_word <= dst_addr[AW:1];
    end
end
always @(posedge clk or posedge rst) begin           // post-write pending
    if (rst) post_wr <= 1'b0;
    else if (state == S_WR_DRAIN && wr_drain == 4'd0) post_wr <= 1'b1;
    else if (rd_grant)                                post_wr <= 1'b0;
end
always @(posedge clk or posedge rst) begin           // skew latch per read
    if (rst) rd_skew <= 1'b0;
    else if (rd_grant)
        rd_skew <= post_wr && ((rd_ba != lw_ba) || (rd_word != lw_word));
end

// 1-cycle-delayed read data, used for the post-write read skew case.
reg [15:0] dout_q;
always @(posedge clk or posedge rst) begin
    if (rst) dout_q <= 16'd0;
    else     dout_q <= jt_dout;
end
wire [15:0] rd_data = rd_skew ? dout_q : jt_dout;

// ---------------------------------------------------------------------------
// Write path counters
// ---------------------------------------------------------------------------
reg [ 9:0]   wr_word_cnt;  // remaining 16-bit words to deliver (N_qwords*4)

// ---------------------------------------------------------------------------
// Busy / status outputs
// ---------------------------------------------------------------------------
assign scan_busy = (state == S_START) || (state == S_READ  && grant == G_SCAN);
assign dst_busy  = (state == S_WR_START) || (state == S_WR_DATA) ||
                   (state == S_WR_DRAIN) ||
                   (state == S_DST_START) || (state == S_DST_READ);
assign p0_busy   = (state == S_START  && grant == G_P0) ||
                   (state == S_READ   && grant == G_P0);

// ---------------------------------------------------------------------------
// wr_drain counter — loaded on the S_WR_DATA→S_WR_DRAIN transition, counts down
// to 0 in S_WR_DRAIN so jtframe completes its write teardown before the next op.
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        wr_drain <= 4'd0;
    else if (state == S_WR_DATA && !jt_wr && jt_rdy)
        wr_drain <= WR_DRAIN_CYCLES;
    else if (state == S_WR_DRAIN && wr_drain != 4'd0)
        wr_drain <= wr_drain - 4'd1;
end

// ---------------------------------------------------------------------------
// Grant register — latched at S_IDLE when a request is accepted.
// Priority: scan > dst_write > dst_read > p0
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        grant <= G_SCAN;
    else if (state == S_IDLE && !init) begin
        if (scan_rd)
            grant <= G_SCAN;
        else if (dst_we_burst)
            grant <= G_DSTW;
        else if (dst_rd)
            grant <= G_DSTR;
        else if (p0_rd)
            grant <= G_P0;
    end
end

// ---------------------------------------------------------------------------
// State register
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        state <= S_IDLE;
    else begin
        case (state)
            S_IDLE: begin
                if (!init) begin
                    if (scan_rd)
                        state <= S_START;
                    else if (dst_we_burst)
                        state <= S_WR_START;
                    else if (dst_rd)
                        state <= S_DST_START;
                    else if (p0_rd)
                        state <= S_START;    // p0 read reuses scan read path
                end
            end

            // ---- scan / p0 read path (shared S_START→S_READ) ----
            S_START: begin
                if (jt_ack)
                    state <= S_READ;
            end
            S_READ: begin
                if (!jt_rd && jt_rdy)
                    state <= S_IDLE;
            end

            // ---- dst write path ----
            S_WR_START: begin
                if (jt_ack)
                    state <= S_WR_DATA;
            end
            S_WR_DATA: begin
                // Remain until jt_wr has been dropped and jtframe signals rdy,
                // then DRAIN before allowing the next op (jtframe write teardown).
                if (!jt_wr && jt_rdy)
                    state <= S_WR_DRAIN;
            end
            S_WR_DRAIN: begin
                if (wr_drain == 4'd0)
                    state <= S_IDLE;
            end

            // ---- dst read path ----
            S_DST_START: begin
                if (jt_ack)
                    state <= S_DST_READ;
            end
            S_DST_READ: begin
                if (!jt_rd && jt_rdy)
                    state <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

// ---------------------------------------------------------------------------
// jt_rd register — controlled by the granted client in S_IDLE.
// Only asserts rd when the granted client is a READ client (scan, dst_rd, p0).
// Priority order mirrors the state FSM: scan > dst_write > dst_read > p0.
// jt_rd must NOT fire when dst_we_burst wins the grant (even if p0_rd is
// also asserted), since that would issue a conflicting READ command.
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        jt_rd <= 1'b0;
    else begin
        case (state)
            S_IDLE: begin
                if (!init) begin
                    if (scan_rd)
                        jt_rd <= 1'b1;                    // scan wins → read
                    else if (dst_we_burst)
                        jt_rd <= 1'b0;                    // dst write wins → no read
                    else if (dst_rd)
                        jt_rd <= 1'b1;                    // dst read wins → read
                    else if (p0_rd)
                        jt_rd <= 1'b1;                    // p0 wins → read
                end
            end
            S_START: begin
                // hold rd while waiting for ack (scan or p0 read)
            end
            S_READ: begin
                // Drop rd after the last word counter decrements to 1
                if (rd_dv && word_cnt == 10'd1)
                    jt_rd <= 1'b0;
            end
            S_WR_START: begin
                jt_rd <= 1'b0;                            // write in progress
            end
            S_DST_START: begin
                // hold rd while waiting for ack (dst read)
            end
            S_DST_READ: begin
                if (rd_dv && word_cnt == 10'd1)
                    jt_rd <= 1'b0;
            end
            default: jt_rd <= 1'b0;
        endcase
    end
end

// ---------------------------------------------------------------------------
// jt_wr register — controlled by dst write path.
//
// Dropped when wr_word_cnt == 1 at eval (in S_WR_DATA).  At that posedge:
//   - Stage-1 evaluates burst_dq_oe = wr = 1 (pre-update value) → captures
//     the last word with OE high.
//   - After NBA: jt_wr = 0.
//   - Next posedge: ctrl FSM sees wr=0 → transitions B_WRITE → B_STOP.
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        jt_wr <= 1'b0;
    else begin
        case (state)
            S_IDLE: begin
                if (!init && !scan_rd && dst_we_burst)
                    jt_wr <= 1'b1;
            end
            S_WR_START: begin
                // hold wr while waiting for ack
            end
            S_WR_DATA: begin
                if (wr_word_cnt == 10'd1)
                    jt_wr <= 1'b0;
            end
            default: jt_wr <= 1'b0;
        endcase
    end
end

// ---------------------------------------------------------------------------
// jt_addr register — latch the address on IDLE→request transition
// Priority matches grant: scan > dst_write > dst_read > p0
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        jt_addr <= {AW{1'b0}};
    else if (state == S_IDLE && !init) begin
        if (scan_rd)
            jt_addr <= scan_addr[AW:1];
        else if (dst_we_burst)
            jt_addr <= dst_addr[AW:1];
        else if (dst_rd)
            jt_addr <= dst_addr[AW:1];
        else if (p0_rd)
            jt_addr <= p0_addr[AW:1];
    end
end

// ---------------------------------------------------------------------------
// jt_ba register — latch the bank on IDLE→request transition
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        jt_ba <= 2'd0;
    else if (state == S_IDLE && !init) begin
        if (scan_rd)
            jt_ba <= scan_addr[26:25];
        else if (dst_we_burst)
            jt_ba <= dst_addr[26:25];
        else if (dst_rd)
            jt_ba <= dst_addr[26:25];
        else if (p0_rd)
            jt_ba <= p0_addr[26:25];
    end
end

// ---------------------------------------------------------------------------
// wr_qword register — latched copy of dst_din64 for write burst.
//
// Initial latch: on the S_IDLE posedge where dst_we_burst is first seen;
// this is the same posedge that transitions the state to S_WR_START.
//
// Reload: on the posedge where wr_beat==3 (the last beat of the current
// qword, checked against the PRE-posedge register value) AND wr_word_cnt > 3
// (meaning at least 4 more words remain = at least one more complete qword).
// At this point dst_din64 must already hold the next qword: the client was
// given dst_wr_accept two cycles earlier (at wr_beat==1) and had until the
// following negedge to update dst_din64.
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        wr_qword <= 64'd0;
    else if (state == S_IDLE && !init && !scan_rd && dst_we_burst)
        wr_qword <= dst_din64;
    else if (state == S_WR_DATA && wr_beat == 2'd3 && wr_word_cnt > 10'd3)
        wr_qword <= dst_din64;
end

// ---------------------------------------------------------------------------
// wr_beat register — 0..3, tracks which 16-bit lane we're presenting.
//
// Critical timing: wr_beat increments only in S_WR_DATA.  The state register
// becomes S_WR_DATA at posedge P (the ack cycle), so the FIRST increment
// fires at posedge P+1 (which is the first posedge in S_WR_DATA state at
// eval time).  Therefore:
//
//   At P+1 eval: wr_beat = 0 (pre-P+1 value, set at P's NBA = 0, unchanged).
//                Stage-1 captures jt_din = word[0] at P+1.  ✓
//   At P+2 eval: wr_beat = 1 (incremented at P+1).
//                Stage-1 captures word[1] at P+2.  ✓
//   ...
//
// This avoids the prior-scaffold "captures word[0] twice" bug: if wr_beat
// were incremented earlier (at the ack posedge via wr_active), Stage-1 at
// P+1 would see wr_beat=1 and capture word[1] first, losing word[0].
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        wr_beat <= 2'd0;
    else if (state == S_IDLE && !init && !scan_rd && dst_we_burst)
        wr_beat <= 2'd0;
    else if (state == S_WR_DATA)
        wr_beat <= wr_beat + 2'd1;
end

// ---------------------------------------------------------------------------
// wr_word_cnt register — remaining 16-bit words to deliver.
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        wr_word_cnt <= 10'd0;
    else if (state == S_IDLE && !init && !scan_rd && dst_we_burst)
        wr_word_cnt <= {dst_we_qcnt, 2'b00};   // N_qwords * 4
    else if (state == S_WR_DATA && wr_word_cnt != 10'd0)
        wr_word_cnt <= wr_word_cnt - 10'd1;
end

// ---------------------------------------------------------------------------
// dst_wr_accept — one-cycle strobe: client must advance dst_din64.
//
// Timing chain for N=2 qwords, ack at posedge P:
//   State S_WR_DATA starts at P (NBA).  First S_WR_DATA eval at P+1.
//   P+2: wr_beat eval = 1 (set at P+1) → condition true → NBA at P+2
//   P+3: dst_wr_accept visible = 1.  Testbench @(negedge P+3.5): dst_din64=Q1.
//   P+4: wr_beat eval = 3.  wr_word_cnt = 5 > 3.  wr_qword latches Q1.  ✓
//
// Accept at wr_beat==1 gives two cycles of margin (negedge to next posedge)
// before the qword latch at wr_beat==3.
//
// wr_word_cnt > 4: suppresses accept on the last qword's beat-1 where
// wr_word_cnt ≤ 4 (only 4 words remain in the last qword, no successor).
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        dst_wr_accept <= 1'b0;
    else
        dst_wr_accept <= (state == S_WR_DATA) && (wr_beat == 2'd1) && (wr_word_cnt > 10'd4);
end

// ---------------------------------------------------------------------------
// word_cnt register — tracks remaining 16-bit words to receive (reads)
// Handles scan, dst_rd, and p0_rd.
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        word_cnt <= 10'd0;
    else if (state == S_IDLE && !init) begin
        if (scan_rd)
            word_cnt <= {scan_burst, 2'b00};    // scan_burst * 4
        else if (dst_we_burst)
            word_cnt <= 10'd0;                  // write path doesn't use word_cnt
        else if (dst_rd)
            word_cnt <= {dst_burst, 2'b00};     // dst_burst * 4
        else if (p0_rd)
            word_cnt <= {p0_burst, 2'b00};      // p0_burst * 4 words
    end
    else if (rd_dv)
        word_cnt <= word_cnt - 1;
end

// ---------------------------------------------------------------------------
// beat_pos register — 0..3, cycles per read qword
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        beat_pos <= 2'd0;
    else if (state == S_IDLE && !init) begin
        if (scan_rd || (!dst_we_burst && !dst_rd && p0_rd))
            beat_pos <= 2'd0;
        else if (!dst_we_burst && dst_rd)
            beat_pos <= 2'd0;
    end
    else if (rd_dv)
        beat_pos <= beat_pos + 1;
end

// ---------------------------------------------------------------------------
// asm_reg — shift in each 16-bit word little-endian (shared scan + dst + p0)
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        asm_reg <= 64'd0;
    else if (rd_dv) begin
        case (beat_pos)
            2'd0: asm_reg <= {asm_reg[63:16], rd_data};
            2'd1: asm_reg <= {asm_reg[63:32], rd_data, asm_reg[15:0]};
            2'd2: asm_reg <= {asm_reg[63:48], rd_data, asm_reg[31:0]};
            2'd3: asm_reg <= {rd_data, asm_reg[47:0]};
        endcase
    end
end

// ---------------------------------------------------------------------------
// scan_dout64 register — latch assembled qword when beat_pos reaches 3 (scan)
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        scan_dout64 <= 64'd0;
    else if (state == S_READ && grant == G_SCAN && rd_dv && beat_pos == 2'd3)
        scan_dout64 <= {rd_data, asm_reg[47:0]};
end

// ---------------------------------------------------------------------------
// scan_dready register — one-cycle pulse per assembled scan qword
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        scan_dready <= 1'b0;
    else
        scan_dready <= (state == S_READ && grant == G_SCAN && rd_dv && beat_pos == 2'd3);
end

// ---------------------------------------------------------------------------
// dst_dout64 register — latch assembled qword when beat_pos reaches 3 (dst)
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        dst_dout64 <= 64'd0;
    else if (state == S_DST_READ && rd_dv && beat_pos == 2'd3)
        dst_dout64 <= {rd_data, asm_reg[47:0]};
end

// ---------------------------------------------------------------------------
// dst_dready register — one-cycle pulse per assembled dst qword
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        dst_dready <= 1'b0;
    else
        dst_dready <= (state == S_DST_READ && rd_dv && beat_pos == 2'd3);
end

// ---------------------------------------------------------------------------
// p0_dout64 register — latch assembled qword when beat_pos reaches 3 (p0)
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        p0_dout64 <= 64'd0;
    else if (state == S_READ && grant == G_P0 && rd_dv && beat_pos == 2'd3)
        p0_dout64 <= {rd_data, asm_reg[47:0]};
end

// ---------------------------------------------------------------------------
// p0_dready register — one-cycle pulse per assembled p0 qword
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        p0_dready <= 1'b0;
    else
        p0_dready <= (state == S_READ && grant == G_P0 && rd_dv && beat_pos == 2'd3);
end

endmodule
