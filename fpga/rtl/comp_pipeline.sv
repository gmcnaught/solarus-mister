// comp_pipeline.sv — per-blit, band-chunked RMW compositor (Spec A, Task 5)
// Copyright (C) 2026 — GPL-3.0
//
// Executes ONE blit at a time, bit-exact to the legacy blitter_top per-pixel FSM
// (blitter_ref). Wires together the comp_* family:
//   comp_span_setup  → clip/flip → one row-span per visible dst row
//   comp_src_linebuf → on-chip source row (filled from DDR per span)
//   comp_dest_band   → 320px × 16-row RMW band buffer (load → cw merge → flush)
//   comp_mixer       → LAT=3 issue-interval-1 blend pipeline
//
// For tall blits (clipped height > 16 rows) the work is split into CHUNKS of
// ≤16 consecutive destination rows; each chunk is LOAD → COMPOSITE → FLUSH'd
// back to DDR before the next chunk starts.
//
// ── hflip-once decision ─────────────────────────────────────────────────────
// HFLIP is applied EXACTLY ONCE here, in comp_pipeline's source-fetch addressing
// (the per-span serve_x cursor), and comp_src_linebuf.serve_hflip is held 0.
// This directly mirrors the legacy FSM's src_byte_cur +/-2 walk and is therefore
// bit-exact. comp_span_setup already flip-resolves span_src_x0 (the start), so we
// walk serve_x by +1 (no flip) / -1 (hflip) from (c_src_x + span_src_x0). We do
// NOT also set serve_hflip — that would double-flip.
//
// ── c_src_x / c_src_y application ───────────────────────────────────────────
// comp_span_setup emits span_src_x0 / span_src_y FLIP-RESOLVED but WITHOUT the
// source-rect origin. We add c_src_x / c_src_y here in source addressing:
//   src_local_x(k) = c_src_x + span_src_x0 + (hflip? -k : +k)
//   src_local_y    = c_src_y + span_src_y
//   src_byte       = c_src_off + src_local_y*c_src_stride + src_local_x*2
//
`default_nettype none
`include "comp_defs.vh"
`include "blitter_defs.vh"

module comp_pipeline (
  input  wire        clk,
  input  wire        rst,

  // ── command interface ──────────────────────────────────────────────────────
  input  wire        blit_start,         // one-cycle pulse to begin a blit
  input  wire  [7:0] c_opcode,           // OP_FILL=2, OP_BLIT=3
  input  wire  [7:0] c_blend,            // BLEND_KEY=1, BLEND_ALPHA=2, BLEND_PALPHA=3
  input  wire  [7:0] c_format,           // FMT_RGB565=0, FMT_ARGB4444=1
  input  wire  [7:0] c_flags,            // F_HFLIP=01, F_VFLIP=02, F_COLORKEY=04
  input  wire [31:0] c_src_off,          // source byte offset (heap-relative)
  input  wire [15:0] c_src_stride,       // source row stride (bytes)
  input  wire [15:0] c_src_x,            // source rect origin x (pixels)
  input  wire [15:0] c_src_y,            // source rect origin y (pixels)
  input  wire [15:0] c_w,
  input  wire [15:0] c_h,
  input  wire [15:0] c_colorkey,
  input  wire  [7:0] c_alpha,
  input  wire [15:0] c_color,            // FILL color
  input  wire signed [15:0] c_dst_x,
  input  wire signed [15:0] c_dst_y,
  input  wire [31:0] target_base,        // framebuffer base qword

  // ── shared mem_* master (owned only while a pipe blit runs) ─────────────────
  output reg  [31:0] mem_addr,
  output reg         mem_rd,
  output reg         mem_wr,
  output reg  [63:0] mem_din,
  output reg  [7:0]  mem_be,
  input  wire [63:0] mem_dout,
  input  wire        mem_dout_ready,
  input  wire        mem_busy,

  output reg         blit_done           // one-cycle pulse when the blit completes
);

  // ── opcode / blend / format / flag constants (mirror blitter_top) ───────────
  localparam [7:0] OP_FILL=8'd2, OP_BLIT=8'd3;
  localparam [7:0] BLEND_KEY=8'd1, BLEND_ALPHA=8'd2, BLEND_PALPHA=8'd3;
  localparam [7:0] F_HFLIP=8'h01, F_VFLIP=8'h02, F_COLORKEY=8'h04;

  wire keyed       = (c_blend == BLEND_KEY) || ((c_flags & F_COLORKEY) != 0);
  wire is_fill     = (c_opcode == OP_FILL);

  // ════════════════════════════════════════════════════════════════════════════
  //  sub-module wiring
  // ════════════════════════════════════════════════════════════════════════════

  // ---- comp_span_setup ----
  reg         ss_start;
  wire        ss_span_valid;
  wire [15:0] ss_span_dst_x, ss_span_dst_y, ss_span_len, ss_span_src_x0, ss_span_src_y;
  wire        ss_span_last, ss_done;

  comp_span_setup u_span (
    .clk(clk), .start(ss_start),
    .c_dst_x(c_dst_x), .c_dst_y(c_dst_y),
    .c_w(c_w), .c_h(c_h), .c_flags(c_flags),
    .span_valid(ss_span_valid),
    .span_dst_x(ss_span_dst_x), .span_dst_y(ss_span_dst_y),
    .span_len(ss_span_len),
    .span_src_x0(ss_span_src_x0), .span_src_y(ss_span_src_y),
    .span_last(ss_span_last), .done(ss_done)
  );

  // ---- comp_src_linebuf ----
  reg         lb_fill_we;
  reg  [63:0] lb_fill_qw;
  reg   [9:0] lb_fill_idx;
  reg         lb_serve_req;
  reg  [15:0] lb_serve_x;
  wire        lb_serve_valid;
  wire [15:0] lb_serve_pix;

  comp_src_linebuf u_linebuf (
    .clk(clk),
    .fill_we(lb_fill_we), .fill_qw(lb_fill_qw), .fill_idx(lb_fill_idx),
    .serve_req(lb_serve_req), .serve_x(lb_serve_x),
    .serve_w(16'd0), .serve_hflip(1'b0),   // hflip handled in serve_x walk (see header)
    .serve_valid(lb_serve_valid), .serve_pix(lb_serve_pix)
  );

  // ---- comp_dest_band ----
  reg         db_ld_we;
  reg  [63:0] db_ld_qw;
  reg  [12:0] db_ld_idx;
  reg         db_cw_we;
  reg  [15:0] db_cw_x;
  reg   [3:0] db_cw_row;
  reg  [15:0] db_cw_pix;
  reg  [15:0] db_rd_x;
  reg   [3:0] db_rd_row;
  wire [15:0] db_rd_dst;
  reg         db_flush_req;
  wire        db_fl_valid;
  wire [63:0] db_fl_qw;
  wire  [7:0] db_fl_be;
  wire [12:0] db_fl_idx;
  wire        db_flush_done;

  comp_dest_band u_band (
    .clk(clk),
    .ld_we(db_ld_we), .ld_qw(db_ld_qw), .ld_idx(db_ld_idx),
    .cw_we(db_cw_we), .cw_x(db_cw_x), .cw_row(db_cw_row), .cw_pix(db_cw_pix),
    .rd_x(db_rd_x), .rd_row(db_rd_row), .rd_dst(db_rd_dst),
    .flush_req(db_flush_req),
    .fl_valid(db_fl_valid), .fl_qw(db_fl_qw), .fl_be(db_fl_be), .fl_idx(db_fl_idx),
    .flush_done(db_flush_done)
  );

  // ---- comp_mixer ----
  reg         mx_in_valid;
  reg  [15:0] mx_in_src;
  reg  [15:0] mx_in_dst;
  reg   [7:0] mx_in_mode;
  reg   [7:0] mx_in_fmt;
  reg  [15:0] mx_in_key;
  reg   [7:0] mx_in_alpha;
  wire        mx_out_valid;
  wire [15:0] mx_out_pix;
  wire        mx_out_we;

  comp_mixer u_mixer (
    .clk(clk),
    .in_valid(mx_in_valid), .in_src(mx_in_src), .in_dst(mx_in_dst),
    .in_mode(mx_in_mode), .in_fmt(mx_in_fmt), .in_key(mx_in_key), .in_alpha(mx_in_alpha),
    .out_valid(mx_out_valid), .out_pix(mx_out_pix), .out_we(mx_out_we)
  );

  // mixer mode mapping (c_blend → comp_mixer in_mode) for the NON-palpha modes.
  wire [7:0] mix_mode = is_fill                  ? `COMP_COPY :
                        (c_blend == BLEND_ALPHA)  ? `COMP_CA   :
                        keyed                     ? `COMP_KEY  :
                                                    `COMP_COPY;

  // ── per-pixel mixer-feed derivation (evaluated at the FEED cycle) ──────────
  // For PALPHA the served pixel lb_serve_pix is ARGB4444 {A4,R4,G4,B4}. comp_mixer
  // does NOT expand ARGB4444 channels, so to stay bit-exact with the legacy
  // blend4444 we expand here and feed COMP_CA with a8={A4,A4}:
  //   sr={r4,r4[3]}  sg={g4,g4[3:2]}  sb={b4,b4[3]}
  wire        b_palpha = (c_blend == BLEND_PALPHA) && !is_fill;
  wire  [3:0] pa_a4 = lb_serve_pix[15:12];
  wire  [3:0] pa_r4 = lb_serve_pix[11:8];
  wire  [3:0] pa_g4 = lb_serve_pix[7:4];
  wire  [3:0] pa_b4 = lb_serve_pix[3:0];
  wire [15:0] pa_expanded = { pa_r4, pa_r4[3],          // R5
                              pa_g4, pa_g4[3:2],         // G6
                              pa_b4, pa_b4[3] };         // B5
  wire  [7:0] pa_a8 = { pa_a4, pa_a4 };
  // mixer-feed selects (PALPHA → expanded src + COMP_CA + a8; else pass-through)
  wire [15:0] feed_src   = b_palpha ? pa_expanded : lb_serve_pix;
  wire  [7:0] feed_mode  = b_palpha ? `COMP_CA     : mix_mode;
  wire  [7:0] feed_alpha = b_palpha ? pa_a8        : c_alpha;
  wire        feed_skip  = b_palpha && (pa_a4 == 4'd0);   // A4==0 → fully transparent

  // ════════════════════════════════════════════════════════════════════════════
  //  flush FIFO — comp_dest_band's flush FSM walks 1 qword/cycle and cannot be
  //  paused, but DDR single-beat writes are backpressured. Capture every fl_*
  //  emission into a FIFO and drain it to DDR at the bus's pace.
  // ════════════════════════════════════════════════════════════════════════════
  localparam FIFO_AW = 11;                       // 2048 entries ≥ 1280 max dirty qw
  reg [63:0] f_qw  [0:(1<<FIFO_AW)-1];
  reg  [7:0] f_be  [0:(1<<FIFO_AW)-1];
  reg [12:0] f_idx [0:(1<<FIFO_AW)-1];
  reg [FIFO_AW:0] f_wptr, f_rptr;                // extra bit for full/empty disambig
  wire f_empty = (f_wptr == f_rptr);

  // ════════════════════════════════════════════════════════════════════════════
  //  FSM
  // ════════════════════════════════════════════════════════════════════════════
  localparam [5:0]
    P_IDLE        = 6'd0,
    P_SPAN_COLL   = 6'd1,
    P_CHUNK_INIT  = 6'd2,
    P_LOAD_ISS    = 6'd3,
    P_LOAD_WAIT   = 6'd4,
    P_COMP_SPAN   = 6'd5,
    P_SRCFILL_ISS = 6'd6,
    P_SRCFILL_WAIT= 6'd7,
    P_PIXEL       = 6'd8,
    P_DRAIN       = 6'd9,
    P_FLUSH_REQ   = 6'd10,
    P_FLUSH_DRAIN = 6'd11,    // drain band flush emissions into the FIFO
    P_WB_ISS      = 6'd12,    // pop FIFO, issue DDR write
    P_WB_WAIT     = 6'd13,    // hold the DDR write until accepted
    P_DONE        = 6'd14;
  reg [5:0] state;

  // shared read handshake (mirror blitter_top S_RD_WAIT)
  reg        rd_issued;
  reg [5:0]  rd_ret;           // state to enter after a read completes
  reg [63:0] rd_data;

  // ── span table (max FB_H=240 spans) ─────────────────────────────────────────
  localparam MAX_SPANS = 240;
  reg [15:0] sp_dst_x [0:MAX_SPANS-1];
  reg [15:0] sp_dst_y [0:MAX_SPANS-1];
  reg [15:0] sp_len   [0:MAX_SPANS-1];
  reg [15:0] sp_src_x0[0:MAX_SPANS-1];
  reg [15:0] sp_src_y [0:MAX_SPANS-1];
  reg [8:0]  span_count, span_wr;

  // ── chunk bookkeeping ────────────────────────────────────────────────────────
  localparam [8:0] BAND_H = `COMP_BAND_H;        // 16
  reg [8:0]  chunk_first, chunk_nspan, chunk_si, ld_si;
  reg [15:0] chunk_base_y;

  // ── per-span working registers ───────────────────────────────────────────────
  reg [15:0] cur_dst_x, cur_dst_y, cur_len, cur_src_x0, cur_src_y;
  reg  [3:0] cur_band_row;
  // global source-pixel addressing (heap-relative pixel index = byte>>1).
  reg [31:0] gpix0;                               // gpix of served pixel k=0
  reg [31:0] gpix_lo, gpix_hi;                    // inclusive gpix range of the span
  reg [31:0] fill_qw;                             // current SRC qword being filled

  // ── band preload bookkeeping ─────────────────────────────────────────────────
  reg [15:0] ld_qx, ld_qx_end;
  reg  [3:0] ld_band_row;

  // ── per-pixel compositing pipeline ───────────────────────────────────────────
  // Issue at cycle T registers rd_x / serve_x; the band rd_dst + linebuf serve_pix
  // become valid registers AFTER the T+1 edge (1-cycle read latency), so we sample
  // them into the mixer at T+2.  Two valid/coord stages carry the metadata:
  //   s1_* : 1 cycle after issue (read in flight)
  //   s2_* : 2 cycles after issue (rd_dst/serve_pix valid → FEED the mixer)
  reg [15:0] pix_k, pix_total;
  reg        s1_valid, s2_valid;
  reg [15:0] s1_cw_x, s2_cw_x;
  reg  [3:0] s1_cw_row, s2_cw_row;

  localparam MIX_LAT = 3;
  reg [15:0] cwx_pipe [0:MIX_LAT];
  reg  [3:0] cwr_pipe [0:MIX_LAT];
  reg        cwv_pipe [0:MIX_LAT];
  integer    pp;
  // pipeline depth from last issue to last write-back: 2 (read+feed) + MIX_LAT.
  localparam [3:0] PIPE_DEPTH = 2 + MIX_LAT;
  reg [3:0]  drain_cnt;

  // source row base byte address for the current span (origin-y applied).
  // _n variant uses the span being latched THIS cycle in P_COMP_SPAN (cur_src_y
  // is not yet updated), so the gpix computation sees the correct row.
  wire [31:0] src_row_base_n = c_src_off
            + (({16'd0, c_src_y} + {16'd0, sp_src_y[chunk_first + chunk_si]})
                 * {16'd0, c_src_stride});

  // ── power-on state ────────────────────────────────────────────────────────────
  initial begin
    state       = P_IDLE;
    mem_rd      = 1'b0; mem_wr = 1'b0; mem_be = 8'd0; mem_addr = 32'd0; mem_din = 64'd0;
    blit_done   = 1'b0; ss_start = 1'b0;
    lb_fill_we  = 1'b0; lb_serve_req = 1'b0;
    db_ld_we    = 1'b0; db_cw_we = 1'b0; db_flush_req = 1'b0;
    mx_in_valid = 1'b0; s1_valid = 1'b0; s2_valid = 1'b0; rd_issued = 1'b0;
    span_count  = 9'd0; f_wptr = 0; f_rptr = 0;
  end

  always @(posedge clk) begin
    if (rst) begin
      state <= P_IDLE;
      mem_rd <= 1'b0; mem_wr <= 1'b0; mem_be <= 8'd0;
      blit_done <= 1'b0; ss_start <= 1'b0;
      lb_fill_we <= 1'b0; lb_serve_req <= 1'b0;
      db_ld_we <= 1'b0; db_cw_we <= 1'b0; db_flush_req <= 1'b0;
      mx_in_valid <= 1'b0; s1_valid <= 1'b0; s2_valid <= 1'b0; rd_issued <= 1'b0;
      f_wptr <= 0; f_rptr <= 0;
    end else begin
      // single-cycle strobe defaults
      mem_rd       <= 1'b0;     // read request is a per-cycle pulse (re-asserted in wait states)
      ss_start     <= 1'b0;
      lb_fill_we   <= 1'b0;
      lb_serve_req <= 1'b0;
      db_ld_we     <= 1'b0;
      db_cw_we     <= 1'b0;
      db_flush_req <= 1'b0;
      mx_in_valid  <= 1'b0;
      blit_done    <= 1'b0;

      case (state)

        // ─────────────────────────────────────────────────────────────────────
        P_IDLE: begin
          mem_rd <= 1'b0; mem_wr <= 1'b0;
          if (blit_start) begin
            ss_start   <= 1'b1;
            span_wr    <= 9'd0;
            f_wptr     <= 0; f_rptr <= 0;
            state      <= P_SPAN_COLL;
          end
        end

        // ─────────────────────────────────────────────────────────────────────
        // Collect every span from comp_span_setup into the span table.
        P_SPAN_COLL: begin
          if (ss_span_valid) begin
            sp_dst_x [span_wr] <= ss_span_dst_x;
            sp_dst_y [span_wr] <= ss_span_dst_y;
            sp_len   [span_wr] <= ss_span_len;
            sp_src_x0[span_wr] <= ss_span_src_x0;
            sp_src_y [span_wr] <= ss_span_src_y;
            span_wr            <= span_wr + 9'd1;
          end
          if (ss_done) begin
            span_count  <= span_wr;
            chunk_first <= 9'd0;
            if (span_wr == 9'd0) state <= P_DONE;     // fully clipped → nothing
            else                 state <= P_CHUNK_INIT;
          end
        end

        // ─────────────────────────────────────────────────────────────────────
        // Set up the next ≤BAND_H-row chunk.
        P_CHUNK_INIT: begin
          if (chunk_first >= span_count) begin
            state <= P_DONE;
          end else begin
            chunk_nspan  <= ((span_count - chunk_first) > BAND_H)
                              ? BAND_H : (span_count - chunk_first);
            chunk_base_y <= sp_dst_y[chunk_first];
            ld_si        <= 9'd0;
            state        <= P_LOAD_ISS;
          end
        end

        // ─────────────────────────────────────────────────────────────────────
        // BAND PRELOAD — read the touched qword x-range of each span so blend
        // RMW reads see real FB data (and the band's ld clears stale dirty/be).
        // Applied for BOTH blit and fill (fill needs the be/dirty clear).
        P_LOAD_ISS: begin
          if (ld_si >= chunk_nspan) begin
            chunk_si <= 9'd0;
            state    <= P_COMP_SPAN;
          end else begin
            ld_qx       <= sp_dst_x[chunk_first + ld_si][15:2];
            ld_qx_end   <= (sp_dst_x[chunk_first + ld_si] + sp_len[chunk_first + ld_si] - 16'd1) >> 2;
            ld_band_row <= (sp_dst_y[chunk_first + ld_si] - chunk_base_y);
            mem_addr    <= target_base
                         + ({16'd0, sp_dst_y[chunk_first + ld_si]} * 32'd80)
                         + {16'd0, sp_dst_x[chunk_first + ld_si][15:2]};
            mem_rd      <= 1'b1;
            rd_issued   <= 1'b0;
            rd_ret      <= P_LOAD_WAIT;
            state       <= P_LOAD_WAIT;
          end
        end

        // Backpressure-safe preload read + band write.
        P_LOAD_WAIT: begin
          if (!rd_issued) begin
            mem_rd <= 1'b1;
            if (!mem_busy) rd_issued <= 1'b1;
          end else if (mem_dout_ready) begin
            rd_issued <= 1'b0;
            db_ld_we  <= 1'b1;
            db_ld_qw  <= mem_dout;
            db_ld_idx <= ({4'd0, ld_band_row} * 13'd80) + {3'd0, ld_qx[9:0]};
            if (ld_qx >= ld_qx_end) begin
              ld_si <= ld_si + 9'd1;
              state <= P_LOAD_ISS;
            end else begin
              ld_qx    <= ld_qx + 16'd1;
              mem_addr <= target_base
                        + ({16'd0, sp_dst_y[chunk_first + ld_si]} * 32'd80)
                        + {16'd0, (ld_qx + 16'd1)};
              mem_rd   <= 1'b1;
              state    <= P_LOAD_WAIT;
            end
          end
        end

        // ─────────────────────────────────────────────────────────────────────
        // COMPOSITE one span: latch params + compute the source-x fill window.
        P_COMP_SPAN: begin
          if (chunk_si >= chunk_nspan) begin
            state <= P_FLUSH_REQ;
          end else begin
            cur_dst_x    <= sp_dst_x [chunk_first + chunk_si];
            cur_dst_y    <= sp_dst_y [chunk_first + chunk_si];
            cur_len      <= sp_len   [chunk_first + chunk_si];
            cur_src_x0   <= sp_src_x0[chunk_first + chunk_si];
            cur_src_y    <= sp_src_y [chunk_first + chunk_si];
            cur_band_row <= (sp_dst_y[chunk_first + chunk_si] - chunk_base_y);
            if (is_fill) begin
              pix_k     <= 16'd0;
              pix_total <= sp_len[chunk_first + chunk_si];
              state     <= P_PIXEL;
            end else begin
              // GLOBAL-PIXEL source addressing (robust to stride<8 / non-qword-
              // aligned rows — mirrors the legacy FSM's absolute byte cursor):
              //   gpix(k) = (src_row_base>>1) + c_src_x + src_x0  ± k   (hflip = -k)
              //   SRC qword addr = SRC_QW + (gpix>>2)
              //   linebuf index  = gpix - ((gpix_lo>>2)<<2)
              // gpix_lo/hi bound the served pixels; fill_qw walks the qwords.
              gpix0 <= (src_row_base_n >> 1)
                       + {16'd0, c_src_x} + {16'd0, sp_src_x0[chunk_first+chunk_si]};
              if (c_flags & F_HFLIP) begin
                gpix_lo <= (src_row_base_n >> 1) + {16'd0, c_src_x}
                           + {16'd0, sp_src_x0[chunk_first+chunk_si]}
                           - ({16'd0, sp_len[chunk_first+chunk_si]} - 32'd1);
                gpix_hi <= (src_row_base_n >> 1) + {16'd0, c_src_x}
                           + {16'd0, sp_src_x0[chunk_first+chunk_si]};
                fill_qw <= ((src_row_base_n >> 1) + {16'd0, c_src_x}
                           + {16'd0, sp_src_x0[chunk_first+chunk_si]}
                           - ({16'd0, sp_len[chunk_first+chunk_si]} - 32'd1)) >> 2;
              end else begin
                gpix_lo <= (src_row_base_n >> 1) + {16'd0, c_src_x}
                           + {16'd0, sp_src_x0[chunk_first+chunk_si]};
                gpix_hi <= (src_row_base_n >> 1) + {16'd0, c_src_x}
                           + {16'd0, sp_src_x0[chunk_first+chunk_si]}
                           + ({16'd0, sp_len[chunk_first+chunk_si]} - 32'd1);
                fill_qw <= ((src_row_base_n >> 1) + {16'd0, c_src_x}
                           + {16'd0, sp_src_x0[chunk_first+chunk_si]}) >> 2;
              end
              state <= P_SRCFILL_ISS;
            end
          end
        end

        // ─────────────────────────────────────────────────────────────────────
        // SOURCE FILL — read SRC qwords [gpix_lo>>2 .. gpix_hi>>2] into the
        // linebuf at index (fill_qw - (gpix_lo>>2)).
        P_SRCFILL_ISS: begin
          if (fill_qw > (gpix_hi >> 2)) begin
            pix_k     <= 16'd0;
            pix_total <= cur_len;
            state     <= P_PIXEL;
          end else begin
            mem_addr  <= `SRC_QW + fill_qw;
            mem_rd    <= 1'b1;
            rd_issued <= 1'b0;
            state     <= P_SRCFILL_WAIT;
          end
        end

        P_SRCFILL_WAIT: begin
          if (!rd_issued) begin
            mem_rd <= 1'b1;
            if (!mem_busy) rd_issued <= 1'b1;
          end else if (mem_dout_ready) begin
            rd_issued   <= 1'b0;
            lb_fill_we  <= 1'b1;
            lb_fill_qw  <= mem_dout;
            lb_fill_idx <= (fill_qw - (gpix_lo >> 2));    // 0,1,2,... linebuf qword idx
            fill_qw     <= fill_qw + 32'd1;
            state       <= P_SRCFILL_ISS;
          end
        end

        // ─────────────────────────────────────────────────────────────────────
        // PER-PIXEL COMPOSITE.
        //   T   : ISSUE   — register rd_x / serve_x / serve_req (s1)
        //   T+1 : read in flight                                  (s2)
        //   T+2 : FEED    — rd_dst/serve_pix valid as regs → mixer in
        //   T+2+LAT : mixer out → cw write into the band
        P_PIXEL: begin
          // ── ISSUE (k < total) ──
          if (pix_k < pix_total) begin
            if (!is_fill) begin
              lb_serve_req <= 1'b1;
              // linebuf index = gpix(k) - (gpix_lo & ~3)   [gpix_lo aligned base]
              lb_serve_x   <= (c_flags & F_HFLIP)
                ? ((gpix0 - {16'd0, pix_k}) - ((gpix_lo >> 2) << 2))
                : ((gpix0 + {16'd0, pix_k}) - ((gpix_lo >> 2) << 2));
            end
            db_rd_x   <= cur_dst_x + pix_k;
            db_rd_row <= cur_band_row;
            s1_valid  <= 1'b1;
            s1_cw_x   <= cur_dst_x + pix_k;
            s1_cw_row <= cur_band_row;
            pix_k     <= pix_k + 16'd1;
          end else begin
            s1_valid <= 1'b0;
          end

          // ── s1 → s2 (read-in-flight → read-valid) ──
          s2_valid  <= s1_valid;
          s2_cw_x   <= s1_cw_x;
          s2_cw_row <= s1_cw_row;

          // ── FEED MIXER (s2: rd_dst/serve_pix now valid) ──
          // PALPHA bit-exactness: comp_mixer's COMP_PA uses the RGB565 channel
          // split (no ARGB4444 4->5/6/5 expansion), so it does NOT match the
          // legacy blend4444. We therefore EXPAND the ARGB4444 source to RGB565
          // here (sr={r4,r4[3]}, sg={g4,g4[3:2]}, sb={b4,b4[3]}), extract the
          // per-pixel alpha a8={a4,a4}, and drive the mixer in COMP_CA mode — the
          // unified weighted-sum/reduce path that IS bit-exact to blend4444.
          // A4==0 (fully transparent) pixels are skipped via the cw write gate.
          if (s2_valid) begin
            mx_in_valid <= 1'b1;
            mx_in_src   <= is_fill ? c_color : feed_src;
            mx_in_dst   <= db_rd_dst;
            mx_in_mode  <= feed_mode;
            mx_in_fmt   <= c_format;
            mx_in_key   <= c_colorkey;
            mx_in_alpha <= feed_alpha;
          end

          // ── cw coordinate shadow pipeline (seeded at the FEED cycle) ──
          // cwv gates the write-back; fold the PALPHA A4==0 skip in here so a
          // fully-transparent pixel never writes (COMP_CA's out_we is always 1).
          cwx_pipe[0] <= s2_cw_x;
          cwr_pipe[0] <= s2_cw_row;
          cwv_pipe[0] <= s2_valid && !feed_skip;
          for (pp = 1; pp <= MIX_LAT; pp = pp + 1) begin
            cwx_pipe[pp] <= cwx_pipe[pp-1];
            cwr_pipe[pp] <= cwr_pipe[pp-1];
            cwv_pipe[pp] <= cwv_pipe[pp-1];
          end

          // ── WRITE-BACK ──
          if (mx_out_valid && cwv_pipe[MIX_LAT] && mx_out_we) begin
            db_cw_we  <= 1'b1;
            db_cw_x   <= cwx_pipe[MIX_LAT];
            db_cw_row <= cwr_pipe[MIX_LAT];
            db_cw_pix <= mx_out_pix;
          end

          if (pix_k >= pix_total && !s1_valid && !s2_valid) begin
            drain_cnt <= PIPE_DEPTH;
            state     <= P_DRAIN;
          end
        end

        // Drain serve→feed→mixer after the last issue.
        P_DRAIN: begin
          s2_valid    <= 1'b0;
          cwx_pipe[0] <= 16'd0;
          cwr_pipe[0] <= 4'd0;
          cwv_pipe[0] <= 1'b0;
          for (pp = 1; pp <= MIX_LAT; pp = pp + 1) begin
            cwx_pipe[pp] <= cwx_pipe[pp-1];
            cwr_pipe[pp] <= cwr_pipe[pp-1];
            cwv_pipe[pp] <= cwv_pipe[pp-1];
          end
          if (mx_out_valid && cwv_pipe[MIX_LAT] && mx_out_we) begin
            db_cw_we  <= 1'b1;
            db_cw_x   <= cwx_pipe[MIX_LAT];
            db_cw_row <= cwr_pipe[MIX_LAT];
            db_cw_pix <= mx_out_pix;
          end
          if (drain_cnt == 4'd0) begin
            chunk_si <= chunk_si + 9'd1;
            state    <= P_COMP_SPAN;
          end else begin
            drain_cnt <= drain_cnt - 4'd1;
          end
        end

        // ─────────────────────────────────────────────────────────────────────
        // FLUSH: pulse flush_req, capture every emitted dirty qword into the FIFO.
        P_FLUSH_REQ: begin
          db_flush_req <= 1'b1;
          state        <= P_FLUSH_DRAIN;
        end

        P_FLUSH_DRAIN: begin
          if (db_fl_valid) begin
            f_qw [f_wptr[FIFO_AW-1:0]] <= db_fl_qw;
            f_be [f_wptr[FIFO_AW-1:0]] <= db_fl_be;
            f_idx[f_wptr[FIFO_AW-1:0]] <= db_fl_idx;
            f_wptr <= f_wptr + 1'b1;
          end
          if (db_flush_done) begin
            state <= P_WB_ISS;
          end
        end

        // ─────────────────────────────────────────────────────────────────────
        // WRITE-BACK: drain the FIFO to DDR at bus pace.
        P_WB_ISS: begin
          if (f_empty) begin
            // chunk complete → advance to next chunk
            chunk_first <= chunk_first + chunk_nspan;
            state       <= P_CHUNK_INIT;
          end else begin
            mem_wr   <= 1'b1;
            mem_be   <= f_be[f_rptr[FIFO_AW-1:0]];
            mem_addr <= target_base
                      + ({16'd0, chunk_base_y} * 32'd80)
                      + {19'd0, f_idx[f_rptr[FIFO_AW-1:0]]};
            mem_din  <= f_qw[f_rptr[FIFO_AW-1:0]];
            state    <= P_WB_WAIT;
          end
        end

        P_WB_WAIT: begin
          if (!mem_busy) begin
            mem_wr <= 1'b0;
            mem_be <= 8'd0;
            f_rptr <= f_rptr + 1'b1;
            state  <= P_WB_ISS;
          end else begin
            mem_wr <= 1'b1;
          end
        end

        // ─────────────────────────────────────────────────────────────────────
        P_DONE: begin
          mem_rd <= 1'b0; mem_wr <= 1'b0;
          blit_done <= 1'b1;
          state     <= P_IDLE;
        end

        default: state <= P_IDLE;

      endcase
    end
  end

endmodule
`default_nettype wire
