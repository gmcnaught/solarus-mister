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
  // [v2 escape-elim] color-mod (tint): per-channel RGB888 modulation of the SOURCE
  // pixel, applied BEFORE the blend equation. Active only when c_flags & F_COLORMOD
  // (else a true no-op). Composes with every blend_mode (incl. ADD/MULTIPLY) and
  // with FILL (source channel = c_color).
  input  wire  [7:0] c_cmod_r,           // tint R (0..255), identity = 255
  input  wire  [7:0] c_cmod_g,           // tint G (0..255), identity = 255
  input  wire  [7:0] c_cmod_b,           // tint B (0..255), identity = 255
  input  wire signed [15:0] c_dst_x,
  input  wire signed [15:0] c_dst_y,
  input  wire [31:0] target_base,        // framebuffer base qword

  // ── shared mem_* master (owned only while a pipe blit runs) ─────────────────
  // Now driven by the internal comp_burst engine (u_burst), not the FSM directly.
  output wire [31:0] mem_addr,
  output wire        mem_rd,
  output wire        mem_wr,
  output wire [7:0]  mem_burstcnt,
  output wire [63:0] mem_din,
  output wire [7:0]  mem_be,
  input  wire [63:0] mem_dout,
  input  wire        mem_dout_ready,
  input  wire        mem_busy,

  // ── P_SRC cache-ok channel (Task 5: read-only; sprite atlas lives outside FB) ──
  // [collapse-single-source] The SOLE source-pixel path. Every BLIT fetches its
  // source row through P_SRC (SDRAM); the DDR3 live-source path (read via u_burst /
  // SRC_QW) was removed. Protocol: pulse p0_rd for one cycle with p0_addr; capture
  // p0_dout when p0_ok asserts (no busy/backpressure). c_srcsel is retained as an
  // input (hardwired to 1 by blitter_top) so unit benches can still drive the port.
  input  wire        c_srcsel,
  output reg  [26:0] p0_addr,           // qword-aligned byte address
  output reg         p0_rd,             // one-cycle read pulse (cache-ok: no hold)
  input  wire [63:0] p0_dout,           // read data valid when p0_ok asserts
  input  wire        p0_ok,             // per-beat valid strobe from the cache channel

  // ── on-chip framebuffer (comp_fbram) dest port [FB-in-BRAM] ──────────────────
  // The composite destination now lives in on-chip M10K (comp_fbram), not the SDRAM
  // FB. The mixer's RMW dst read comes from fb_rd_qword (lane-selected); the composite
  // result is written one pixel/cycle via fb_wr_*. qword index = y*80 + (x>>2), lane =
  // x[1:0]. (Task 1: ports added but the internal band path is still authoritative —
  // these dangle until the Task 2 cutover routes the mixer through them.)
  output reg         fb_wr_en,
  output reg  [14:0] fb_wr_qw,
  output reg  [1:0]  fb_wr_lane,
  output reg  [15:0] fb_wr_pix,
  output reg         fb_rd_en,
  output reg  [14:0] fb_rd_qw,
  input  wire [63:0] fb_rd_qword,

  output reg         blit_done           // one-cycle pulse when the blit completes
);

  // ── opcode / blend / format / flag constants (mirror blitter_top) ───────────
  localparam [7:0] OP_FILL=8'd2, OP_BLIT=8'd3;
  localparam [7:0] BLEND_KEY=8'd1, BLEND_ALPHA=8'd2, BLEND_PALPHA=8'd3,
                   BLEND_ADD=8'd4, BLEND_MULTIPLY=8'd5;   // [v2 escape-elim]
  localparam [7:0] F_HFLIP=8'h01, F_VFLIP=8'h02, F_COLORKEY=8'h04,
                   F_COLORMOD=8'h40;                       // [v2 escape-elim]

  wire keyed       = (c_blend == BLEND_KEY) || ((c_flags & F_COLORKEY) != 0);
  wire is_fill     = (c_opcode == OP_FILL);
  wire is_add      = (c_blend == BLEND_ADD);
  wire is_mul      = (c_blend == BLEND_MULTIPLY);
  wire colormod_en = (c_flags & F_COLORMOD) != 8'd0;

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
    .fill_bank(1'b0),                       // [Task 3] will drive ping-pong; tied 0 = single-bank
    .serve_req(lb_serve_req), .serve_x(lb_serve_x),
    .serve_w(16'd0), .serve_hflip(1'b0),   // hflip handled in serve_x walk (see header)
    .serve_bank(1'b0),                      // [Task 3] will drive ping-pong; tied 0 = single-bank
    .serve_valid(lb_serve_valid), .serve_pix(lb_serve_pix)
  );

  // ---- destination framebuffer [FB-in-BRAM] ----
  // The dest pixel RMW now goes straight to the on-chip comp_fbram via the fb_*
  // ports (instantiated in the integration layer). No band buffer, no SDRAM
  // preload/flush: comp_fbram IS the framebuffer of record. The per-pixel read
  // (fb_rd_*) and write (fb_wr_*) are driven from P_PIXEL below; the mixer's RMW
  // dst input comes from fb_rd_qword (lane-selected at the pixel's x[1:0]).

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
  // [v2 escape-elim] ADD/MULTIPLY are honoured for BOTH blit AND fill (checked
  // before is_fill), so a FILL with blend_mode ADD/MULTIPLY composites src=c_color
  // against the existing FB pixel (the band preload supplies dst for fills too).
  // Other fills stay a plain COPY; existing blit modes unchanged.
  wire [7:0] mix_mode = is_add                    ? `COMP_ADD  :
                        is_mul                    ? `COMP_MUL  :
                        is_fill                   ? `COMP_COPY :
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

  // [B: skip band-LOAD for opaque COPY] A blit whose composite OVERWRITES every
  // pixel needs no RMW preload of the dest band. That's plain COPY / plain FILL
  // (mix_mode==COMP_COPY) and NOT per-pixel-alpha (b_palpha). Keyed (COMP_KEY,
  // skips matched px), ALPHA/ADD/MUL (blend with dst), and PALPHA all read dst, so
  // they're excluded. Colour-mod stays opaque (COPY still writes). Per-blit const.
  // The actual skip ALSO requires the span to fully cover its qwords (no partial
  // edge lanes) — decided per span in P_LOAD_RD against this flag.
  wire        comp_opaque = (mix_mode == `COMP_COPY) && !b_palpha;

  // ── color-mod (tint) stage [v2 escape-elim] — PIPELINED across 2 cycles ──────
  // Modulate the SOURCE pixel per channel by (cr,cg,cb)/255 BEFORE the blend, gated
  // by F_COLORMOD (clear ⇒ identity true no-op: src_to_mixer_d = raw_src). raw_src is
  // the pre-blend source: c_color for FILL, the served (PALPHA-expanded) pixel for
  // BLIT — so tint composes with COPY/KEY/CONST_ALPHA/PALPHA/ADD/MULTIPLY and with
  // FILL. Same divide-free /255 reduction as blt_blend565 / COMP_DIV255, so
  // (255,255,255) is an EXACT identity.
  //
  // TIMING (fmax): the multiply (R/G/B × 8-bit) and the /255 reduction (+128, >>8,
  // add, >>8) used to be one combinational path between two registers (lb_serve_pix
  // → mx_in_src) — a mult+reduce in a single cycle, the v2 critical path. It is now
  // SPLIT exactly like comp_mixer splits its own MAC (stage B) from /255 (stage C):
  //   cycle T+2 (old FEED): compute the PRODUCTS cm_p{r,g,b} here, register into the
  //                         new s3_cm_p* stage (the multiply gets its own cycle).
  //   cycle T+3 (s3 FEED) : reduce the registered products → cmod_src_d and feed the
  //                         mixer (the reduce gets its own cycle). See the s3 stage.
  // This adds ONE pipeline stage (II stays 1; +1 drain cycle per span — negligible).
  // The reduction is INLINED (not the COMP_DIV255 macro) for the iverilog -y
  // library-mode macro-scoping caveat documented in comp_mixer.sv stage C.
  // NOTE (semantics, bit-exact contract for Workstream C): tint is applied to the
  // pixel that enters the WHOLE mixer, so a COLORKEY compare sees the MODULATED src
  // ("modulate source, then run the blend"). The per-pixel PALPHA alpha (pa_a4/a8)
  // is taken from the ORIGINAL fetched pixel and is NOT modulated.
  wire [15:0] raw_src = is_fill ? c_color : feed_src;
  wire [16:0] cm_pr   = {12'd0, raw_src[15:11]} * {9'd0, c_cmod_r};  // R5*8b (<=7905)
  wire [16:0] cm_pg   = {11'd0, raw_src[10:5]}  * {9'd0, c_cmod_g};  // G6*8b (<=16065)
  wire [16:0] cm_pb   = {12'd0, raw_src[4:0]}   * {9'd0, c_cmod_b};  // B5*8b (<=7905)

  // ════════════════════════════════════════════════════════════════════════════
  //  shared mem_* master — no longer used for the destination [FB-in-BRAM].
  //  The dest framebuffer lives in comp_fbram (fb_* ports); the band preload + the
  //  flush/write-back burst engine that used to drive mem_* are gone. Source pixels
  //  come through the cache-ok p0_* port. Tie mem_* idle (the port is dropped from
  //  comp_pipeline in a follow-up; kept here so blitter_top's wiring is unchanged).
  // ════════════════════════════════════════════════════════════════════════════
  assign mem_addr     = 32'd0;
  assign mem_rd       = 1'b0;
  assign mem_wr       = 1'b0;
  assign mem_burstcnt = 8'd0;
  assign mem_din      = 64'd0;
  assign mem_be       = 8'd0;
  // mem_dout / mem_dout_ready / mem_busy inputs are unused.

  // ════════════════════════════════════════════════════════════════════════════
  //  FSM
  // ════════════════════════════════════════════════════════════════════════════
  localparam [5:0]
    P_IDLE        = 6'd0,
    P_SPAN_COLL   = 6'd1,
    P_CHUNK_INIT  = 6'd2,
    P_COMP_SPAN   = 6'd5,
    P_SRCFILL_ISS = 6'd6,
    P_SRCFILL_WAIT= 6'd7,
    P_PIXEL       = 6'd8,
    P_DRAIN       = 6'd9,
    P_DONE        = 6'd14,
    P_CHUNK_RD    = 6'd17,    // registered span-record read (chunk advance bookkeeping)
    P_COMP_RD     = 6'd19,    // composite params + source-row multiply (registered)
    P_COMP_RD2    = 6'd20;    // gpix adds (split from the multiply for timing)
  reg [5:0] state;

  // ── span table (max FB_H=240 spans) ─────────────────────────────────────────
  localparam MAX_SPANS = 240;
  reg [15:0] sp_dst_x [0:MAX_SPANS-1];
  reg [15:0] sp_dst_y [0:MAX_SPANS-1];
  reg [15:0] sp_len   [0:MAX_SPANS-1];
  reg [15:0] sp_src_x0[0:MAX_SPANS-1];
  reg [15:0] sp_src_y [0:MAX_SPANS-1];
  reg [8:0]  span_count, span_wr;

  // ── chunk bookkeeping ────────────────────────────────────────────────────────
  // The chunk loop is retained as plain span grouping (≤BAND_H consecutive rows per
  // pass); with the dest in comp_fbram there is no per-chunk preload/flush, so a
  // chunk is now just "composite this group of spans straight into the FB".
  localparam [8:0] BAND_H = `COMP_BAND_H;        // 16
  reg [8:0]  chunk_first, chunk_nspan, chunk_si;
  reg [15:0] chunk_base_y;

  // span-table single registered READ port. The FSM used to index sp_*[chunk_first+i]
  // combinationally at ~26 sites, forcing the 5 tables into logic (uninferred RAM +
  // 240:1 read muxes). Route every read through one combinational address (sp_ra_c)
  // feeding registered fields (sp_q_*) so the tables infer as simple-dual-port BRAM;
  // each consumer presents the index one cycle ahead via a P_*_RD state (span setup
  // is not the per-pixel bottleneck). The write port (P_SPAN_COLL @ span_wr) is the
  // sole writer. Address mux + read block live after the FSM state decl.
  reg  [8:0]  sp_ra_c;                                             // comb read index
  reg  [15:0] sp_q_dst_x, sp_q_dst_y, sp_q_len, sp_q_src_x0, sp_q_src_y;

  // span-record read-address mux (combinational) + registered read. Each consuming
  // state presents its index; the following P_*_RD state uses sp_q_* one cycle later.
  always @* begin
    case (state)
      P_CHUNK_INIT: sp_ra_c = chunk_first;               // → chunk_base_y
      P_COMP_SPAN:  sp_ra_c = chunk_first + chunk_si;    // → composite params + gpix
      default:      sp_ra_c = chunk_first;
    endcase
  end
  always @(posedge clk) begin
    sp_q_dst_x  <= sp_dst_x [sp_ra_c];
    sp_q_dst_y  <= sp_dst_y [sp_ra_c];
    sp_q_len    <= sp_len   [sp_ra_c];
    sp_q_src_x0 <= sp_src_x0[sp_ra_c];
    sp_q_src_y  <= sp_src_y [sp_ra_c];
  end

  // ── per-span working registers ───────────────────────────────────────────────
  reg [15:0] cur_dst_x, cur_dst_y, cur_len, cur_src_x0, cur_src_y;
  reg  [3:0] cur_band_row;
  // global source-pixel addressing (heap-relative pixel index = byte>>1).
  reg [31:0] gpix0;                               // gpix of served pixel k=0
  reg [31:0] gpix_lo, gpix_hi;                    // inclusive gpix range of the span
  reg [31:0] fill_qw;                             // current SRC qword being filled

  // ── SDRAM source-fill bookkeeping (the sole source path: one P_SRC read per qword) ──
  // fill_qw = gpix_lo>>2 is the linebuf base qword; sf_idx walks 0..sf_nqw-1
  // landing each fetched qword at linebuf index sf_idx.
  reg [15:0] sf_idx, sf_nqw;

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

  // ── s3 colour-mod split stage (T+3) ───────────────────────────────────────────
  // The old FEED (T+2) registered the colour-mod PRODUCTS + every other mixer input
  // here; this stage does the /255 reduce + the actual mixer feed one cycle later, so
  // the multiply and the reduce sit in separate clock cycles (timing — see the tint
  // block above). All signals the mixer needs are carried through these registers so
  // they stay aligned with the (one-cycle-later) reduced source.
  reg        s3_valid, s3_skip, s3_colormod_en;
  reg [15:0] s3_cw_x;
  reg  [3:0] s3_cw_row;
  reg [16:0] s3_cm_pr, s3_cm_pg, s3_cm_pb;   // registered colour-mod products (T+2 mult)
  reg [15:0] s3_raw_src;                      // pre-mod source (colormod-off path)
  reg [15:0] s3_dst, s3_key;
  reg  [7:0] s3_mode, s3_fmt, s3_alpha;
  // /255 reduce of the registered products (T+3) — bit-identical to the old inline
  // reduction, just one cycle later. (255,255,255) ⇒ exact identity.
  wire [16:0] cm_tr_d = s3_cm_pr + 17'd128;
  wire [16:0] cm_tg_d = s3_cm_pg + 17'd128;
  wire [16:0] cm_tb_d = s3_cm_pb + 17'd128;
  wire [16:0] cm_dr_d = (cm_tr_d + (cm_tr_d >> 8)) >> 8;             // round(R5*cr/255)
  wire [16:0] cm_dg_d = (cm_tg_d + (cm_tg_d >> 8)) >> 8;             // round(G6*cg/255)
  wire [16:0] cm_db_d = (cm_tb_d + (cm_tb_d >> 8)) >> 8;             // round(B5*cb/255)
  wire [15:0] cmod_src_d     = {cm_dr_d[4:0], cm_dg_d[5:0], cm_db_d[4:0]};
  wire [15:0] src_to_mixer_d = s3_colormod_en ? cmod_src_d : s3_raw_src;

  localparam MIX_LAT = 3;
  reg [15:0] cwx_pipe [0:MIX_LAT];
  reg  [3:0] cwr_pipe [0:MIX_LAT];
  reg        cwv_pipe [0:MIX_LAT];
  integer    pp;
  // pipeline depth from last issue to last write-back: 3 (read + colour-mod mult +
  // reduce/feed) + MIX_LAT. The extra +1 vs the pre-pipelined design is the s3 stage.
  localparam [3:0] PIPE_DEPTH = 3 + MIX_LAT;
  reg [3:0]  drain_cnt;

  // source row base byte address for the current span (origin-y applied). Uses the
  // registered span-record read (sp_q_src_y), valid in P_COMP_RD. The 16x16 multiply
  // is registered into src_row_base_r in P_COMP_RD and the gpix adds happen the next
  // cycle (P_COMP_RD2) — splitting the multiply from the address adds keeps this off
  // the critical path (it was the worst setup path: span RAM -> mult -> gpix_lo).
  wire [31:0] src_row_base_q = c_src_off
            + (({16'd0, c_src_y} + {16'd0, sp_q_src_y})
                 * {16'd0, c_src_stride});
  reg  [31:0] src_row_base_r;   // registered src_row_base (post-multiply)

  // ── power-on state ────────────────────────────────────────────────────────────
  initial begin
    state       = P_IDLE;
    blit_done   = 1'b0; ss_start = 1'b0;
    lb_fill_we  = 1'b0; lb_serve_req = 1'b0;
    mx_in_valid = 1'b0; s1_valid = 1'b0; s2_valid = 1'b0; s3_valid = 1'b0;
    span_count  = 9'd0;
    p0_addr = 27'd0; p0_rd = 1'b0;
    fb_wr_en = 1'b0; fb_wr_qw = 15'd0; fb_wr_lane = 2'd0; fb_wr_pix = 16'd0;
    fb_rd_en = 1'b0; fb_rd_qw = 15'd0;
  end

  always @(posedge clk) begin
    if (rst) begin
      state <= P_IDLE;
      blit_done <= 1'b0; ss_start <= 1'b0;
      lb_fill_we <= 1'b0; lb_serve_req <= 1'b0;
      mx_in_valid <= 1'b0; s1_valid <= 1'b0; s2_valid <= 1'b0; s3_valid <= 1'b0;
      p0_rd <= 1'b0;
      fb_wr_en <= 1'b0; fb_rd_en <= 1'b0;
    end else begin
      // single-cycle strobe defaults
      ss_start     <= 1'b0;
      lb_fill_we   <= 1'b0;
      lb_serve_req <= 1'b0;
      mx_in_valid  <= 1'b0;
      blit_done    <= 1'b0;
      fb_wr_en     <= 1'b0;     // composite write is a one-cycle pulse
      fb_rd_en     <= 1'b0;     // dst RMW read is a one-cycle pulse

      case (state)

        // ─────────────────────────────────────────────────────────────────────
        P_IDLE: begin
          if (blit_start) begin
            ss_start   <= 1'b1;
            span_wr    <= 9'd0;
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
            // sp_ra_c (comb) = chunk_first this cycle → sp_q valid in P_CHUNK_RD
            state        <= P_CHUNK_RD;
          end
        end

        // chunk_base_y from the registered span read (sp_q_dst_y = sp_dst_y[chunk_first]).
        // [FB-in-BRAM] No band preload: the dest already lives in comp_fbram. Go straight
        // to compositing the chunk's spans (chunk_base_y kept only for the band_row
        // sanity invariant in P_COMP_RD; fb addressing uses the absolute cur_dst_y).
        P_CHUNK_RD: begin
          chunk_base_y <= sp_q_dst_y;
          chunk_si     <= 9'd0;
          state        <= P_COMP_SPAN;
        end

        // ─────────────────────────────────────────────────────────────────────
        // COMPOSITE one span: latch params + compute the source-x fill window. When the
        // chunk's spans are all composited, advance to the next chunk (no flush — the
        // composited pixels are already resident in comp_fbram).
        P_COMP_SPAN: begin
          if (chunk_si >= chunk_nspan) begin
            chunk_first <= chunk_first + chunk_nspan;
            state       <= P_CHUNK_INIT;
          end else begin
            // sp_ra_c (comb) = chunk_first+chunk_si → sp_q valid in P_COMP_RD
            state <= P_COMP_RD;
          end
        end

        // COMPOSITE one span: latch params + compute the source-x fill window, all
        // from the registered span read (record at chunk_first+chunk_si).
        P_COMP_RD: begin
            cur_dst_x    <= sp_q_dst_x;
            cur_dst_y    <= sp_q_dst_y;
            cur_len      <= sp_q_len;
            cur_src_x0   <= sp_q_src_x0;
            cur_src_y    <= sp_q_src_y;
            cur_band_row <= (sp_q_dst_y - chunk_base_y);
            // synthesis translate_off
            // Linchpin invariant: cw_row/rd_row are 4-bit; a chunk's spans MUST be
            // consecutive rows so (dst_y - chunk_base_y) stays within [0, BAND_H-1].
            if ((sp_q_dst_y - chunk_base_y) > (BAND_H - 9'd1))
              $display("FAIL: band_row %0d out of range (chunk spans not consecutive rows)",
                       sp_q_dst_y - chunk_base_y);
            // synthesis translate_on
            if (is_fill) begin
              pix_k     <= 16'd0;
              pix_total <= sp_q_len;
              state     <= P_PIXEL;
            end else begin
              // Register the source-row base (the 16x16 multiply result); the gpix
              // address adds run next cycle in P_COMP_RD2 off cur_src_x0/cur_len.
              src_row_base_r <= src_row_base_q;
              state          <= P_COMP_RD2;
            end
        end

        // GLOBAL-PIXEL source addressing (robust to stride<8 / non-qword-aligned
        // rows — mirrors the legacy FSM's absolute byte cursor):
        //   gpix(k) = (src_row_base>>1) + c_src_x + src_x0  ± k   (hflip = -k)
        //   P_SRC qword byte addr = (gpix>>2)<<3;  linebuf index = gpix-((gpix_lo>>2)<<2)
        // Driven from the registered src_row_base_r + cur_src_x0/cur_len (latched in
        // P_COMP_RD) so only the adds — not the multiply — are on this cycle's path.
        P_COMP_RD2: begin
          gpix0 <= (src_row_base_r >> 1)
                   + {16'd0, c_src_x} + {16'd0, cur_src_x0};
          if (c_flags & F_HFLIP) begin
            gpix_lo <= (src_row_base_r >> 1) + {16'd0, c_src_x}
                       + {16'd0, cur_src_x0}
                       - ({16'd0, cur_len} - 32'd1);
            gpix_hi <= (src_row_base_r >> 1) + {16'd0, c_src_x}
                       + {16'd0, cur_src_x0};
            fill_qw <= ((src_row_base_r >> 1) + {16'd0, c_src_x}
                       + {16'd0, cur_src_x0}
                       - ({16'd0, cur_len} - 32'd1)) >> 2;
          end else begin
            gpix_lo <= (src_row_base_r >> 1) + {16'd0, c_src_x}
                       + {16'd0, cur_src_x0};
            gpix_hi <= (src_row_base_r >> 1) + {16'd0, c_src_x}
                       + {16'd0, cur_src_x0}
                       + ({16'd0, cur_len} - 32'd1);
            fill_qw <= ((src_row_base_r >> 1) + {16'd0, c_src_x}
                       + {16'd0, cur_src_x0}) >> 2;
          end
          state <= P_SRCFILL_ISS;
        end

        // ─────────────────────────────────────────────────────────────────────
        // SOURCE FILL — walk the contiguous SRC qword range [gpix_lo>>2 .. gpix_hi>>2]
        // through the P_SRC (SDRAM) cache-ok port; beat i lands at linebuf qword
        // index i (linebuf base = gpix_lo>>2, matching the serve_x subtraction in
        // P_PIXEL). [collapse-single-source] This is now the ONLY source path — the
        // former DDR3 live-source branch (cb_*/SRC_QW under c_srcsel=0) was removed.
        P_SRCFILL_ISS: begin
          // P_SRC cache-ok (Task 5): walk the contiguous qword range one read at a
          // time. fill_qw = gpix_lo>>2 (the linebuf base); byte addr = qw<<3.
          // Pulse p0_rd for exactly one cycle with p0_addr; p0_ok returns data.
          sf_idx   <= 16'd0;
          sf_nqw   <= 16'(((gpix_hi >> 2) - (gpix_lo >> 2)) + 32'd1);
          p0_addr  <= 27'(fill_qw << 3);
          p0_rd    <= 1'b1;               // one-cycle read pulse
          state    <= P_SRCFILL_WAIT;
        end

        P_SRCFILL_WAIT: begin
          // Cache-ok protocol: p0_rd was pulsed last cycle; deassert it now.
          // Capture the returned beat into the linebuf on p0_ok; then issue the
          // next qword (another single p0_rd pulse) until the whole
          // [gpix_lo>>2 .. gpix_hi>>2] run is in.
          p0_rd <= 1'b0;        // deassert after the one-cycle pulse
          if (p0_ok) begin
            lb_fill_we  <= 1'b1;
            lb_fill_qw  <= p0_dout;
            lb_fill_idx <= 10'(sf_idx);          // beat i -> linebuf qword i
            if ((sf_idx + 16'd1) >= sf_nqw) begin
              pix_k     <= 16'd0;
              pix_total <= cur_len;
              state     <= P_PIXEL;
            end else begin
              sf_idx  <= sf_idx + 16'd1;
              p0_addr <= 27'((fill_qw + {16'd0, sf_idx} + 32'd1) << 3);
              p0_rd   <= 1'b1;            // pulse for next qword
            end
          end
        end

        // ─────────────────────────────────────────────────────────────────────
        // PER-PIXEL COMPOSITE. [FB-in-BRAM] The dest RMW pixel comes from comp_fbram
        // (fb_rd_*); the composited result is written back to comp_fbram (fb_wr_*).
        //   T   : ISSUE   — pulse fb_rd_* (dst qword) / serve_x / serve_req (s1)
        //   T+1 : reads in flight                                          (s2)
        //   T+2 : FEED    — fb_rd_qword/serve_pix valid as regs → mixer in
        //   T+2+LAT : mixer out → fb_wr_* into comp_fbram
        // fb_rd has the same 1-cycle read latency as the old band read, and fb_rd_en/
        // fb_rd_qw are registered at ISSUE exactly like db_rd_x was, so fb_rd_qword is
        // valid at T+2 when sampled into s3_dst — the lane is selected by s2_cw_x[1:0]
        // (which carries this pixel's dst x two cycles later, aligned with the read).
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
            // dst RMW read of comp_fbram: qword = cur_dst_y*80 + (x>>2). The whole
            // qword (4 lanes) returns; the pixel's lane is selected at FEED.
            fb_rd_en  <= 1'b1;
            fb_rd_qw  <= 15'(cur_dst_y * 16'd80 + ((cur_dst_x + pix_k) >> 16'd2));
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

          // ── s2 → s3: register colour-mod PRODUCTS + every mixer input (T+2) ──
          // rd_dst (db_rd_dst) and serve_pix (lb_serve_pix, via cm_p*/raw_src) are
          // valid THIS cycle. We capture the colour-mod MULTIPLY result + the PALPHA-
          // resolved mode/alpha/skip/src here; the /255 reduce + the actual mixer feed
          // happen one cycle later (s3, T+3), splitting mult from reduce for fmax.
          s3_valid       <= s2_valid;
          s3_cw_x        <= s2_cw_x;
          s3_cw_row      <= s2_cw_row;
          s3_cm_pr       <= cm_pr;
          s3_cm_pg       <= cm_pg;
          s3_cm_pb       <= cm_pb;
          s3_raw_src     <= raw_src;
          s3_colormod_en <= colormod_en;
          // dst RMW pixel: lane-select this pixel's lane from the comp_fbram qword read.
          // s2_cw_x carries the dst x of the pixel whose read is valid this cycle.
          s3_dst         <= fb_rd_qword[s2_cw_x[1:0]*16 +: 16];
          s3_mode        <= feed_mode;
          s3_fmt         <= c_format;
          s3_key         <= c_colorkey;
          s3_alpha       <= feed_alpha;
          s3_skip        <= feed_skip;

          // ── FEED MIXER (s3: reduced colour-mod source ready, T+3) ──
          // PALPHA bit-exactness: comp_mixer's COMP_PA uses the RGB565 channel split
          // (no ARGB4444 4->5/6/5 expansion), so the source was EXPANDED to RGB565 +
          // COMP_CA at s2; here we drive the registered values. The colour-mod source
          // (src_to_mixer_d) is the /255-reduced registered product this cycle. A4==0
          // (fully transparent) pixels are skipped via the cw write gate (s3_skip).
          if (s3_valid) begin
            mx_in_valid <= 1'b1;
            mx_in_src   <= src_to_mixer_d;   // [v2] colour-modulated source, reduced this cycle
            mx_in_dst   <= s3_dst;
            mx_in_mode  <= s3_mode;
            mx_in_fmt   <= s3_fmt;
            mx_in_key   <= s3_key;
            mx_in_alpha <= s3_alpha;
          end

          // ── cw coordinate shadow pipeline (seeded at the s3 mixer-feed cycle) ──
          // cwv gates the write-back; fold the PALPHA A4==0 skip in here so a
          // fully-transparent pixel never writes (COMP_CA's out_we is always 1).
          cwx_pipe[0] <= s3_cw_x;
          cwr_pipe[0] <= s3_cw_row;
          cwv_pipe[0] <= s3_valid && !s3_skip;
          for (pp = 1; pp <= MIX_LAT; pp = pp + 1) begin
            cwx_pipe[pp] <= cwx_pipe[pp-1];
            cwr_pipe[pp] <= cwr_pipe[pp-1];
            cwv_pipe[pp] <= cwv_pipe[pp-1];
          end

          // ── WRITE-BACK into comp_fbram ──
          // qword = cur_dst_y*80 + (x>>2), lane = x[1:0]. cur_dst_y is constant for the
          // whole span (one span = one dst row), so the in-flight write-back pixels all
          // belong to this row — no need to pipe dst_y.
          if (mx_out_valid && cwv_pipe[MIX_LAT] && mx_out_we) begin
            fb_wr_en   <= 1'b1;
            fb_wr_qw   <= 15'(cur_dst_y * 16'd80 + (cwx_pipe[MIX_LAT] >> 16'd2));
            fb_wr_lane <= cwx_pipe[MIX_LAT][1:0];
            fb_wr_pix  <= mx_out_pix;
          end

          if (pix_k >= pix_total && !s1_valid && !s2_valid && !s3_valid) begin
            drain_cnt <= PIPE_DEPTH;
            state     <= P_DRAIN;
          end
        end

        // Drain serve→feed→mixer after the last issue.
        P_DRAIN: begin
          s2_valid    <= 1'b0;
          s3_valid    <= 1'b0;
          cwx_pipe[0] <= 16'd0;
          cwr_pipe[0] <= 4'd0;
          cwv_pipe[0] <= 1'b0;
          for (pp = 1; pp <= MIX_LAT; pp = pp + 1) begin
            cwx_pipe[pp] <= cwx_pipe[pp-1];
            cwr_pipe[pp] <= cwr_pipe[pp-1];
            cwv_pipe[pp] <= cwv_pipe[pp-1];
          end
          if (mx_out_valid && cwv_pipe[MIX_LAT] && mx_out_we) begin
            fb_wr_en   <= 1'b1;
            fb_wr_qw   <= 15'(cur_dst_y * 16'd80 + (cwx_pipe[MIX_LAT] >> 16'd2));
            fb_wr_lane <= cwx_pipe[MIX_LAT][1:0];
            fb_wr_pix  <= mx_out_pix;
          end
          if (drain_cnt == 4'd0) begin
            chunk_si <= chunk_si + 9'd1;
            state    <= P_COMP_SPAN;
          end else begin
            drain_cnt <= drain_cnt - 4'd1;
          end
        end

        // ─────────────────────────────────────────────────────────────────────
        P_DONE: begin
          blit_done <= 1'b1;
          state     <= P_IDLE;
        end

        default: state <= P_IDLE;

      endcase
    end
  end

endmodule
`default_nettype wire
