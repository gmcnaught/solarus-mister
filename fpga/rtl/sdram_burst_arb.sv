// sdram_burst_arb.sv — multi-client arbiter over jtframe_burst_sdram.
//
// JT-T5b: AUTOPRECH uniform-timing read capture.
//   The arb drives jtframe_burst_sdram through its prog_* path with prog_en
//   held high.  That path uses the jtframe_sdram64_bank instance configured
//   AUTOPRECH=1 / PRECHARGE_ALL=1, so EVERY access is a uniform cold page-miss:
//   precharge-all → activate → read/write → auto-precharge.  Read-data timing is
//   therefore CONSTANT for all access patterns (post-write, same/diff row,
//   diff bank, back-to-back), which lets a SINGLE fixed capture rule replace the
//   variable-offset prediction that the burst path (jtframe_burst_ctrl) required.
//
//   prog-mode SDRAM config (set by jtframe_burst_mode for PROG_LEN=64):
//     - read burst length 4 (one 64-bit qword per CMD_READ), CAS latency 2
//     - write burst mode = SINGLE location (one column per CMD_WRITE)
//   So:
//     - READS  issue one cold BL=4 read command per 16-bit word and capture ONLY
//       beat 0 (the addressed column), advancing the word address by 1.  The
//       trailing burst beats are unusable: BL=4 SEQUENTIAL bursts wrap within the
//       4-word-aligned block, and auto-precharge releases the DQ bus before the
//       controller clock can sample the last beat.  Beat 0 is the only beat that
//       is both correctly addressed and reliably sampled (see the capture block).
//     - WRITES issue one single-location write per 16-bit word (data held
//       constant for the whole command → open-loop timing safe, exactly the
//       proven jtframe_dwnld pattern), advancing the word address by 1 per word.
//
// Address mapping (AW=23, 16-bit words, 2-bit bank):
//   ba   = client_addr[26:25]
//   addr = client_addr[AW:1]   (23-bit linear word address; bit[0] byte select).
//   The prog path's prog_bank_addr remap exactly cancels the bank's row/col
//   split, so prog_addr == linear word address hits the same physical cell as
//   the tb's Bank[word_addr] preload (verified by Tests 1/2).
//
// 16→64 read assembly: every 4 consecutive captured words are packed
// little-endian into dout64: first word → [15:0], ..., fourth → [63:48].
// scan_dready / dst_dready / p0_dready pulse for one cycle per assembled qword.
//
// GRANT / CLIENT LATCH:
//   At S_IDLE the arbiter selects the highest-priority asserted request:
//   scan > dst_write > dst_read > p0_read.  The selection is stored in `grant`
//   and held for the full burst (all states until return to S_IDLE).  All read
//   assembler outputs (dout64/dready) are steered to the granted client.
//   Scan always wins the next grant boundary, so scan is never starved.
//
// Refresh: internal counter fires rfsh every RFSH_PERIOD clk cycles.
//   jtframe defers the refresh to the next burst gap, so rfsh never corrupts a
//   live burst.
//
// Quartus constraint: one always-block per reg (Error 10028).
`default_nettype none

module sdram_burst_arb #(
    parameter integer AW          = 23,
    parameter integer HF          = 1,
    parameter integer MISTER      = 0,
    parameter integer PROG_LEN    = 64,
    // Refresh interval in clk cycles. Default 640 (~6.4 µs @ 100 MHz, well under
    // the 7.8 µs row-refresh deadline). Overridable so sims can shorten it to
    // exercise many refresh intervals in bounded time.
    parameter integer RFSH_PERIOD = 640
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
    // Single-16-bit-word write (vram_demux partial/sub-qword lane writes). Each
    // dst_we pulse writes one 16-bit word (dst_din) at dst_addr as one prog
    // single-location write — the same per-word write the burst path uses.
    input  wire        dst_we,       // assert to write one 16-bit word (dst_din)
    input  wire [15:0] dst_din,      // single-word write data
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
// Refresh counter — pulse rfsh every RFSH_PERIOD cycles (default 640 ~6.4 µs
// @ 100 MHz). jtframe_burst_sdram defers the refresh to the next burst gap, so
// rfsh never corrupts a live burst.
// ---------------------------------------------------------------------------
reg [$clog2(RFSH_PERIOD)-1:0] hcnt;
wire rfsh = (hcnt == 0);

always @(posedge clk or posedge rst) begin
    if (rst)
        hcnt <= 0;
    else
        hcnt <= (hcnt == (RFSH_PERIOD - 1)) ? 0 : hcnt + 1;
end

// ---------------------------------------------------------------------------
// jtframe_burst_sdram consumer signals (prog_* path)
// ---------------------------------------------------------------------------
reg  [AW-1:0] jt_addr;   // linear word address (prog_addr)
reg  [ 1:0]   jt_ba;     // bank (prog_ba — drives the bank select directly)
reg            jt_rd;    // prog_rd  — read request (per qword)
reg            jt_wr;    // prog_wr  — write request (per single word)

// jt_din is COMBINATIONAL: the current 16-bit write word selected from the
// latched qword buffer by wr_beat.  Held stable for the whole single-location
// write command (the bank is in SINGLE write-burst mode), so there is no
// data/strobe alignment hazard — exactly the jtframe_dwnld pattern.
reg  [63:0]   wr_qword;   // latched copy of dst_din64 for current burst qword
reg  [ 1:0]   wr_beat;    // 0..3 — which 16-bit lane is currently presented

wire [15:0]   jt_din;
assign jt_din = (wr_beat == 2'd0) ? wr_qword[15: 0] :
                (wr_beat == 2'd1) ? wr_qword[31:16] :
                (wr_beat == 2'd2) ? wr_qword[47:32] :
                                    wr_qword[63:48] ;

wire [15:0]   jt_dout;   // shared read-data port (1 IO stage)
wire           jt_ack;   // prog_ack — read/write command issued (st[READ]+2)
wire           jt_dst;   // prog_dst — first read-data beat
wire           jt_dok;   // prog_dok — read data valid window (4 beats)
wire           jt_rdy;   // prog_rdy — command complete

// ---------------------------------------------------------------------------
// jtframe_burst_sdram instance — prog_* path (AUTOPRECH uniform timing).
//   The burst-path inputs (addr/ba/rd/wr/din) are tied off; the burst-path
//   strobes (ack/dst/dok/rdy) are left unconnected.  Read data is taken from
//   the shared `dout` port; strobes from prog_dst/prog_dok/prog_rdy/prog_ack.
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

    // burst path — unused (tied off)
    .addr       ( {AW{1'b0}} ),
    .ba         ( 2'b00      ),
    .rd         ( 1'b0       ),
    .wr         ( 1'b0       ),
    .din        ( 16'h0000   ),
    .dout       ( jt_dout    ),   // shared read-data port
    .ack        (            ),
    .dst        (            ),
    .dok        (            ),
    .rdy        (            ),

    // prog path — the AUTOPRECH uniform-timing datapath
    .prog_en    ( 1'b1      ),
    .prog_addr  ( jt_addr   ),
    .prog_rd    ( jt_rd     ),
    .prog_wr    ( jt_wr     ),
    .prog_din   ( jt_din    ),
    .prog_dsn   ( 2'b00     ),   // DQM active-high: 00 = write both bytes
    .prog_ba    ( jt_ba     ),
    .prog_dst   ( jt_dst    ),
    .prog_dok   ( jt_dok    ),
    .prog_rdy   ( jt_rdy    ),
    .prog_ack   ( jt_ack    ),

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
localparam [3:0]
    S_IDLE    = 4'd0,   // waiting for a request
    S_RD_REQ  = 4'd1,   // read: assert prog_rd for one word, wait for ack
    S_RD_CAP  = 4'd2,   // read: capture the word's beat 0, then next word or done
    S_WR_REQ  = 4'd3,   // write: assert prog_wr for one word, wait for completion
    S_WR_NEXT = 4'd4,   // write: advance to the next word / finish
    S_RD_DONE = 4'd5,   // read: 1-cycle drain before S_IDLE (avoid same-cycle re-arm race)
    S_WR_DONE = 4'd6;   // write: drain before S_IDLE

reg [3:0] state;

// ---------------------------------------------------------------------------
// Inter-burst drain — at a grant boundary the next burst may target a DIFFERENT
// bank/direction than the one just finished.  The AUTOPRECH bank controller has
// a multi-cycle precharge/teardown pipeline; if the next read/write is launched
// before it returns to idle, its activate can race the previous access's
// teardown and a command can reach an un-activated bank (SDRAM model fatal).
// S_RD_DONE/S_WR_DONE hold rd=wr=0 (and a stable address) for DRAIN_CYCLES so the
// controller fully idles before S_IDLE latches the next grant.  (Intra-burst
// per-word accesses stay on one bank and need no drain — proven by Test 1.)
// ---------------------------------------------------------------------------
localparam [4:0] DRAIN_CYCLES = 5'd16;
reg [4:0] drain_cnt;
// (drain_cnt update block is below, after last_word/wr_word_cnt are declared.)

// ---------------------------------------------------------------------------
// Grant register — latches which client won the current burst.
//   2'd0 = scan, 2'd1 = dst_w, 2'd2 = dst_r, 2'd3 = p0
// ---------------------------------------------------------------------------
localparam [1:0]
    G_SCAN  = 2'd0,
    G_DSTW  = 2'd1,
    G_DSTR  = 2'd2,
    G_P0    = 2'd3;

reg [1:0] grant;

// A dst WRITE request is either a multi-qword burst or a single-16-bit-word write.
wire dst_wr_req = dst_we_burst | dst_we;
// Highest-priority request currently asserted at S_IDLE (scan>dstw>dstr>p0).
wire any_req = scan_rd | dst_wr_req | dst_rd | p0_rd;

// ---------------------------------------------------------------------------
// Read path counters
// ---------------------------------------------------------------------------
reg [ 9:0]   word_cnt;    // remaining 16-bit words for the whole read burst
reg [ 1:0]   beat_pos;    // 0..3 position within the current read qword
reg [63:0]   asm_reg;     // 64-bit assembler

// ---------------------------------------------------------------------------
// Read-data capture (rd_dv) — ONE cold read per 16-bit word, capturing only the
// FIRST burst beat (the addressed column) under uniform AUTOPRECH timing.
//
// Each cold access is a BL=4 read with auto-precharge.  Two SDRAM facts make the
// trailing beats unusable:
//   1. BL=4 SEQUENTIAL bursts WRAP within the 4-word-aligned block, so reading
//      column C returns {C, C|1..3 wrapped}, NOT C..C+3 linear.
//   2. Auto-precharge releases the DQ bus (tHZ) ~2 ns before the controller clock
//      — which lags the SDRAM clock — can sample the LAST (4th) beat, so it reads
//      back high-Z (proven from -DDEBUG_BURST_ARB raw-bus traces: dq=w0,w1,w2,Z).
// The ONLY beat that is both correctly addressed (no wrap) and reliably sampled
// is beat 0 — which is exactly the requested column.  So every read captures one
// word (its beat 0, anchored on jt_dst), then the word address advances by 1 and
// the next cold read issues.  ONE fixed rule, identical for every access pattern.
// ---------------------------------------------------------------------------
wire rd_dv = (state == S_RD_CAP) && jt_dst && (word_cnt != 10'd0);
wire [15:0] rd_data = jt_dout;

// last_word: the final word of the whole read burst was just captured.
wire last_word = rd_dv && (word_cnt == 10'd1);

// qword_done: the 4th word of a qword was just captured this cycle.
wire qword_done = rd_dv && (beat_pos == 2'd3);

// ---------------------------------------------------------------------------
// Write path counter
// ---------------------------------------------------------------------------
reg [ 9:0]   wr_word_cnt;  // remaining 16-bit words to write (N_qwords*4)

// Inter-burst drain counter update (declared earlier near the FSM states).
always @(posedge clk or posedge rst) begin
    if (rst)
        drain_cnt <= 5'd0;
    else if (state == S_RD_CAP && last_word)
        drain_cnt <= DRAIN_CYCLES;
    else if (state == S_WR_NEXT && wr_word_cnt == 10'd1)
        drain_cnt <= DRAIN_CYCLES;
    else if ((state == S_RD_DONE || state == S_WR_DONE) && drain_cnt != 5'd0)
        drain_cnt <= drain_cnt - 5'd1;
end

// ---------------------------------------------------------------------------
// Busy / status outputs
// ---------------------------------------------------------------------------
wire rd_grant_scan = (grant == G_SCAN);
wire rd_grant_dstr = (grant == G_DSTR);
wire rd_grant_p0   = (grant == G_P0);
wire in_read  = (state == S_RD_REQ) || (state == S_RD_CAP) || (state == S_RD_DONE);
wire in_write = (state == S_WR_REQ) || (state == S_WR_NEXT) || (state == S_WR_DONE);

assign scan_busy = in_read && rd_grant_scan;
assign dst_busy  = in_write || (in_read && rd_grant_dstr);
assign p0_busy   = in_read && rd_grant_p0;

// ---------------------------------------------------------------------------
// Grant register — latched at S_IDLE when a request is accepted.
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        grant <= G_SCAN;
    else if (state == S_IDLE && !init) begin
        if (scan_rd)            grant <= G_SCAN;
        else if (dst_wr_req)    grant <= G_DSTW;
        else if (dst_rd)        grant <= G_DSTR;
        else if (p0_rd)         grant <= G_P0;
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
                if (!init && any_req) begin
                    if (scan_rd)            state <= S_RD_REQ;
                    else if (dst_wr_req)    state <= S_WR_REQ;
                    else                    state <= S_RD_REQ; // dst_rd or p0_rd
                end
            end

            // ---- read: one cold read command per 16-bit word ----
            S_RD_REQ: begin
                // prog_rd is asserted; once the read command issues (jt_ack)
                // begin capturing.  prog_rd is dropped (see jt_rd block) so the
                // bank does not auto-launch the next read after auto-precharge.
                if (jt_ack)
                    state <= S_RD_CAP;
            end
            S_RD_CAP: begin
                if (last_word)
                    state <= S_RD_DONE;         // whole burst done — drain to idle
                else if (rd_dv)
                    state <= S_RD_REQ;          // next word read
            end
            S_RD_DONE: if (drain_cnt == 5'd0) state <= S_IDLE;  // controller idled

            // ---- write: one single-location write per 16-bit word ----
            S_WR_REQ: begin
                // prog_wr asserted with prog_din held; wait for completion.
                if (jt_rdy)
                    state <= S_WR_NEXT;
            end
            S_WR_NEXT: begin
                if (wr_word_cnt == 10'd1)
                    state <= S_WR_DONE;         // all words written — drain to idle
                else
                    state <= S_WR_REQ;         // next word
            end
            S_WR_DONE: if (drain_cnt == 5'd0) state <= S_IDLE;  // controller idled

            default: state <= S_IDLE;
        endcase
    end
end

// ---------------------------------------------------------------------------
// jt_rd register — read request, one 16-bit word per assertion.
//   Asserted on entering a read at S_IDLE and re-asserted for each subsequent
//   word (in S_RD_CAP when advancing).  Dropped once the read command issues
//   (jt_ack) so the AUTOPRECH bank does not re-read after auto-precharge.
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        jt_rd <= 1'b0;
    else begin
        case (state)
            S_IDLE: begin
                // Mirror the grant priority EXACTLY (scan > dst_write > dst_read
                // > p0): assert jt_rd iff the winning client is a read.  A bare
                // "!dst_wr_req" guard is wrong — scan outranks dst writes, so
                // scan_rd must drive jt_rd even when a dst write is also pending.
                if (!init) begin
                    if (scan_rd)            jt_rd <= 1'b1;   // scan read wins
                    else if (dst_wr_req)    jt_rd <= 1'b0;   // write wins
                    else if (dst_rd)        jt_rd <= 1'b1;   // dst read wins
                    else if (p0_rd)         jt_rd <= 1'b1;   // p0 read wins
                end
            end
            S_RD_REQ: begin
                if (jt_ack)
                    jt_rd <= 1'b0;          // command issued — stop requesting
            end
            S_RD_CAP: begin
                // Re-assert for the next word read once this word is captured.
                if (rd_dv && !last_word)
                    jt_rd <= 1'b1;
            end
            default: jt_rd <= 1'b0;
        endcase
    end
end

// ---------------------------------------------------------------------------
// jt_wr register — write request, one single-location write per word.
//   Asserted on entering a write at S_IDLE and re-asserted for each subsequent
//   word.  Dropped when the write completes (jt_rdy) so exactly one column is
//   written per command.
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        jt_wr <= 1'b0;
    else begin
        case (state)
            S_IDLE: begin
                if (!init && !scan_rd && dst_wr_req)
                    jt_wr <= 1'b1;
            end
            S_WR_REQ: begin
                // Drop jt_wr as soon as the write command issues (jt_ack).  The
                // single-location write data was held constant and is already
                // committed at the command, so dropping early is safe — and it
                // stops the AUTOPRECH controller from speculatively re-requesting
                // the bus and leaving a dangling activation on the write's bank
                // (which a following different-bank read would then misuse).
                if (jt_ack)
                    jt_wr <= 1'b0;
            end
            S_WR_NEXT: begin
                if (wr_word_cnt != 10'd1)
                    jt_wr <= 1'b1;          // next word
            end
            default: jt_wr <= 1'b0;
        endcase
    end
end

// ---------------------------------------------------------------------------
// jt_addr / jt_ba — latched at S_IDLE; addr advances per qword (read, +4) or
// per word (write, +1).
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        jt_addr <= {AW{1'b0}};
    else if (state == S_IDLE && !init) begin
        if (scan_rd)            jt_addr <= scan_addr[AW:1];
        else if (dst_wr_req)    jt_addr <= dst_addr[AW:1];
        else if (dst_rd)        jt_addr <= dst_addr[AW:1];
        else if (p0_rd)         jt_addr <= p0_addr[AW:1];
    end
    else if (state == S_RD_CAP && rd_dv && !last_word)
        jt_addr <= jt_addr + 1;        // next word
    else if (state == S_WR_NEXT && wr_word_cnt != 10'd1)
        jt_addr <= jt_addr + 1;        // next word
end

always @(posedge clk or posedge rst) begin
    if (rst)
        jt_ba <= 2'd0;
    else if (state == S_IDLE && !init) begin
        if (scan_rd)            jt_ba <= scan_addr[26:25];
        else if (dst_wr_req)    jt_ba <= dst_addr[26:25];
        else if (dst_rd)        jt_ba <= dst_addr[26:25];
        else if (p0_rd)         jt_ba <= p0_addr[26:25];
    end
end

// ---------------------------------------------------------------------------
// wr_qword register — latched copy of dst_din64 for the current write qword.
//   Initial latch on the S_IDLE acceptance posedge; reloaded with the next
//   qword when the last word (wr_beat==3) of the current qword completes and
//   more qwords remain.  Single-location writes are slow enough that the client
//   has ample time after dst_wr_accept to present the next qword.
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        wr_qword <= 64'd0;
    else if (state == S_IDLE && !init && !scan_rd && dst_wr_req)
        // burst write: latch the qword; single write: place the one word in lane 0
        wr_qword <= dst_we_burst ? dst_din64 : {48'd0, dst_din};
    else if (state == S_WR_NEXT && wr_beat == 2'd3 && wr_word_cnt > 10'd1)
        wr_qword <= dst_din64;
end

// ---------------------------------------------------------------------------
// wr_beat register — 0..3, which 16-bit lane of wr_qword is being written.
//   Advances when a word write completes (in S_WR_NEXT).
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        wr_beat <= 2'd0;
    else if (state == S_IDLE && !init && !scan_rd && dst_wr_req)
        wr_beat <= 2'd0;
    else if (state == S_WR_NEXT)
        wr_beat <= wr_beat + 2'd1;
end

// ---------------------------------------------------------------------------
// wr_word_cnt register — remaining 16-bit words to write.
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        wr_word_cnt <= 10'd0;
    else if (state == S_IDLE && !init && !scan_rd && dst_wr_req)
        // burst write: N_qwords * 4 words; single write: exactly 1 word
        wr_word_cnt <= dst_we_burst ? {dst_we_qcnt, 2'b00} : 10'd1;
    else if (state == S_WR_NEXT && wr_word_cnt != 10'd0)
        wr_word_cnt <= wr_word_cnt - 10'd1;
end

// ---------------------------------------------------------------------------
// dst_wr_accept — one-cycle strobe: client must advance dst_din64 to the next
// qword.  Fired EARLY in each qword (at wr_beat==1) when more qwords remain, so
// the client has the rest of the qword's single-location writes (~2-3 cold
// writes) to present the next qword before wr_qword is reloaded at wr_beat==3.
// (wr_word_cnt>4 ⇒ at least one full qword remains beyond the current one.)
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        dst_wr_accept <= 1'b0;
    else
        dst_wr_accept <= (state == S_WR_NEXT) && (wr_beat == 2'd1) &&
                         (wr_word_cnt > 10'd4);
end

// ---------------------------------------------------------------------------
// word_cnt register — remaining 16-bit words to receive (reads).
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        word_cnt <= 10'd0;
    else if (state == S_IDLE && !init) begin
        if (scan_rd)            word_cnt <= {scan_burst, 2'b00};
        else if (dst_wr_req)    word_cnt <= 10'd0;   // writes don't use word_cnt
        else if (dst_rd)        word_cnt <= {dst_burst, 2'b00};
        else if (p0_rd)         word_cnt <= {p0_burst, 2'b00};
    end
    else if (rd_dv)
        word_cnt <= word_cnt - 10'd1;
end

// ---------------------------------------------------------------------------
// beat_pos register — 0..3, cycles per read qword.
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        beat_pos <= 2'd0;
    else if (state == S_IDLE && !init)
        beat_pos <= 2'd0;
    else if (rd_dv)
        beat_pos <= beat_pos + 2'd1;
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
// Per-client assembled qword + dready (steered by grant).
// ---------------------------------------------------------------------------
always @(posedge clk or posedge rst) begin
    if (rst)
        scan_dout64 <= 64'd0;
    else if (rd_grant_scan && qword_done)
        scan_dout64 <= {rd_data, asm_reg[47:0]};
end
always @(posedge clk or posedge rst) begin
    if (rst)
        scan_dready <= 1'b0;
    else
        scan_dready <= rd_grant_scan && qword_done;
end

always @(posedge clk or posedge rst) begin
    if (rst)
        dst_dout64 <= 64'd0;
    else if (rd_grant_dstr && qword_done)
        dst_dout64 <= {rd_data, asm_reg[47:0]};
end
always @(posedge clk or posedge rst) begin
    if (rst)
        dst_dready <= 1'b0;
    else
        dst_dready <= rd_grant_dstr && qword_done;
end

always @(posedge clk or posedge rst) begin
    if (rst)
        p0_dout64 <= 64'd0;
    else if (rd_grant_p0 && qword_done)
        p0_dout64 <= {rd_data, asm_reg[47:0]};
end
always @(posedge clk or posedge rst) begin
    if (rst)
        p0_dready <= 1'b0;
    else
        p0_dready <= rd_grant_p0 && qword_done;
end

endmodule
