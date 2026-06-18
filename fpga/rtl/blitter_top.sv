// VENDORED from github.com/gmcnaught/mister-fpga-blitter (rtl/blitter_top.sv)
// HW addresses come from blitter_defs.vh (this dir). Do not edit here; edit upstream + re-copy.
//============================================================================
//  blitter_top.sv — MiSTer fabric 2D blitter: functional spike (#003)
//
//  Walks a DDR command ring (until END / cmd_count), composites into a
//  framebuffer in DDR per the host<->fabric contract (docs/blitter-protocol.md),
//  then writes the video control word as a DROP-IN PRODUCER for the existing
//  scanout reader. Verified bit-exact in simulation against the C reference
//  model (refmodel/blitter_ref.c) over the full v1 command set.
//
//  SCOPE NOTE: this spike uses a single Avalon-MM master with simple per-pixel
//  reads/writes (byte-enable lane writes) — deliberately FUNCTIONAL, not yet
//  bandwidth-optimal. The on-chip line/tile buffer + burst-DMA refinement (the
//  CV1000 pattern, see docs/) is the #004/#005 perf work and does not change
//  these command/handshake/pixel semantics.
//
//  Command word on-wire layout (32 bytes = 4 qwords, little-endian):
//    u32[0] = opcode[7:0] | blend[15:8] | format[23:16] | flags[31:24]
//    u32[1] = src_off[31:0]
//    u32[2] = src_stride[15:0] | src_x[31:16]
//    u32[3] = w[15:0] | h[31:16]
//    u32[4] = src_y[15:0] | resv
//    u32[5] = dst_x[15:0] | dst_y[31:16]   (signed16)
//    u32[6] = colorkey[15:0] | alpha[23:16] | priority[31:24]
//    u32[7] = color[15:0] | resv
//    qw_k = {u32[2k+1], u32[2k]}
//
//  Copyright (C) 2026 — GPL-3.0
//============================================================================
`default_nettype none
`include "blitter_defs.vh"

module blitter_top #(
    parameter AW = 32
) (
    input  wire          clk,
    input  wire          rst,
    // Avalon-MM-ish master to shared DDR (qword addressed)
    output reg  [AW-1:0] mem_addr,
    output reg           mem_rd,
    output reg           mem_wr,
    output reg  [63:0]   mem_din,
    output reg  [7:0]    mem_be,
    input  wire [63:0]   mem_dout,
    input  wire          mem_dout_ready,
    input  wire          mem_busy,    // reserved (sim model never busy)
    // ---- SDRAM SOURCE path (issue #19, runtime-selected by C_SRCSEL) ----------
    // When the latched srcsel bit is set, blitter SOURCE pixel reads are routed
    // here (sdram_src_arb -> sdram_psx) instead of the DDR3 mem_* master. Only the
    // source read moves; control/ring/dst-RMW reads + ALL writes stay on mem_*.
    // Default (C_SRCSEL=0) leaves src_sdram_rd deasserted -> this path is inert and
    // the DDR3 behavior is byte-identical to the shipping core.
    output reg  [26:0]   src_sdram_addr,   // byte address (qword-aligned) of the source beat
    output reg           src_sdram_rd,     // request one 64-bit beat (held until granted)
    input  wire [63:0]   src_sdram_dout64, // the assembled 64-bit beat (valid on dout_ready)
    input  wire          src_sdram_dout_ready, // per-beat strobe from sdram_psx
    input  wire          src_sdram_busy,   // arbiter p0_busy (= controller not-ready/accepting)
    // ---- SDRAM STAGE WRITE path (issue #19, BLT_OP_STAGE) ----------------------
    // A BLT_OP_STAGE command copies a source region from DDR3 (SRC_QW + off) into
    // SDRAM at the heap-relative byte offset `off` (exactly the address the
    // C_SRCSEL=1 source read uses). These single-16-bit-word write outputs route
    // through sdram_src_arb -> sdram_psx. They are IDLE (we=0) outside staging, so
    // the C_SRCSEL=0 / shipping path is byte-identical (SDRAM write port dead).
    output reg           src_sdram_we,     // request one 16-bit word write (held until granted)
    output reg  [15:0]   src_sdram_din,    // the word to write
    output reg  [26:0]   src_sdram_waddr,  // byte address (bit0=0, 16-bit mode) of the word
    // ---- BL=4 BURST staging write (issue #19) ----
    // One 64-bit DDR3 beat -> ONE SDRAM burst write (4 words) instead of 4 single
    // writes. src_sdram_waddr carries the 8-byte-aligned beat byte address.
    output reg           src_sdram_we_burst, // request one 4-word burst write (held until granted)
    output reg  [63:0]   src_sdram_din64,    // the 64-bit beat to burst-write
    output reg           idle
);
    localparam [5:0]
        S_POLL_SUBMIT=6'd0, S_POLL_DONE=6'd1, S_CHK_NEW=6'd2,
        S_GOT_CMDCNT=6'd3,  S_GOT_TARGET=6'd4, S_GOT_FLAGS=6'd5, S_GOT_CLEAR=6'd6,
        S_CLR_WR=6'd7,      S_FETCH=6'd8,  S_COLLECT=6'd9, S_DECODE=6'd10,
        S_SETUP=6'd11,      S_FILL_WR=6'd12,
        S_BLIT_RDSRC=6'd13, S_BLIT_GOTSRC=6'd14, S_BLIT_RDDST=6'd15,
        S_BLIT_GOTDST=6'd16, S_BLIT_WR=6'd17, S_PIX_ADV=6'd18, S_NEXT_CMD=6'd19,
        S_FRAME_VCTRL=6'd20, S_WR_DONE=6'd21, S_WR_STATUS=6'd22,
        S_RD_WAIT=6'd23,    S_WR_WAIT=6'd24,
        S_BSETUP=6'd25,     // isolated source-base multiply (timing)
        S_BLIT_BLEND2=6'd26,// 2nd blend stage: /255 reduce + RGB565 pack (timing)
        // dst-cache / write-coalesce states
        S_DST_FLUSH=6'd27,  // issue the coalesced DDR write of the cached qword
        S_DST_RDISS=6'd28,  // (blend miss) issue the dst qword read into the cache
        S_ADV_FLUSH=6'd29,  // S_PIX_ADV decided to advance but must flush first
        S_GOT_SRCSEL=6'd30, // control-fetch: latch C_SRCSEL after C_FLAGS
        S_SRC_SDRAM_WAIT=6'd31, // await the SDRAM source beat (when srcsel=1)
        // ---- BLT_OP_STAGE DDR3->SDRAM copy FSM (issue #19) ----
        S_STAGE_RD=6'd32,     // issue the DDR3 read of beat i (SRC_QW + off + i*8)
        S_STAGE_GOT=6'd33,    // capture the beat; begin writing its 4 words to SDRAM
        S_STAGE_WR=6'd34,     // issue one 16-bit SDRAM word write
        S_STAGE_WR_WAIT=6'd35,// hold the SDRAM write until the arbiter accepts it
        S_WR_THROTTLE=6'd36;  // [#34] idle WR_THROTTLE cycles after a write (scanout bandwidth)

    localparam [7:0] OP_NOP=8'd0, OP_END=8'd1, OP_FILL=8'd2, OP_BLIT=8'd3, OP_STAGE=8'd4;
    localparam [7:0] BLEND_KEY=8'd1, BLEND_ALPHA=8'd2, BLEND_PALPHA=8'd3;
    localparam [7:0] F_HFLIP=8'h01, F_VFLIP=8'h02, F_COLORKEY=8'h04, F_STAGE_DST=8'h08,
                     F_SRC_SDRAM=8'h10;  // [#34] per-command source mux: this BLIT reads SDRAM
    // Source pixel formats (cmd.format). RGB565 keeps the v1 16bpp addressing;
    // ARGB4444 is also 16bpp ({A4,R4,G4,B4}) so src_byte_cur / +/-2 / src_sh are
    // UNCHANGED — BLEND_PALPHA just reinterprets the fetched 16-bit source pixel.
    localparam [7:0] FMT_RGB565=8'd0, FMT_ARGB4444=8'd1;

    reg  [5:0]  state, rd_ret, wr_ret, wr_ret2;
    reg         rd_issued;   // read accepted by the bus, now awaiting dout_ready
    reg  [7:0]  throttle_cnt;// [#34] f2h write-throttle countdown (S_WR_THROTTLE)
    // [#34] RUNTIME f2h write-throttle: idle cycles after each accepted f2h write before
    // the next bus transaction. Latched from C_SRCSEL[15:8] each frame (spare bits; the
    // engine publishes it from SOLARUS_BLT_THROTTLE) so the value is HW-tunable without a
    // rebuild. Re-introduces the pacing the DDR3 path got "for free" from interleaved f2h
    // source reads (moving reads to SDRAM un-throttled the blitter -> write storm ->
    // ddram_busy -> scanout FIFO underflow -> rolling image). jtframe lfbuf discipline:
    // the writer must not steal the display's bus window. 0 = no throttle.
    reg  [7:0]  throttle_cfg;
    reg  [63:0] rd_data;

    reg  [31:0] submit_reg, done_reg, cmd_count, cmd_idx, frame_counter;
    reg  [1:0]  target_buf;   // 0/1 = framebuffer; 2 = off-screen bg-cache (no flip)
    reg         srcsel;       // C_SRCSEL bit0: 1 = SDRAM source path, 0 = DDR3 (default)
    reg  [31:0] target_base, cfg_flags, clr_idx;
    reg  [15:0] clear_color;
    reg  [63:0] cmd_qw [0:3];
    reg  [1:0]  fetch_k;

    reg  [7:0]  c_opcode, c_blend, c_format, c_flags, c_alpha;
    reg  [31:0] c_src_off;
    reg  [15:0] c_src_stride, c_src_x, c_src_y, c_w, c_h, c_colorkey, c_color;
    reg  signed [15:0] c_dst_x, c_dst_y;

    reg  signed [31:0] x0r, y0r, x1r, y1r, dx, dy;
    reg         is_fill;
    reg  [15:0] src_pix, wr_pix;
    reg  [31:0] src_byte_cur, src_row_byte;   // incremental source addressing
    reg  [15:0] src_x0s, src_y0s;             // source start coords (latched at S_SETUP)

    // ---- BLT_OP_STAGE copy state (issue #19) ----
    // size = {c_h, c_w} (w=size[15:0], h=size[31:16]); copy `stage_size` bytes from
    // DDR3 SRC_QW+off into SDRAM[off..]. stage_byte = bytes already copied (multiple
    // of 8 = whole beats); stage_beat holds the current DDR3 beat being drained word
    // by word (stage_wj = 0..3).
    reg  [31:0] stage_off;     // DDR3 read (heap/bounce) byte offset (= c_src_off)
    reg  [31:0] stage_sdram_off;// SDRAM dest byte offset (#32: decoupled from the DDR3 read base)
    reg  [31:0] stage_size;    // total bytes to copy = {c_h, c_w}
    reg  [31:0] stage_byte;    // bytes copied so far (beat-granular until a write lands)
    reg  [63:0] stage_beat;    // the current DDR3 beat
    reg  [1:0]  stage_wj;      // which 16-bit word of the beat is being written (0..3)

    wire keyed = (c_blend == BLEND_KEY) || ((c_flags & F_COLORKEY) != 0);
    // [#34] PER-COMMAND source mux. C_SRCSEL (srcsel) is the frame-level master ENABLE;
    // this BLIT reads SDRAM only if it ALSO carries F_SRC_SDRAM. An un-staged source
    // (flag clear) reads DDR3 even under C_SRCSEL=1, so a frame may mix SDRAM + DDR3
    // sources (and FILL / framebuffer-carry blits, which can't be staged, stay on DDR3).
    wire src_in_sdram = srcsel && ((c_flags & F_SRC_SDRAM) != 0);

    // ---- 2-STAGE BLEND (timing): the source-over composite is split across two
    // FSM cycles so no single clock does (multiply + /255 reduction + RGB565 pack)
    // feeding wr_pix. Both const-alpha (blend565) and per-pixel-alpha (blend4444)
    // are unified through the SAME weighted-sum -> reduce/pack datapath:
    //   Stage 1 (S_BLIT_GOTDST): extract per-channel src (5/6/5) + 8-bit alpha
    //     (RGB565 src direct + const c_alpha; ARGB4444 src expands 4->5/6/5 and
    //     a8={a4,a4}), read dst channels, and compute & REGISTER the weighted
    //     sums tr=sr*a8 + dr*na, tg, tb.
    //   Stage 2 (S_BLIT_BLEND2): the divide-free /255 reduction
    //     (t+128+((t+128)>>8))>>8 per channel + the RGB565 pack into wr_pix.
    // Bit-exact to the previous single-cycle blend565/blend4444 (just 1 cycle
    // later); proven by tb_blitter_blend (CONST_ALPHA) + tb_blitter_palpha.
    //
    // Stage-1 outputs (registered): weighted per-channel sums. Max value is
    // 63*255*2 = 32130 (16 bits suffice, but tr+128 needs the headroom -> 17b).
    reg [16:0] blend_tr, blend_tg, blend_tb;

    // Stage-1 combinational channel/alpha extraction (off src_pix / dst_pix_w):
    //  - alpha a8: const path = c_alpha; per-pixel = {a4,a4}
    //  - src channels expanded to dst widths (5/6/5)
    wire        b_palpha = (c_blend == BLEND_PALPHA);
    wire [7:0]  b_a8  = b_palpha ? {src_pix[15:12], src_pix[15:12]} : c_alpha;
    wire [7:0]  b_na  = 8'd255 - b_a8;
    wire [4:0]  b_sr  = b_palpha ? {src_pix[11:8],  src_pix[11]}   : src_pix[15:11];
    wire [5:0]  b_sg  = b_palpha ? {src_pix[7:4],   src_pix[7:6]}  : src_pix[10:5];
    wire [4:0]  b_sb  = b_palpha ? {src_pix[3:0],   src_pix[3]}    : src_pix[4:0];
    // b_dr/b_dg/b_db (dst channels) declared after dst_pix_w below.

    // Stage-2 divide-free /255 reduction (same form as the old refmodel):
    //   o = (t + 128 + ((t+128)>>8)) >> 8
    function [5:0] reduce255(input [16:0] t);
        reg [17:0] t128;
        begin
            t128 = {1'b0, t} + 18'd128;
            reduce255 = (t128 + (t128 >> 8)) >> 8;
        end
    endfunction
    wire [5:0] blend_or = reduce255(blend_tr);
    wire [5:0] blend_og = reduce255(blend_tg);
    wire [5:0] blend_ob = reduce255(blend_tb);

    // ---- clip (combinational off decoded c_*) --------------------------
    wire signed [31:0] sdx = c_dst_x, sdy = c_dst_y;
    wire signed [31:0] xe = sdx + c_w, ye = sdy + c_h;
    wire signed [31:0] clip_x0 = (sdx<0)?0:sdx;
    wire signed [31:0] clip_y0 = (sdy<0)?0:sdy;
    wire signed [31:0] clip_x1 = (xe>`FB_W)?`FB_W:xe;
    wire signed [31:0] clip_y1 = (ye>`FB_H)?`FB_H:ye;
    wire empty = (clip_x0>=clip_x1) || (clip_y0>=clip_y1);

    // ---- source addressing: REGISTERED INCREMENTAL --------------------------
    // Was a per-pixel 16x16 multiply (c_src_y+sy)*c_src_stride sitting on the
    // dy -> wr_pix critical path (setup slack -7.348 ns). src_byte_cur is now
    // maintained by adds in S_PIX_ADV (+/-2 per pixel, +/-stride per row); the
    // single multiply is isolated once-per-blit in S_BSETUP.
    wire [31:0] src_qw    = `SRC_QW + (src_byte_cur >> 3);
    wire [5:0]  src_sh    = {src_byte_cur[2:1], 4'b0};
    // ---- SOURCE QWORD READ CACHE (perf: amortize per-pixel read latency) -------
    // A 64-bit DDR beat holds FOUR 16bpp source pixels. The per-pixel cursor steps
    // +2 bytes, so 4 consecutive pixels in a row share ONE source qword; without a
    // cache the FSM re-reads that qword 4x, and a single-beat read stalls ~7 cyc
    // (rlat + backpressure + arbiter grant) — the profiled dominant cost. We keep
    // the last source qword + its address; on a HIT (same qword, cache valid) we
    // skip the DDR read entirely and serve src_pix from the cached beat. Bit-exact:
    // same bytes the read would have returned (source surface is not written during
    // a blit). Invalidated per-blit at S_BSETUP. Flips still step +/-2 bytes so 4
    // adjacent pixels stay in one qword regardless of direction.
    reg  [31:0] src_cache_qw;
    reg  [63:0] src_cache_data;
    reg         src_cache_vld;
    reg         src_from_cache;   // S_BLIT_GOTSRC: take src_pix from cache vs rd_data
    wire        src_hit = src_cache_vld && (src_qw == src_cache_qw);
    wire [63:0] src_beat = src_from_cache ? src_cache_data : rd_data;
    wire [15:0] src_pix_w = src_beat[src_sh +: 16];
    // signed source-local start coords at the clipped origin (off c_*, dst)
    wire signed [31:0] sx0 = clip_x0 - sdx;   // = lx at (clip_x0)
    wire signed [31:0] sy0 = clip_y0 - sdy;   // = ly at (clip_y0)

    // ---- dest addressing: REGISTERED INCREMENTAL (timing) -------------------
    // dst_pidx = dy*320 + dx was a per-pixel 16x16 multiply feeding the dst_qw /
    // dst_sh / lane_be / dst_pix_w chain on the dx -> wr_pix critical path. Like
    // the source cursor, it is now maintained by adds: +1 per pixel in a row, and
    // reset to the row start (+320) per row in S_PIX_ADV. The single base
    // multiply (y0*320 + x0) is isolated once-per-blit in S_BSETUP / S_FILL setup.
    reg  [31:0] dst_pidx_r, dst_row_pidx_r;
    wire [31:0] dst_pidx = dst_pidx_r;
    wire [31:0] dst_qw   = target_base + (dst_pidx >> 2);
    wire [5:0]  dst_sh   = {dst_pidx[1:0], 4'b0};
    wire [7:0]  lane_be  = 8'h03 << {dst_pidx[1:0], 1'b0};
    // base index at the clipped origin: dy*320 = (dy<<8)+(dy<<6) shift-add.
    wire [31:0] dst_base_pidx = (clip_y0<<8) + (clip_y0<<6) + clip_x0;

    // ---- DESTINATION QWORD CACHE + WRITE-COALESCE (perf) ----------------------
    // The framebuffer qword (4 RGB565 px) is shared by 4 horizontally-adjacent
    // dest pixels. Single-beat per-pixel writes cost ~1-2 cyc each and, for blends,
    // each pixel also did a single-beat dst read-modify-write (~7 cyc). We hold ONE
    // dst qword: its 64-bit data, a per-lane byte-enable accumulator (which 16-bit
    // lanes this blit has modified), valid (has true DDR contents for RMW reads) and
    // dirty (has un-flushed writes). Per pixel we MERGE wr_pix into the cached qword
    // (no DDR) and OR in the lane BE. When the dest qword address changes (next
    // pixel/row) or the blit ends we FLUSH one DDR write using the accumulated BE —
    // byte-identical to the old per-pixel lane writes (untouched lanes preserved,
    // skipped/keyed pixels never set their lane). Blend RMW reads are served from the
    // cache on a hit; a miss flushes any dirty qword then reads the new one.
    reg  [31:0] dst_cache_qw;
    reg  [63:0] dst_cache_data;
    reg  [7:0]  dst_cache_be;     // lanes modified (accumulated, 2 BE bits per px)
    reg         dst_cache_vld;    // holds real DDR contents (safe for blend RMW read)
    reg         dst_cache_dirty;  // has pending writes to flush
    reg         dst_from_cache;   // S_BLIT_GOTDST: take dst channels from cache vs rd_data
    wire        dst_hit  = dst_cache_vld && (dst_qw == dst_cache_qw);
    wire [63:0] dst_beat = dst_from_cache ? dst_cache_data : rd_data;
    wire [15:0] dst_pix_w = dst_beat[dst_sh +: 16];
    // stage-1 dst channel extraction
    wire [4:0]  b_dr  = dst_pix_w[15:11];
    wire [5:0]  b_dg  = dst_pix_w[10:5];
    wire [4:0]  b_db  = dst_pix_w[4:0];
    // merge wr_pix into the current dst qword lane (clear the 16b lane, OR the pixel)
    wire [63:0] dst_merge_mask = {48'd0, 16'hFFFF} << dst_sh;   // ones over the lane
    wire [63:0] dst_lane_ins   = {48'd0, wr_pix}  << dst_sh;
    wire [63:0] dst_merged     = (dst_cache_data & ~dst_merge_mask) | dst_lane_ins;

    // video control word (drop-in producer): frame_counter[31:2] | buf[1:0]
    wire [31:0] vctrl_val = ((frame_counter + 32'd1) << 2) | {31'd0, target_buf[0]};

    always @(posedge clk) begin
        if (rst) begin
            state<=S_POLL_SUBMIT; mem_rd<=0; mem_wr<=0; mem_be<=0;
            mem_addr<=0; mem_din<=0; idle<=1; frame_counter<=0;
            cmd_idx<=0; fetch_k<=0; submit_reg<=0; done_reg<=0; rd_issued<=0;
            throttle_cnt<=8'd0; throttle_cfg<=8'd0;
            src_cache_vld<=0; src_from_cache<=0;
            dst_cache_vld<=0; dst_cache_dirty<=0; dst_from_cache<=0;
            srcsel<=1'b0; src_sdram_rd<=1'b0; src_sdram_addr<=27'd0;
            src_sdram_we<=1'b0; src_sdram_din<=16'd0; src_sdram_waddr<=27'd0;
            src_sdram_we_burst<=1'b0; src_sdram_din64<=64'd0;
        end else begin
            mem_rd<=1'b0;
            src_sdram_rd<=1'b0;   // single-cycle request unless re-asserted (held in S_RD wait)
            src_sdram_we<=1'b0;   // single-cycle write request unless re-asserted (held in S_STAGE_WR_WAIT)
            src_sdram_we_burst<=1'b0; // single-cycle burst-write request unless re-asserted
            case (state)
            S_POLL_SUBMIT: begin
                idle<=1; mem_rd<=1; mem_addr<=`BLTCTRL_QW+`C_SUBMIT;
                rd_ret<=S_POLL_DONE; state<=S_RD_WAIT;
            end
            S_POLL_DONE: begin
                submit_reg<=rd_data[31:0];
                mem_rd<=1; mem_addr<=`BLTCTRL_QW+`C_DONE;
                rd_ret<=S_CHK_NEW; state<=S_RD_WAIT;
            end
            S_CHK_NEW: begin
                done_reg<=rd_data[31:0];
                if (rd_data[31:0]==submit_reg) state<=S_POLL_SUBMIT;   // idle: keep polling
                else begin
                    idle<=0; mem_rd<=1; mem_addr<=`BLTCTRL_QW+`C_CMDCOUNT;
                    rd_ret<=S_GOT_CMDCNT; state<=S_RD_WAIT;
                end
            end
            S_GOT_CMDCNT: begin
                cmd_count<=rd_data[31:0];
                mem_rd<=1; mem_addr<=`BLTCTRL_QW+`C_TARGET;
                rd_ret<=S_GOT_TARGET; state<=S_RD_WAIT;
            end
            S_GOT_TARGET: begin
                target_buf<=rd_data[1:0];
                // C_TARGET==2 -> compose into the OFF-SCREEN bg-cache (no display flip);
                // 0/1 -> framebuffer BUF0/BUF1.
                target_base<=(rd_data[1:0]==2'd2) ? `CACHE_QW :
                             (rd_data[0] ? `FB1_QW : `FB0_QW);
                mem_rd<=1; mem_addr<=`BLTCTRL_QW+`C_FLAGS;
                rd_ret<=S_GOT_FLAGS; state<=S_RD_WAIT;
            end
            S_GOT_FLAGS: begin
                cfg_flags<=rd_data[31:0];
                // fetch C_SRCSEL next (appended control word; default 0 = DDR3)
                mem_rd<=1; mem_addr<=`BLTCTRL_QW+`C_SRCSEL;
                rd_ret<=S_GOT_SRCSEL; state<=S_RD_WAIT;
            end
            S_GOT_SRCSEL: begin
                srcsel<=rd_data[0];           // bit0: 1 -> SDRAM source path, 0 -> DDR3
                throttle_cfg<=rd_data[15:8];  // [#34] f2h write-throttle (spare C_SRCSEL bits)
                mem_rd<=1; mem_addr<=`BLTCTRL_QW+`C_CLEAR;
                rd_ret<=S_GOT_CLEAR; state<=S_RD_WAIT;
            end
            S_GOT_CLEAR: begin
                clear_color<=rd_data[15:0];
                if (cfg_flags[0]) begin clr_idx<=0; state<=S_CLR_WR; end
                else begin cmd_idx<=0; fetch_k<=0; state<=S_FETCH; end
            end
            S_CLR_WR: begin
                if (clr_idx==`FB_QWORDS) begin
                    cmd_idx<=0; fetch_k<=0; state<=S_FETCH;
                end else begin
                    mem_wr<=1; mem_be<=8'hFF; mem_addr<=target_base+clr_idx;
                    mem_din<={4{clear_color}}; clr_idx<=clr_idx+1;
                    wr_ret<=S_CLR_WR; state<=S_WR_WAIT;
                end
            end

            S_FETCH: begin
                if (cmd_idx>=cmd_count) state<=S_FRAME_VCTRL;
                else begin
                    fetch_k<=0; mem_rd<=1; mem_addr<=`RING_QW+cmd_idx*4;
                    rd_ret<=S_COLLECT; state<=S_RD_WAIT;
                end
            end
            S_COLLECT: begin
                cmd_qw[fetch_k]<=rd_data;
                if (fetch_k==2'd3) state<=S_DECODE;
                else begin
                    mem_rd<=1; mem_addr<=`RING_QW+cmd_idx*4+(fetch_k+2'd1);
                    fetch_k<=fetch_k+2'd1; rd_ret<=S_COLLECT; state<=S_RD_WAIT;
                end
            end
            S_DECODE: begin
                c_opcode    <= cmd_qw[0][7:0];
                c_blend     <= cmd_qw[0][15:8];
                c_format    <= cmd_qw[0][23:16];
                c_flags     <= cmd_qw[0][31:24];
                c_src_off   <= cmd_qw[0][63:32];
                c_src_stride<= cmd_qw[1][15:0];
                c_src_x     <= cmd_qw[1][31:16];
                c_w         <= cmd_qw[1][47:32];
                c_h         <= cmd_qw[1][63:48];
                c_src_y     <= cmd_qw[2][15:0];
                c_dst_x     <= cmd_qw[2][47:32];
                c_dst_y     <= cmd_qw[2][63:48];
                c_colorkey  <= cmd_qw[3][15:0];
                c_alpha     <= cmd_qw[3][23:16];
                c_color     <= cmd_qw[3][47:32];
                state<=S_SETUP;
            end
            S_SETUP: begin
                // [#34 timing] Load the dst write-index base UNCONDITIONALLY here
                // (not inside the !empty branch below). dst_base_pidx depends only on
                // c_dst_x/c_dst_y — NOT on c_h — so the worst-case setup path was
                // c_h -> ye -> clip_y1 -> empty -> the dst_*_pidx_r load ENABLE
                // (-0.080 ns post-VRAM). Moving the load out of the empty-gated branch
                // removes `empty` (hence c_h) from these 32-bit registers' enable; the
                // value is dead for empty/END/NOP/STAGE commands (the blit/fill loop is
                // the only consumer and only runs on the !empty path). No FSM-timing
                // change (same S_DECODE->S_SETUP cycle) — a pipeline stage here perturbs
                // the write-coalesce flush (tb_blitter_system PHASE3 drops the last qword).
                dst_pidx_r     <= dst_base_pidx;
                dst_row_pidx_r <= dst_base_pidx;
                if (c_opcode==OP_END)       state<=S_FRAME_VCTRL;
                else if (c_opcode==OP_NOP)  state<=S_NEXT_CMD;
                else if (c_opcode==OP_STAGE) begin
                    // BLT_OP_STAGE: copy {c_h,c_w} bytes from DDR3 SRC_QW+off into
                    // SDRAM. DDR3 read base = c_src_off. SDRAM dest = u32[2]
                    // ({c_src_x,c_src_stride}) when F_STAGE_DST is set (#32 decoupled),
                    // else c_src_off (#19 behavior). size = {h,w}; 0-byte = no-op.
                    stage_off  <= c_src_off;
                    stage_sdram_off <= (c_flags & F_STAGE_DST) ? {c_src_x, c_src_stride}
                                                               : c_src_off;
                    stage_size <= {c_h, c_w};
                    stage_byte <= 32'd0;
                    if ({c_h, c_w} == 32'd0) state<=S_NEXT_CMD;
                    else                     state<=S_STAGE_RD;
                end
                else if (empty)             state<=S_NEXT_CMD;
                else begin
                    x0r<=clip_x0; y0r<=clip_y0; x1r<=clip_x1; y1r<=clip_y1;
                    dx<=clip_x0;  dy<=clip_y0; is_fill<=(c_opcode==OP_FILL);
                    // dst write-index base (dst_pidx_r/dst_row_pidx_r) is loaded
                    // UNCONDITIONALLY at the top of S_SETUP (timing — see note above);
                    // per-pixel/per-row it is maintained by adds in S_PIX_ADV.
                    // latch source-local start coords (flip-aware); the base
                    // multiply happens once in S_BSETUP (off the per-pixel path)
                    src_x0s <= c_src_x + ((c_flags&F_HFLIP) ? (c_w-1 - sx0[15:0]) : sx0[15:0]);
                    src_y0s <= c_src_y + ((c_flags&F_VFLIP) ? (c_h-1 - sy0[15:0]) : sy0[15:0]);
                    // new blit -> dst cache holds nothing valid for THIS blit's qwords
                    // (another blit may have touched them via DDR); start clean.
                    dst_cache_vld   <= 1'b0;
                    dst_cache_dirty <= 1'b0;
                    state<=(c_opcode==OP_FILL)?S_FILL_WR:S_BSETUP;
                end
            end
            S_BSETUP: begin
                // single isolated source-base multiply (src_y*stride); per-pixel
                // addressing is pure adds from here on
                src_row_byte <= c_src_off + src_y0s*c_src_stride + {15'd0, src_x0s, 1'b0};
                src_byte_cur <= c_src_off + src_y0s*c_src_stride + {15'd0, src_x0s, 1'b0};
                src_cache_vld <= 1'b0;   // new source surface -> invalidate read cache
                state<=S_BLIT_RDSRC;
            end

            // FILL: deposit c_color via the shared coalescing merge (S_BLIT_WR).
            // c_color is stable for the whole blit, so we can set wr_pix and merge
            // in the next cycle exactly like COPY/BLEND.
            S_FILL_WR: begin
                wr_pix <= c_color; state <= S_BLIT_WR;
            end
            S_BLIT_RDSRC: begin
                if (src_hit) begin
                    // cache HIT: skip the read, serve src_pix from cache next cyc.
                    // Identical for BOTH source paths (no bus access on a hit).
                    src_from_cache <= 1'b1; state<=S_BLIT_GOTSRC;
                end else if (src_in_sdram) begin
                    // SDRAM SOURCE path: request one 64-bit beat at the same qword the
                    // DDR3 read would fetch. src_sdram_addr is the BYTE address of that
                    // qword (src_byte_cur masked to the 8-byte boundary), so the beat
                    // holds the same 4 source pixels. rd_data is filled from the SDRAM
                    // beat in S_SRC_SDRAM_WAIT, then S_BLIT_GOTSRC proceeds unchanged.
                    src_from_cache <= 1'b0;
                    src_sdram_addr <= {src_byte_cur[26:3], 3'b000};
                    src_sdram_rd   <= 1'b1;
                    state<=S_SRC_SDRAM_WAIT;
                end else begin
                    src_from_cache <= 1'b0;
                    mem_rd<=1; mem_addr<=src_qw; rd_ret<=S_BLIT_GOTSRC; state<=S_RD_WAIT;
                end
            end
            // Hold the SDRAM source request until the arbiter accepts it (!busy),
            // then await the single beat's dout_ready. Mirrors S_RD_WAIT but on the
            // SDRAM source ports. On dout_ready, capture the beat into rd_data so the
            // shared S_BLIT_GOTSRC cache-fill + src_pix logic runs UNCHANGED.
            S_SRC_SDRAM_WAIT: begin
                if (src_sdram_rd) begin
                    // re-assert until granted; the arbiter grants when !busy.
                    if (!src_sdram_busy) src_sdram_rd <= 1'b0;  // accepted; drop request
                    else                 src_sdram_rd <= 1'b1;  // hold
                end
                if (src_sdram_dout_ready) begin
                    rd_data <= src_sdram_dout64; state <= S_BLIT_GOTSRC;
                end
            end
            S_BLIT_GOTSRC: begin
                // populate the cache on a real read (miss); on a hit it is unchanged.
                if (!src_from_cache) begin
                    src_cache_data <= rd_data; src_cache_qw <= src_qw; src_cache_vld <= 1'b1;
                end
                src_pix<=src_pix_w;
                if (keyed && (src_pix_w==c_colorkey)) state<=S_PIX_ADV; // skip-write
                // per-pixel alpha: fully-transparent source (A4==0) -> skip-write
                else if (c_blend==BLEND_PALPHA && (src_pix_w[15:12]==4'd0))
                    state<=S_PIX_ADV;
                else if (c_blend==BLEND_ALPHA || c_blend==BLEND_PALPHA) begin
                    // blend RMW read of the dst qword: HIT -> use cached contents
                    // (already includes earlier same-qword blends, exactly like the
                    // old per-pixel read-after-write); MISS -> flush any dirty stale
                    // qword (S_DST_RDISS handles read+populate after the flush).
                    if (dst_hit) begin
                        dst_from_cache <= 1'b1; state<=S_BLIT_GOTDST;
                    end else if (dst_cache_dirty) begin
                        wr_ret2 <= S_DST_RDISS; state<=S_DST_FLUSH;
                    end else begin
                        state <= S_DST_RDISS;
                    end
                end else begin wr_pix<=src_pix_w; state<=S_BLIT_WR; end
            end
            // (blend MISS) issue the dst qword read; populate the cache in
            // S_BLIT_GOTDST from rd_data. dst_from_cache=0 -> blend uses rd_data.
            S_DST_RDISS: begin
                dst_from_cache <= 1'b0;
                mem_rd<=1; mem_addr<=dst_qw; rd_ret<=S_BLIT_GOTDST; state<=S_RD_WAIT;
            end
            // Stage 1: per-channel weighted sums (multiplies) -> registers.
            // src alpha/channel extraction (RGB565 vs ARGB4444) is the b_* wires.
            S_BLIT_GOTDST: begin
                // on a real read (miss), capture the qword into the cache (valid
                // contents for subsequent same-qword RMW blends).
                if (!dst_from_cache) begin
                    dst_cache_data <= rd_data; dst_cache_qw <= dst_qw; dst_cache_vld <= 1'b1;
                end
                blend_tr <= b_sr*b_a8 + b_dr*b_na;
                blend_tg <= b_sg*b_a8 + b_dg*b_na;
                blend_tb <= b_sb*b_a8 + b_db*b_na;
                state<=S_BLIT_BLEND2;
            end
            // Stage 2: /255 reduction + RGB565 pack (no multiply on this path).
            S_BLIT_BLEND2: begin
                wr_pix<={ blend_or[4:0], blend_og[5:0], blend_ob[4:0] };
                state<=S_BLIT_WR;
            end
            // COALESCING MERGE: deposit wr_pix into the dst-qword cache instead of a
            // per-pixel DDR write. If a different qword is pending-dirty, flush it
            // first (S_DST_FLUSH returns here). Then merge: clear the lane, OR the
            // pixel, accumulate the lane byte-enable, mark dirty. On a fresh qword
            // (not the one cached) reset the BE accumulator to this lane only.
            S_BLIT_WR: begin
                if (dst_cache_dirty && (dst_qw != dst_cache_qw)) begin
                    wr_ret2 <= S_BLIT_WR; state <= S_DST_FLUSH;   // flush stale qword first
                end else begin
                    // dst_merged = (cache & ~lane) | pixel; correct for both the
                    // same-qword case and a fresh qword (BE gates the unwritten lanes).
                    // BE accumulates ONLY when we are already mid-write on this same
                    // qword (dirty); otherwise start fresh at this lane. (For blends
                    // the RMW read leaves vld=1/dirty=0, so the first write of a qword
                    // correctly resets BE rather than ORing a stale accumulator.)
                    dst_cache_data  <= dst_merged;
                    dst_cache_be    <= (dst_cache_dirty && (dst_qw == dst_cache_qw))
                                         ? (dst_cache_be | lane_be) : lane_be;
                    dst_cache_qw    <= dst_qw;
                    dst_cache_dirty <= 1'b1;
                    state <= S_PIX_ADV;
                end
            end
            S_PIX_ADV: begin
                if ((dx+1)>=x1r) begin
                    dx<=x0r;
                    if ((dy+1)>=y1r) begin
                        // end of blit: flush the final cached qword if dirty
                        if (dst_cache_dirty) begin wr_ret2<=S_NEXT_CMD; state<=S_DST_FLUSH; end
                        else state<=S_NEXT_CMD;
                    end
                    else begin
                        dy<=dy+1;
                        // next row: dst index steps to the next row start (+320),
                        // dst cursor reset to it (mirrors src_byte_cur reset).
                        dst_row_pidx_r <= dst_row_pidx_r + `FB_W;
                        dst_pidx_r     <= dst_row_pidx_r + `FB_W;
                        // next row: source y steps by +/-1 -> +/- stride bytes;
                        // reset the column cursor to the new row's start
                        src_row_byte <= (c_flags&F_VFLIP) ? src_row_byte - {16'd0,c_src_stride}
                                                          : src_row_byte + {16'd0,c_src_stride};
                        src_byte_cur <= (c_flags&F_VFLIP) ? src_row_byte - {16'd0,c_src_stride}
                                                          : src_row_byte + {16'd0,c_src_stride};
                        state<=is_fill?S_FILL_WR:S_BLIT_RDSRC;
                    end
                end else begin
                    dx<=dx+1;
                    // next pixel in row: dst index +1
                    dst_pidx_r <= dst_pidx_r + 32'd1;
                    // next pixel in row: source x steps by +/-1 -> +/-2 bytes
                    src_byte_cur <= (c_flags&F_HFLIP) ? src_byte_cur - 32'd2
                                                      : src_byte_cur + 32'd2;
                    state<=is_fill?S_FILL_WR:S_BLIT_RDSRC;
                end
            end
            // Coalesced writeback of the cached dst qword: ONE DDR write of the
            // accumulated lanes (dst_cache_be) to dst_cache_qw. Clears dirty; the
            // cache data/valid persist (so an immediately-following same-qword RMW
            // read still hits). Returns to wr_ret2 once the bus accepts the write.
            S_DST_FLUSH: begin
                mem_wr<=1; mem_be<=dst_cache_be; mem_addr<=dst_cache_qw;
                mem_din<=dst_cache_data;
                dst_cache_dirty<=1'b0;
                wr_ret<=wr_ret2; state<=S_WR_WAIT;
            end

            // ---- BLT_OP_STAGE DDR3->SDRAM copy (issue #19) ----
            // Read one 64-bit beat from DDR3 at SRC_QW + (off+stage_byte)>>3 (the
            // staged region is qword-aligned: off is qword-aligned in practice and
            // stage_byte advances by 8). The shared read master + S_RD_WAIT carry it.
            S_STAGE_RD: begin
                mem_rd<=1; mem_addr<=`SRC_QW + ((stage_off + stage_byte) >> 3);
                rd_ret<=S_STAGE_GOT; state<=S_RD_WAIT;
            end
            // Capture the beat, then issue ONE BL=4 SDRAM burst write of all 4
            // words (instead of 4 single-word writes). The beat is 8-byte aligned
            // (off is qword-aligned; stage_byte steps by 8), so its 4 words share
            // one row + 4 consecutive columns — a single SDRAM burst, never
            // crossing a row boundary.
            S_STAGE_GOT: begin
                stage_beat <= rd_data;
                state<=S_STAGE_WR;
            end
            // Issue one 4-word SDRAM burst write of the current beat at the
            // 8-byte-aligned heap byte address off + stage_byte.
            S_STAGE_WR: begin
                src_sdram_waddr    <= (stage_sdram_off + stage_byte) & 27'h7FFFFF8; // 8-byte align (#32 decoupled dest)
                src_sdram_din64    <= stage_beat;
                src_sdram_we_burst <= 1'b1;
                state<=S_STAGE_WR_WAIT;
            end
            // Hold the burst write until the arbiter accepts it (!busy). On
            // acceptance, drop the request; advance to the next beat, or complete
            // the command once all `stage_size` bytes are copied.
            S_STAGE_WR_WAIT: begin
                if (src_sdram_we_burst) begin
                    if (!src_sdram_busy) src_sdram_we_burst <= 1'b0;  // accepted; drop
                    else                 src_sdram_we_burst <= 1'b1;  // hold
                end else begin
                    // the burst write was accepted last cycle; advance one beat.
                    if (stage_byte + 32'd8 >= stage_size) begin
                        state<=S_NEXT_CMD;
                    end else begin
                        stage_byte <= stage_byte + 32'd8;
                        state<=S_STAGE_RD;
                    end
                end
            end

            S_NEXT_CMD: begin cmd_idx<=cmd_idx+1; state<=S_FETCH; end

            S_FRAME_VCTRL: begin
                // OFF-SCREEN cache pass (target==2): do NOT publish a new frame — skip
                // the vctrl write + frame_counter bump so the scanout keeps displaying
                // the previous (complete) frame while the cache is composed invisibly.
                // Still signals C_DONE below so the engine's handshake completes.
                if (target_buf==2'd2) begin
                    state<=S_WR_DONE;
                end else begin
                    mem_wr<=1; mem_be<=8'h0F; mem_addr<=`VCTRL_QW;
                    mem_din<={32'd0, vctrl_val};
                    frame_counter<=frame_counter+1;
                    wr_ret<=S_WR_DONE; state<=S_WR_WAIT;
                end
            end
            S_WR_DONE: begin
                mem_wr<=1; mem_be<=8'h0F; mem_addr<=`BLTCTRL_QW+`C_DONE;
                mem_din<={32'd0, submit_reg};
                wr_ret<=S_WR_STATUS; state<=S_WR_WAIT;
            end
            S_WR_STATUS: begin
                mem_wr<=1; mem_be<=8'h0F; mem_addr<=`BLTCTRL_QW+`C_STATUS;
                mem_din<=64'd0; wr_ret<=S_POLL_SUBMIT; state<=S_WR_WAIT;
            end

            // Backpressure-safe generic read: hold mem_rd until the bus accepts
            // it (~mem_busy), then await dout_ready. (mem_busy = ddram busy OR not
            // granted by the arbiter; on the never-busy sim model this is a no-op.)
            S_RD_WAIT: begin
                if (!rd_issued) begin
                    mem_rd <= 1'b1;                       // hold request
                    if (!mem_busy) rd_issued <= 1'b1;     // accepted this cycle
                end else if (mem_dout_ready) begin
                    rd_data <= mem_dout; rd_issued <= 1'b0; state <= rd_ret;
                end
            end
            // Backpressure-safe generic write: mem_wr/addr/din/be held from the
            // issue state; clear + advance only once the bus accepts (~mem_busy).
            S_WR_WAIT: if (!mem_busy) begin
                mem_wr <= 1'b0; mem_be <= 8'h00;
                // [#34] after the write is accepted, idle the bus for throttle_cfg cycles
                // so the scanout reader can refill its FIFO (un-throttled back-to-back
                // writes saturate the f2h write FIFO -> ddram_busy -> scanout starves).
                if (throttle_cfg != 8'd0) begin
                    throttle_cnt <= throttle_cfg; state <= S_WR_THROTTLE;
                end else state <= wr_ret;
            end
            // [#34] bus held idle (mem_rd/mem_wr both 0 here) -> the arbiter sees the
            // blitter not requesting and the reader gets the bus. Then resume the FSM.
            S_WR_THROTTLE:
                if (throttle_cnt != 8'd0) throttle_cnt <= throttle_cnt - 8'd1;
                else state <= wr_ret;
            default: state<=S_POLL_SUBMIT;
            endcase
        end
    end
endmodule
`default_nettype wire
