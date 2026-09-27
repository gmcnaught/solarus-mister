//============================================================================
//  walk_prefetch.sv — burst prefetch of batch-walker entries (blitter_top)
//
//  The batch walkers (TILELIST / TILELIST_RES / SPRITELIST / TILEMAP) used to
//  fetch every entry qword with its own single-beat DDR read (S_RD_WAIT, ~18
//  cycles each, one at a time, and only between blits). This unit streams the
//  op's entry array from DDR as multi-beat bursts into a FIFO, while
//  comp_pipeline runs (comp_pipeline never uses the mem_* master), and hands the
//  walker the qwords it asks for through a small window.
//
//  Stream: nrows rows; row r covers bytes [start_byte + r*stride_bytes,
//  + row_bytes) of the region at base_qw. A linear entry array is one row. The
//  TILEMAP cell window is one row per cell row. Each row is read as the qwords
//  that cover it, in bursts of <= BURST beats, one burst in flight at a time.
//  Every FIFO entry carries its absolute qword address (tag); tags never
//  decrease (consecutive rows may repeat a qword when a row ends mid-qword).
//
//  Consumer: the walker presents a target qword address (cons_T) and a count
//  (cons_k, 1..3) and waits for cons_ready. The window then holds qwords
//  cons_T .. cons_T+k-1 in w0..w2. Qwords below cons_T are dropped. A qword is
//  not dropped until the target moves past it, so consecutive entries that
//  share a qword (12-byte entries, adjacent cells) both see it. k > 1 is only
//  valid for single-row streams (contiguous tags).
//
//  stop: stop issuing, wait for the in-flight burst's beats, then flush the
//  FIFO and window and release the bus (own -> 0).
//
//  Copyright (C) 2026 — GPL-3.0
//============================================================================
`default_nettype none

module walk_prefetch #(
    parameter DEPTH_LG2 = 6,     // FIFO depth 64 qwords
    parameter BURST     = 16     // max beats per DDR burst (arbiter holds the reader off this long)
) (
    input  wire        clk,
    input  wire        rst,
    // ---- stream control ----
    input  wire        start,         // pulse; parameters valid this cycle
    input  wire [28:0] base_qw,       // region base (qword address)
    input  wire [31:0] start_byte,    // byte offset of row 0 within the region
    input  wire [31:0] row_bytes,     // bytes per row (>= 1)
    input  wire [23:0] stride_bytes,  // row-to-row byte stride
    input  wire [9:0]  nrows,         // >= 1
    input  wire        stop,          // level: finish the in-flight burst, flush, release
    output reg         own,           // bus owner (start .. flush); owner-mux select
    // ---- DDR read master (qword addressed, same handshake as blitter_top bm_*) ----
    output reg  [28:0] mem_addr,
    output reg         mem_rd,        // held until accepted (!mem_busy)
    output reg  [7:0]  mem_burstcnt,
    input  wire        mem_busy,
    input  wire [63:0] mem_dout,
    input  wire        mem_dout_ready,
    // ---- consumer window ----
    input  wire        cons_en,       // walker waiting in S_PF_WIN
    input  wire [28:0] cons_T,        // first qword wanted
    input  wire [1:0]  cons_k,        // qwords wanted (1..3)
    output wire        cons_ready,
    output wire [63:0] w0, w1, w2,
    output wire        beat,          // one qword received (profile)
    output wire        dbg_starved    // stream finished and the window cannot be satisfied
);
    localparam DEPTH = 1 << DEPTH_LG2;
    localparam [8:0] BURST9 = BURST;

    // ── FIFO: {tag, data}. Registered read (M10K); first-word-fall-through by
    //    addressing the RAM with the NEXT read pointer. An entry is readable one
    //    cycle after its write lands (wp_q), so a same-edge write/read never
    //    returns the collision value.
    (* ramstyle = "no_rw_check, M10K" *) reg [92:0] fifo [0:DEPTH-1];
    reg  [DEPTH_LG2:0] wp, wp_q, rp;
    reg  [92:0]        head;
    wire               pop;
    wire [DEPTH_LG2:0] rp_next = rp + {{DEPTH_LG2{1'b0}}, pop};
    wire               head_valid = (rp != wp_q);
    wire [28:0]        head_tag   = head[92:64];
    wire [DEPTH_LG2:0] fifo_cnt   = wp - rp;
    reg                flush;
    wire               fifo_we;

    // ── burst generator ──
    localparam [1:0] G_IDLE = 2'd0, G_ROW = 2'd1, G_RUN = 2'd2;
    reg  [1:0]  g_st;
    reg  [31:0] g_rb;          // current row byte offset
    reg  [31:0] g_rowb;        // row_bytes
    reg  [23:0] g_stride;
    reg  [9:0]  g_rows;        // rows left, including the current one
    reg  [28:0] g_base;
    reg  [28:0] g_q, g_qe;     // next qword to request / last qword of the row
    reg  [8:0]  rx_left;       // beats still owed by the accepted/pending burst
    reg  [28:0] rx_tag;        // tag of the next beat
    wire [28:0] g_rem   = g_qe - g_q;                         // remaining - 1
    wire [8:0]  g_need  = (g_rem >= BURST9 - 9'd1) ? BURST9 : ({1'b0, g_rem[7:0]} + 9'd1);
    wire [9:0]  g_credit = DEPTH - fifo_cnt;               // free FIFO entries (no beats in flight here)
    wire        rx_beat = own && mem_dout_ready && (rx_left != 9'd0);
    assign beat    = rx_beat;
    assign fifo_we = rx_beat;

    always @(posedge clk) begin
        if (rst) begin
            own <= 1'b0; mem_rd <= 1'b0; mem_addr <= 29'd0; mem_burstcnt <= 8'd1;
            g_st <= G_IDLE; g_rb <= 32'd0; g_rowb <= 32'd0; g_stride <= 24'd0;
            g_rows <= 10'd0; g_base <= 29'd0; g_q <= 29'd0; g_qe <= 29'd0;
            rx_left <= 9'd0; rx_tag <= 29'd0; wp <= 0; wp_q <= 0; flush <= 1'b0;
        end else begin
            wp_q  <= wp;
            flush <= 1'b0;
            if (mem_rd && !mem_busy) mem_rd <= 1'b0;               // accepted
            if (rx_beat) begin
                wp      <= wp + 1'b1;
                rx_tag  <= rx_tag + 29'd1;
                rx_left <= rx_left - 9'd1;
            end
            if (start) begin
                own      <= 1'b1;
                g_base   <= base_qw;
                g_rb     <= start_byte;
                g_rowb   <= row_bytes;
                g_stride <= stride_bytes;
                g_rows   <= nrows;
                g_st     <= G_ROW;
            end else if (stop) begin
                g_st <= G_IDLE;
                // release once nothing is pending or in flight; flush the rest
                if (own && !mem_rd && rx_left == 9'd0 && !flush) begin
                    own   <= 1'b0;
                    flush <= 1'b1;
                end
            end else case (g_st)
                G_ROW: begin
                    g_q  <= g_base + g_rb[31:3];
                    g_qe <= g_base + ((g_rb + g_rowb - 32'd1) >> 3);
                    g_st <= G_RUN;
                end
                G_RUN: if (!mem_rd && rx_left == 9'd0) begin
                    if (g_q > g_qe) begin                           // row done
                        g_rb   <= g_rb + {8'd0, g_stride};
                        g_rows <= g_rows - 10'd1;
                        g_st   <= (g_rows == 10'd1) ? G_IDLE : G_ROW;
                    end else if (g_credit >= {1'b0, g_need}) begin
                        mem_rd       <= 1'b1;
                        mem_addr     <= g_q;
                        mem_burstcnt <= g_need[7:0];
                        rx_left      <= g_need;
                        rx_tag       <= g_q;
                        g_q          <= g_q + {20'd0, g_need};
                    end
                end
                default: ;
            endcase
        end
    end

    always @(posedge clk) begin
        if (fifo_we) fifo[wp[DEPTH_LG2-1:0]] <= {rx_tag, mem_dout};
        head <= fifo[rp_next[DEPTH_LG2-1:0]];
    end

    // ── consumer window ──
    reg  [63:0] wd0, wd1, wd2;
    reg  [28:0] wt0, wt1, wt2;
    reg  [1:0]  wn;
    assign w0 = wd0; assign w1 = wd1; assign w2 = wd2;
    assign cons_ready = (wn >= cons_k) && (wt0 == cons_T);
    wire   w_drop     = cons_en && !cons_ready && (wn != 2'd0) && (wt0 < cons_T);
    wire   w_take     = cons_en && !cons_ready && !w_drop && (wn < cons_k) && head_valid;
    wire   w_discard  = w_take && (wn == 2'd0) && (head_tag < cons_T);
    assign pop        = w_take && !flush;
    // (own is still 0 on the start cycle, when the generator has not left G_IDLE yet)
    assign dbg_starved = cons_en && own && !cons_ready && !w_drop && !head_valid
                      && (g_st == G_IDLE) && !mem_rd && (rx_left == 9'd0) && (wp == wp_q);

    always @(posedge clk) begin
        if (rst) begin
            rp <= 0; wn <= 2'd0;
            wd0 <= 64'd0; wd1 <= 64'd0; wd2 <= 64'd0;
            wt0 <= 29'd0; wt1 <= 29'd0; wt2 <= 29'd0;
        end else if (flush || start) begin
            rp <= flush ? wp : rp;          // start: FIFO is already empty (flushed at stop)
            wn <= 2'd0;
        end else begin
            rp <= rp_next;
            if (w_drop) begin
                wd0 <= wd1; wd1 <= wd2;
                wt0 <= wt1; wt1 <= wt2;
                wn  <= wn - 2'd1;
            end else if (w_take && !w_discard) begin
                case (wn)
                    2'd0:    begin wd0 <= head[63:0]; wt0 <= head_tag; end
                    2'd1:    begin wd1 <= head[63:0]; wt1 <= head_tag; end
                    default: begin wd2 <= head[63:0]; wt2 <= head_tag; end
                endcase
                wn <= wn + 2'd1;
            end
        end
    end

`ifdef FABRIC_ASSERT
    always @(posedge clk) if (!rst && cons_en && wn != 2'd0)
        assert (wt0 <= cons_T)
        else $display("FABRIC-ASSERT FAIL [walk_prefetch]: window head %h is past target %h @%0t", wt0, cons_T, $time);
    always @(posedge clk) if (!rst)
        assert (!dbg_starved)
        else $display("FABRIC-ASSERT FAIL [walk_prefetch]: stream exhausted before target %h (k=%0d) @%0t", cons_T, cons_k, $time);
    always @(posedge clk) if (!rst && rx_beat)
        assert (fifo_cnt < DEPTH)
        else $display("FABRIC-ASSERT FAIL [walk_prefetch]: FIFO overflow @%0t", $time);
    always @(posedge clk) if (!rst && start)
        assert (!own && rx_left == 9'd0 && wp == rp)
        else $display("FABRIC-ASSERT FAIL [walk_prefetch]: start while busy (own=%b rx_left=%0d cnt=%0d) @%0t", own, rx_left, fifo_cnt, $time);
`endif
endmodule
`default_nettype wire
