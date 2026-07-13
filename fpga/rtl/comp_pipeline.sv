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
`include "comp_clut.vh"

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
  // [PAL8 v1, Task 1.2] per-blit palette selector + CLUT index base offset, and
  // the CLUT lookup port. The registered clut_bram read lives in blitter_top;
  // clut_rd_addr is driven COMBINATIONALLY here from the served index (valid at
  // the s2/FEED cycle, T+2) so clut_rd_data lands registered at T+3 — exactly
  // when the s3 stage holds the same pixel (see the s3 CLUT-decode block below).
  input  wire  [4:0] c_pal_id,       // [PAL8 v1.1] 5 bits -> 32 CLUT banks
  input  wire  [7:0] c_base_off,
  output wire [12:0] clut_rd_addr,    // [PAL8 v1.1] 5-bit bank + 8-bit slot = 8192 entries
  input  wire [31:0] clut_rd_data,
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
  wire is_pal8      = (c_format == `COMP_PAL8);      // [PAL8 v1, Task 1.2]

  // ════════════════════════════════════════════════════════════════════════════
  //  sub-module wiring
  // ════════════════════════════════════════════════════════════════════════════

  // ---- comp_span_setup ----
  reg         ss_start;
  wire        ss_span_valid;
  wire [15:0] ss_span_dst_x, ss_span_dst_y, ss_span_len, ss_span_src_x0, ss_span_src_y;
  wire        ss_span_last, ss_done;

  comp_span_setup u_span (
    .clk(clk), .rst(rst), .start(ss_start),   // [#110] reset u_span in lockstep with the pipeline
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

  // [Task 3] ping-pong bank selects: the prefetch sub-FSM fills fill_bank_sel
  // while P_PIXEL serves serve_bank. In 3a serve_bank is held 0 (single bank);
  // 3b toggles it per span; 3c overlaps fill(N+1) under composite(N).
  reg        serve_bank;        // bank the composite reads (main FSM)
  reg        fill_bank_sel;     // bank the prefetch fills   (main FSM request)

  comp_src_linebuf u_linebuf (
    .clk(clk),
    .fill_we(lb_fill_we), .fill_qw(lb_fill_qw), .fill_idx(lb_fill_idx),
    .fill_bank(fill_bank_sel),              // [Task 3] prefetch target bank
    .serve_req(lb_serve_req), .serve_x(lb_serve_x),
    .serve_w(16'd0), .serve_hflip(1'b0),   // hflip handled in serve_x walk (see header)
    .serve_bank(serve_bank),                // [Task 3] composite source bank
    .serve_valid(lb_serve_valid), .serve_pix(lb_serve_pix)
  );

  // [PAL8 v1, Task 1.2] CLUT read address, driven COMBINATIONALLY from the served
  // index (lb_serve_pix, valid at the s2/FEED cycle T+2). The registered clut_bram
  // read in blitter_top makes clut_rd_data valid at T+3 — aligned with the s3 stage
  // holding the SAME pixel (see the s3 CLUT-decode block near src_to_mixer_d). For
  // non-PAL8 blits this reads an ignored entry — harmless.
  assign clut_rd_addr = {c_pal_id[4:0], (lb_serve_pix[7:0] + c_base_off)};

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
  // [const-alpha fill] CONST_ALPHA (BLEND_ALPHA) is likewise honoured for BOTH
  // blit AND fill — checked BEFORE the is_fill→COPY fallback. A FILL with
  // BLEND_ALPHA blends src=c_color into the FB pixel by c_alpha (raw_src=c_color
  // and feed_alpha=c_alpha are already wired below), so a colored fade's
  // translucent overlay composites correctly instead of writing opaque colour
  // (the "extra black frames" fix). Other fills stay a plain COPY; blits unchanged.
  wire [7:0] mix_mode = is_add                    ? `COMP_ADD  :
                        is_mul                    ? `COMP_MUL  :
                        (c_blend == BLEND_ALPHA)  ? `COMP_CA   :
                        is_fill                   ? `COMP_COPY :
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
  // [#100] Decode ARGB4444 for ALL blend modes, not just PALPHA. comp_mixer treats its
  // src as RGB565 {R5,G6,B5}; an ARGB4444 source ({A4,R4,G4,B4}) MUST be expanded 4->
  // 5/6/5 before it reaches the mixer or COPY/KEY/ADD/MULTIPLY (and ARGB4444 FILL) mangle
  // the colour and a KEY compare runs against the wrong bits. Previously only b_palpha
  // expanded it. The expansion (pa_expanded) drops A4 — correct for these modes (A4 is
  // used only by PALPHA, which additionally routes COMP_CA + pa_a8 below). This obsoletes
  // the pre-fix "ARGB4444 => PALPHA" invariant (#97): ARGB4444 is now legal in any mode.
  wire        is_argb4444 = (c_format == 8'd1);   // FMT_RGB565=0, FMT_ARGB4444=1
  // mixer-feed selects (PALPHA → expanded src + COMP_CA + a8; ARGB4444/other → expanded
  // src + native mode/alpha; RGB565 → pass-through)
  wire [15:0] feed_src   = (b_palpha || is_argb4444) ? pa_expanded : lb_serve_pix;
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
  // [#100] an ARGB4444 FILL carries {A4,R4,G4,B4} in c_color — expand it 4->5/6/5 too
  // (same layout as pa_expanded) so the mixer/colour-mod see real RGB565.
  wire [15:0] c_color_exp = { c_color[11:8], c_color[11],       // R5
                              c_color[7:4],  c_color[7:6],      // G6
                              c_color[3:0],  c_color[3] };      // B5
  wire [15:0] fill_src = is_argb4444 ? c_color_exp : c_color;
  wire [15:0] raw_src = is_fill ? fill_src : feed_src;
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
    P_COMP_SPAN   = 6'd5,     // FILL-only per-span loop (no source fetch)
    P_PRO_WAIT    = 6'd6,     // [Task 3c] prologue: wait span-0 fill before compositing
    P_PIXEL       = 6'd8,
    P_DRAIN       = 6'd9,
    P_DONE        = 6'd14,
    P_CHUNK_RD    = 6'd17,    // registered span-record read (chunk advance bookkeeping)
    P_COMP_RD     = 6'd19,    // FILL-only: latch params (registered span read)
    // [Task 3c] decoupled-prefetch / overlap states (source blits):
    P_SPAN_BEGIN  = 6'd21,    // decide: decode span N+1 (overlap) or composite last span
    P_DEC_RD      = 6'd22,    // decode a span record -> pend + src-row multiply
    P_DEC_RD2     = 6'd23,    // gpix range -> fill_lo/hi + pend; kick the prefetch
    P_ADVANCE     = 6'd24;    // post-drain: wait !prefetch_busy, promote pend->serve
  reg [5:0] state;

  // ── span table (max FB_H=240 spans) ─────────────────────────────────────────
  // Explicit ramstyle (lower-priority hardening alongside the Task 3
  // LAB-overflow root-cause fix in comp_src_linebuf.sv, same AUTO-inference-
  // fragility class -- these arrays fit clean in the failing build but were
  // flagged as an exposed risk of the same nature, not a confirmed second
  // trigger): don't rely on Quartus's AUTO inference heuristic for these
  // either.
  localparam MAX_SPANS = 240;
  (* ramstyle = "no_rw_check, M10K" *) reg [15:0] sp_dst_x [0:MAX_SPANS-1];
  (* ramstyle = "no_rw_check, M10K" *) reg [15:0] sp_dst_y [0:MAX_SPANS-1];
  (* ramstyle = "no_rw_check, M10K" *) reg [15:0] sp_len   [0:MAX_SPANS-1];
  (* ramstyle = "no_rw_check, M10K" *) reg [15:0] sp_src_x0[0:MAX_SPANS-1];
  (* ramstyle = "no_rw_check, M10K" *) reg [15:0] sp_src_y [0:MAX_SPANS-1];
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
      P_CHUNK_INIT: sp_ra_c = chunk_first;                     // → chunk_base_y
      P_CHUNK_RD:   sp_ra_c = chunk_first;                     // → span 0 (prologue decode)
      P_COMP_SPAN:  sp_ra_c = chunk_first + chunk_si;          // FILL: composite params
      P_SPAN_BEGIN: sp_ra_c = chunk_first + chunk_si + 9'd1;   // → span N+1 (overlap decode)
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

  // ── per-span working ("serve") registers — the span currently compositing ──────
  reg [15:0] cur_dst_x, cur_dst_y, cur_len, cur_src_x0, cur_src_y;
  reg  [3:0] cur_band_row;
  // global source-pixel addressing (heap-relative pixel index = byte>>1).
  reg [31:0] gpix0;                               // gpix of served pixel k=0
  reg [31:0] gpix_lo;                             // low gpix of the span (serve base)

  // ── [Task 3c] "pending" (decoded-ahead) span registers ─────────────────────────
  // The overlap decodes span N+1 while span N composites. Its serve params land in
  // pend_* (+ pend_bank = the bank its prefetch filled); when it becomes the current
  // span they are promoted into the cur_*/gpix*/serve_bank registers. dec_src_x0/
  // dec_len carry the decoded span's source-x origin + length from P_DEC_RD into the
  // gpix-range math in P_DEC_RD2 (mirrors the old cur_src_x0/cur_len use there).
  reg [15:0] pend_dst_x, pend_dst_y, pend_len;
  reg  [3:0] pend_band_row;
  reg [31:0] pend_gpix0, pend_gpix_lo;
  reg        pend_bank;
  reg [15:0] dec_src_x0, dec_len;
  reg        pf_prologue;     // the in-flight decode is the chunk's first span (span 0)
  reg        next_valid;      // a span N+1 was decoded+prefetched during this composite

  // ── SDRAM source-fill bookkeeping (the sole source path: one P_SRC read per qword) ──
  // fill_qw = gpix_lo>>2 is the linebuf base qword; sf_idx walks 0..sf_nqw-1
  // landing each fetched qword at linebuf index sf_idx. sf_idx/sf_nqw are now
  // driven by the prefetch sub-FSM (below), not the main FSM.
  reg [15:0] sf_idx, sf_nqw;

  // ════════════════════════════════════════════════════════════════════════════
  //  [Task 3] source-fill PREFETCH sub-FSM — decoupled from the main FSM.
  //  Owns the P_SRC walk (p0_addr/p0_rd) and the linebuf fill writes
  //  (lb_fill_we/lb_fill_qw/lb_fill_idx) plus sf_idx/sf_nqw. The main FSM kicks it
  //  with a one-cycle fill_start + a {fill_lo,fill_hi,fill_bank_sel} request; the
  //  sub-FSM walks the contiguous qword range [fill_lo>>2 .. fill_hi>>2] into the
  //  selected linebuf bank (one P_SRC read per qword), raising prefetch_busy until
  //  the last qword lands.
  //
  //  Cycle-exactness vs the old in-line P_SRCFILL_ISS/WAIT: the kick is pulsed in
  //  P_COMP_RD2 (high the next cycle), and the issue (first p0_rd) is folded INTO
  //  the F_IDLE kick-branch — i.e. it fires the same cycle the old P_SRCFILL_ISS
  //  did (one cycle after P_COMP_RD2). prefetch_last is a combinational "final beat
  //  this cycle" strobe so the main FSM transitions to P_PIXEL on the exact same
  //  cycle the old P_SRCFILL_WAIT did (no added per-span cycle). Two states suffice
  //  (idle / walk); a separate F_ISS issue state would push the first read one cycle
  //  late and change cyc/px.
  // [PAL8 v1, Task 3.1] source-qword byte address for a given LINEBUF-qword index lbq.
  // 16bpp: source qword == linebuf qword (1:1). PAL8: source is staged 8bpp, so 2
  // linebuf qwords (8 px each side, 4 px/qword) share ONE source qword (8 idx bytes) —
  // source qword = lbq>>1 (low half then high half; see Change 3's fill_half/pal8_lanes).
  function [26:0] src_byte_addr; input [31:0] lbq; input pal8;
    src_byte_addr = pal8 ? 27'((lbq >> 1) << 3) : 27'(lbq << 3);
  endfunction

  localparam [1:0] F_IDLE = 2'd0, F_WALK = 2'd1;
  reg [1:0]  fstate;
  reg        prefetch_busy;
  reg [31:0] f_fill_qw;                 // sub-FSM base qword (= fill_lo>>2)
  // request record from the main FSM (kick):
  reg        fill_start;                // one-cycle kick
  reg [31:0] fill_lo, fill_hi;          // inclusive gpix range to fill
  // combinational "the final beat lands THIS cycle" (main FSM advance trigger):
  wire prefetch_last = (fstate == F_WALK) && p0_ok
                       && ((sf_idx + 16'd1) >= sf_nqw);

  // [PAL8 v1, Task 3.1] fill data unpack: for PAL8, one fetched source qword holds 8
  // index bytes that feed TWO linebuf qwords (Change 2's shared source-qword read).
  // fill_half selects which 4-byte half of p0_dout belongs to the linebuf qword being
  // written this beat (parity of the linebuf-qword index); pal8_lanes zero-extends
  // each of those 4 index bytes into a 16-bit linebuf lane (lane j = bits[16*j+:16],
  // lane 0 = lowest-gpix pixel — matches comp_src_linebuf's serve_pix lane layout).
  // Only consumed inside F_WALK's `if (p0_ok)` fill write below; f_fill_qw/sf_idx are
  // valid there (F_WALK regs) and p0_dout is valid there (p0_ok-qualified read data).
  wire        fill_half  = (f_fill_qw + {16'd0, sf_idx}) & 32'd1;   // 0=low 4B, 1=high 4B
  wire [63:0] pal8_lanes = fill_half
      ? { 8'd0, p0_dout[63:56], 8'd0, p0_dout[55:48], 8'd0, p0_dout[47:40], 8'd0, p0_dout[39:32] }
      : { 8'd0, p0_dout[31:24], 8'd0, p0_dout[23:16], 8'd0, p0_dout[15:8],  8'd0, p0_dout[7:0]  };

  always @(posedge clk) begin
    if (rst) begin
      fstate        <= F_IDLE;
      prefetch_busy <= 1'b0;
      p0_rd         <= 1'b0;
      lb_fill_we    <= 1'b0;
    end else begin
      lb_fill_we <= 1'b0;               // one-cycle linebuf write strobe default
      case (fstate)
        F_IDLE: begin
          p0_rd <= 1'b0;
          if (fill_start) begin
            // ISSUE the first qword (folded here for cycle-exactness — see above).
            prefetch_busy <= 1'b1;
            sf_idx        <= 16'd0;
            sf_nqw        <= 16'(((fill_hi >> 2) - (fill_lo >> 2)) + 32'd1);
            f_fill_qw     <= (fill_lo >> 2);
            p0_addr       <= src_byte_addr(fill_lo >> 2, is_pal8);
            p0_rd         <= 1'b1;       // one-cycle read pulse
            fstate        <= F_WALK;
          end
        end
        F_WALK: begin
          p0_rd <= 1'b0;                // deassert after the one-cycle pulse
          if (p0_ok) begin
            lb_fill_we  <= 1'b1;
            lb_fill_qw  <= is_pal8 ? pal8_lanes : p0_dout;
            lb_fill_idx <= 10'(sf_idx);          // beat i -> linebuf qword i
            if ((sf_idx + 16'd1) >= sf_nqw) begin
              prefetch_busy <= 1'b0;
              fstate        <= F_IDLE;
            end else begin
              sf_idx  <= sf_idx + 16'd1;
              p0_addr <= src_byte_addr(f_fill_qw + {16'd0, sf_idx} + 32'd1, is_pal8);
              p0_rd   <= 1'b1;            // pulse for next qword
            end
          end
        end
        default: fstate <= F_IDLE;
      endcase
    end
  end

`ifdef FABRIC_ASSERT
  // [#110 SVA] The prefetch assumes ONE read outstanding with a strict 1-cycle p0_ok:
  // it advances sf_idx / the source qword index on every p0_ok while in F_WALK. A p0_ok
  // that arrives with NO read outstanding (fstate==F_IDLE) would be a spurious ack the
  // walker isn't expecting -> a mis-advance / stale source index. Assert p0_ok is gated
  // by an outstanding read. (Metastability aside, this catches a P_SRC-model contract
  // break: ok without a preceding rd.)
  always @(posedge clk) if (!rst)
    assert (!(p0_ok && fstate == F_IDLE))
    else $display("FABRIC-ASSERT FAIL [comp_pipeline]: p0_ok with no read outstanding (fstate=F_IDLE) @%0t -> prefetch mis-advance", $time);
`endif

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
  reg        s3_palpha;                       // [PAL8 v1] registered b_palpha (Task 1.2)
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
  // [PAL8 v1, Task 1.2] CLUT decode, combinational, valid at T+3 alongside s3 (the
  // clut_bram registered read in blitter_top lands the cycle after clut_rd_addr,
  // which was driven from lb_serve_pix at T+2 — see the clut_rd_addr assign above).
  // INLINED (not the `CLUT_RGB/`CLUT_A4 macros) for the same iverilog -y library-mode
  // macro-argument-mangling caveat comp_mixer.sv's stage C already documents for
  // `COMP_DIV255 (reproduced here too: the macro call arrived as `lut_rd_data`, its
  // first character stripped, "Unable to bind wire/reg/memory" at elaboration).
  // Semantics identical to the macro (CLUT_RGB(e)=e[15:0], CLUT_A4(e)=e[19:16]).
  wire [15:0] pal_rgb_s3 = clut_rd_data[15:0];
  wire  [3:0] pal_a4_s3  = clut_rd_data[19:16];
  // PAL8 bypasses colour-mod in v1 (tiles don't tint); the T+2 s3_raw_src/products
  // hold the raw index and are correctly IGNORED for PAL8.
  wire [15:0] src_to_mixer_d = (s3_fmt == `COMP_PAL8) ? pal_rgb_s3
                              : s3_colormod_en          ? cmod_src_d : s3_raw_src;
  // [PAL8 v1, Task 1.2] transparent-index skip override: for PAL8 the per-pixel skip
  // comes from the CLUT alpha (pal_a4_s3==0), gated by s3_palpha (blend==PALPHA) —
  // non-PALPHA PAL8 blends (COPY/COLORKEY/ADD/MULTIPLY) never skip on CLUT alpha.
  // Non-PAL8 formats keep the existing feed_skip-derived s3_skip unchanged.
  wire s3_skip_eff = (s3_fmt == `COMP_PAL8) ? (s3_palpha && (pal_a4_s3 == 4'd0)) : s3_skip;

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
  // [Task 3c] base gpix of the span being decoded (valid in P_DEC_RD2 off the
  // registered src_row_base_r + dec_src_x0 latched in P_DEC_RD):
  // [PAL8 v1, Task 3.1] src_row_base_r is a BYTE offset; the byte->pixel convert is
  // format-dependent: 16bpp source is 2 B/px (>>1), PAL8 source is staged 8bpp = 1 B/px
  // (>>0). c_src_x/dec_src_x0 are already pixel units.
  wire [31:0] dec_base = (src_row_base_r >> (is_pal8 ? 5'd0 : 5'd1))
                         + {16'd0, c_src_x} + {16'd0, dec_src_x0};

  // ── power-on state ────────────────────────────────────────────────────────────
  initial begin
    state       = P_IDLE;
    blit_done   = 1'b0; ss_start = 1'b0;
    lb_serve_req = 1'b0;
    mx_in_valid = 1'b0; s1_valid = 1'b0; s2_valid = 1'b0; s3_valid = 1'b0;
    span_count  = 9'd0;
    fb_wr_en = 1'b0; fb_wr_qw = 15'd0; fb_wr_lane = 2'd0; fb_wr_pix = 16'd0;
    fb_rd_en = 1'b0; fb_rd_qw = 15'd0;
    // [Task 3] prefetch handshake / bank selects
    fstate = F_IDLE; prefetch_busy = 1'b0;
    p0_addr = 27'd0; p0_rd = 1'b0;
    lb_fill_we = 1'b0; lb_fill_qw = 64'd0; lb_fill_idx = 10'd0;
    sf_idx = 16'd0; sf_nqw = 16'd0; f_fill_qw = 32'd0;
    fill_start = 1'b0; fill_lo = 32'd0; fill_hi = 32'd0;
    serve_bank = 1'b0; fill_bank_sel = 1'b0;
    pf_prologue = 1'b0; next_valid = 1'b0; pend_bank = 1'b0;
  end

  always @(posedge clk) begin
    if (rst) begin
      state <= P_IDLE;
      blit_done <= 1'b0; ss_start <= 1'b0;
      lb_serve_req <= 1'b0;
      mx_in_valid <= 1'b0; s1_valid <= 1'b0; s2_valid <= 1'b0; s3_valid <= 1'b0;
      fb_wr_en <= 1'b0; fb_rd_en <= 1'b0;
      fill_start <= 1'b0;     // [Task 3] no kick on reset
    end else begin
      // single-cycle strobe defaults
      ss_start     <= 1'b0;
      lb_serve_req <= 1'b0;
      mx_in_valid  <= 1'b0;
      blit_done    <= 1'b0;
      fb_wr_en     <= 1'b0;     // composite write is a one-cycle pulse
      fb_rd_en     <= 1'b0;     // dst RMW read is a one-cycle pulse
      fill_start   <= 1'b0;     // [Task 3] prefetch kick is a one-cycle pulse

      case (state)

        // ─────────────────────────────────────────────────────────────────────
        P_IDLE: begin
          if (blit_start) begin
            ss_start   <= 1'b1;
            span_wr    <= 9'd0;
            serve_bank <= 1'b0;     // [Task 3b] start each blit on bank 0
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
          if (is_fill) begin
            // FILL blits have no source fetch → the simple per-span loop.
            state <= P_COMP_SPAN;
          end else begin
            // [Task 3c] SOURCE blits: prologue — decode span 0 and fill ITS bank
            // before compositing (no prior prefetch exists). sp_ra_c (comb, this
            // state) = chunk_first → sp_q (span 0) is valid in P_DEC_RD.
            pf_prologue <= 1'b1;
            next_valid  <= 1'b0;
            state       <= P_DEC_RD;
          end
        end

        // ─────────────────────────────────────────────────────────────────────
        // FILL per-span loop (is_fill only — no source). When the chunk's spans are
        // all composited, advance to the next chunk.
        P_COMP_SPAN: begin
          if (chunk_si >= chunk_nspan) begin
            chunk_first <= chunk_first + chunk_nspan;
            state       <= P_CHUNK_INIT;
          end else begin
            // sp_ra_c (comb) = chunk_first+chunk_si → sp_q valid in P_COMP_RD
            state <= P_COMP_RD;
          end
        end

        // FILL: latch composite params from the registered span read; no prefetch.
        P_COMP_RD: begin
            cur_dst_x    <= sp_q_dst_x;
            cur_dst_y    <= sp_q_dst_y;
            cur_len      <= sp_q_len;
            cur_src_x0   <= sp_q_src_x0;
            cur_src_y    <= sp_q_src_y;
            cur_band_row <= (sp_q_dst_y - chunk_base_y);
            // synthesis translate_off
            if ((sp_q_dst_y - chunk_base_y) > (BAND_H - 9'd1))
              $display("FAIL: band_row %0d out of range (chunk spans not consecutive rows)",
                       sp_q_dst_y - chunk_base_y);
            if (!is_fill)
              $display("FAIL: source span reached the FILL-only P_COMP_RD path");
            // synthesis translate_on
            pix_k     <= 16'd0;
            pix_total <= sp_q_len;
            state     <= P_PIXEL;
        end

        // ─────────────────────────────────────────────────────────────────────
        // [Task 3c] SOURCE overlap path.
        //
        // P_SPAN_BEGIN — about to composite the span now in the serve registers.
        // If a span N+1 exists, decode it (into pend_*) and kick its prefetch into
        // the OTHER bank so the fill overlaps this span's composite; otherwise this
        // is the chunk's last span → composite it with no prefetch.
        P_SPAN_BEGIN: begin
          if ((chunk_si + 9'd1) < chunk_nspan) begin
            next_valid  <= 1'b1;
            pf_prologue <= 1'b0;
            // sp_ra_c (comb, this state) = chunk_first+chunk_si+1 → sp_q valid in P_DEC_RD
            state <= P_DEC_RD;
          end else begin
            next_valid <= 1'b0;
            pix_k      <= 16'd0;
            pix_total  <= cur_len;             // composite the current (serve) span
            state      <= P_PIXEL;
          end
        end

        // P_DEC_RD — decode the span at sp_q into the pending registers; register the
        // source-row base (the 16x16 multiply). Used for span 0 (prologue) and for
        // each span N+1 (overlap). Does NOT touch the serve registers (cur_*/gpix*),
        // so an in-progress composite of span N keeps its state.
        P_DEC_RD: begin
          pend_dst_x    <= sp_q_dst_x;
          pend_dst_y    <= sp_q_dst_y;
          pend_len      <= sp_q_len;
          pend_band_row <= (sp_q_dst_y - chunk_base_y);
          dec_src_x0    <= sp_q_src_x0;
          dec_len       <= sp_q_len;
          src_row_base_r <= src_row_base_q;
          // synthesis translate_off
          if ((sp_q_dst_y - chunk_base_y) > (BAND_H - 9'd1))
            $display("FAIL: band_row %0d out of range (chunk spans not consecutive rows)",
                     sp_q_dst_y - chunk_base_y);
          // synthesis translate_on
          state <= P_DEC_RD2;
        end

        // P_DEC_RD2 — gpix range of the decoded span → fill_lo/fill_hi (+ pend serve
        // addressing), then KICK the prefetch into the proper bank:
        //   prologue → fill the bank span 0 will serve (= serve_bank)
        //   overlap  → fill the OTHER bank (~serve_bank); promoted to serve next span
        // Mirrors the old P_COMP_RD2 gpix math exactly (dec_src_x0/dec_len instead of
        // cur_src_x0/cur_len). After the kick: prologue waits for the fill, while the
        // overlap path drops straight into compositing the CURRENT (serve) span.
        P_DEC_RD2: begin
          pend_gpix0 <= dec_base;
          if (c_flags & F_HFLIP) begin
            fill_lo      <= dec_base - ({16'd0, dec_len} - 32'd1);
            fill_hi      <= dec_base;
            pend_gpix_lo <= dec_base - ({16'd0, dec_len} - 32'd1);
          end else begin
            fill_lo      <= dec_base;
            fill_hi      <= dec_base + ({16'd0, dec_len} - 32'd1);
            pend_gpix_lo <= dec_base;
          end
          fill_bank_sel <= pf_prologue ? serve_bank : ~serve_bank;
          pend_bank     <= pf_prologue ? serve_bank : ~serve_bank;
          fill_start    <= 1'b1;
          if (pf_prologue) begin
            state <= P_PRO_WAIT;
          end else begin
            pix_k     <= 16'd0;
            pix_total <= cur_len;              // composite the current (serve) span
            state     <= P_PIXEL;
          end
        end

        // P_PRO_WAIT — prologue only: wait for span 0's fill (prefetch_last fires on
        // the exact final-beat cycle), then promote pend→serve and begin compositing.
        P_PRO_WAIT: begin
          if (prefetch_last) begin
            cur_dst_x    <= pend_dst_x;
            cur_dst_y    <= pend_dst_y;
            cur_len      <= pend_len;
            cur_band_row <= pend_band_row;
            gpix0        <= pend_gpix0;
            gpix_lo      <= pend_gpix_lo;
            serve_bank   <= pend_bank;
            state        <= P_SPAN_BEGIN;
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
          s3_palpha      <= b_palpha;   // [PAL8 v1, Task 1.2]

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
            // [PAL8 v1, Task 1.2] per-pixel CLUT alpha overrides the mixer alpha only
            // for PAL8+PALPHA; other PAL8 blends (COPY/COLORKEY/ADD/MULTIPLY) keep the
            // ordinary feed_alpha (c_alpha / pa_a8) already latched into s3_alpha.
            mx_in_alpha <= (s3_fmt == `COMP_PAL8 && s3_palpha) ? {pal_a4_s3, pal_a4_s3}
                                                                : s3_alpha;
          end

          // ── cw coordinate shadow pipeline (seeded at the s3 mixer-feed cycle) ──
          // cwv gates the write-back; fold the PALPHA A4==0 skip in here so a
          // fully-transparent pixel never writes (COMP_CA's out_we is always 1).
          cwx_pipe[0] <= s3_cw_x;
          cwr_pipe[0] <= s3_cw_row;
          cwv_pipe[0] <= s3_valid && !s3_skip_eff;   // [PAL8 v1, Task 1.2] CLUT-alpha-aware skip
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
            if (is_fill) begin
              // FILL: simple per-span loop, no banks / no prefetch.
              chunk_si <= chunk_si + 9'd1;
              state    <= P_COMP_SPAN;
            end else begin
              // SOURCE: gate the span advance on the overlapping prefetch too.
              state <= P_ADVANCE;
            end
          end else begin
            drain_cnt <= drain_cnt - 4'd1;
          end
        end

        // ─────────────────────────────────────────────────────────────────────
        // [Task 3c] SOURCE span advance — the composite of the current span has
        // drained. If a span N+1 was prefetched, wait for that fill to finish
        // (!prefetch_busy — composite+drain may have outrun the slower P_SRC walk),
        // then PROMOTE pend→serve and loop to composite it (kicking the next N+1's
        // prefetch). If this was the last span, advance to the next chunk.
        P_ADVANCE: begin
          if (!next_valid) begin
            chunk_first <= chunk_first + chunk_nspan;
            state       <= P_CHUNK_INIT;
          end else if (!prefetch_busy) begin
            cur_dst_x    <= pend_dst_x;
            cur_dst_y    <= pend_dst_y;
            cur_len      <= pend_len;
            cur_band_row <= pend_band_row;
            gpix0        <= pend_gpix0;
            gpix_lo      <= pend_gpix_lo;
            serve_bank   <= pend_bank;
            chunk_si     <= chunk_si + 9'd1;
            state        <= P_SPAN_BEGIN;
          end
          // else: hold — the overlapping prefetch is still filling the other bank.
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
