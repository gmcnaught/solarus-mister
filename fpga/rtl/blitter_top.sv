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
    // Avalon-MM-ish master to shared DDR (qword addressed). Driven by an OWNER
    // MUX (see bottom of module): the FSM drives them via its bm_* regs for ring/
    // clear/STAGE/status traffic; while a render runs, comp_pipeline drives them.
    output wire [AW-1:0] mem_addr,
    output wire          mem_rd,
    output wire          mem_wr,
    output wire [7:0]    mem_burstcnt,   // burst beats while comp_pipeline owns the bus; 8'd1 for FSM traffic
    output wire [63:0]   mem_din,
    output wire [7:0]    mem_be,
    input  wire [63:0]   mem_dout,
    input  wire          mem_dout_ready,
    input  wire          mem_busy,    // reserved (sim model never busy)
    // ---- P_SRC cache-ok channel (Task 5 controller pivot) ----------------------
    // SOURCE pixel reads now use the sdram_fb_cache P_SRC channel (read-only).
    // Protocol: pulse p0_rd with p0_addr for one cycle; capture p0_dout on p0_ok.
    // No busy/backpressure: the cache-ok channel is always ready to accept a read
    // and returns data (p0_ok=1 with p0_dout) after a fixed cache-hit latency.
    // comp_pipeline (u_pipe) is the sole renderer and drives these ports directly
    // (see bottom); they are idle (p0_rd=0) outside a source fetch.
    output wire [26:0]   p0_addr,          // byte address (qword-aligned) of the source beat
    output wire          p0_rd,            // one-cycle read pulse (cache-ok: no hold needed)
    input  wire [63:0]   p0_dout,          // 64-bit read data (valid when p0_ok asserts)
    input  wire          p0_ok,            // per-beat valid strobe from the cache channel
    // ---- SDRAM STAGE WRITE path (issue #19, BLT_OP_STAGE) ----------------------
    // A BLT_OP_STAGE command copies a source region from DDR3 (SRC_QW + off) into
    // SDRAM at the heap-relative byte offset `off` (exactly the address the SDRAM
    // source read uses). These single-16-bit-word write outputs route through the
    // cache STAGE channel (ch1). They are IDLE (we=0) outside staging.
    output reg           src_sdram_we,     // request one 16-bit word write (held until granted)
    output reg  [15:0]   src_sdram_din,    // the word to write
    output reg  [26:0]   src_sdram_waddr,  // byte address (bit0=0, 16-bit mode) of the word
    // ---- BL=4 BURST staging write (issue #19) ----
    // One 64-bit DDR3 beat -> ONE SDRAM burst write (4 words) instead of 4 single
    // writes. src_sdram_waddr carries the 8-byte-aligned beat byte address.
    output reg           src_sdram_we_burst, // request one 4-word burst write (held until granted)
    output reg  [63:0]   src_sdram_din64,    // the 64-bit beat to burst-write
    input  wire          src_sdram_ok,       // [#44] cache-ok: STAGE burst write accepted (hold we_burst until this)
    // ---- intra-frame STAGE->P_SRC coherency barrier ---------------------------
    // After a STAGE command finishes copying its atlas into SDRAM cache ch1, the
    // dirty ch1 lines are NOT yet in SDRAM and ch5 (P_SRC) may hold STALE lines for
    // the same addresses. The engine consumes a freshly-staged surface in the SAME
    // frame (STAGE then BLIT in one command ring), so we cannot wait for vsync to
    // flush. On STAGE completion we pulse stage_barrier and HOLD the FSM until
    // stage_barrier_busy clears (ch1 committed + ch5 invalidated) before processing
    // the next command — guaranteeing the consuming BLIT's P_SRC fetch is coherent.
    output reg           stage_barrier,       // one-cycle request: commit ch1 + invalidate ch5
    input  wire          stage_barrier_busy,  // high while the barrier flush/invalidate runs
    // ---- intra-frame ch0->P_SRC carry-forward coherency barrier ----------------
    // The engine's per-frame carry-forward copies the previously-composited FB
    // (written by the compositor via P_DST/ch0 last frame) into this frame's target
    // FB, reading the source through P_SRC/ch5 (BLT_F_SRC_SDRAM FB->FB copy). ch0 and
    // ch5 are SEPARATE caches over the same SDRAM, so without a commit+invalidate the
    // carry-forward reads STALE pixels and the two display buffers diverge (hero/NPCs
    // flip between two frames). The vsync ch0 flush is async to frame processing, so we
    // pulse dst_barrier when a BLIT carries the F_SRC_FB flag (the carry-forward copy)
    // and HOLD until dst_barrier_busy clears (ch0 committed + ch5 invalidated) BEFORE
    // that BLIT's P_SRC source fetch.
    output reg           dst_barrier,         // one-cycle request: commit ch0 + invalidate ch0/4/5
    input  wire          dst_barrier_busy,    // high while the dst-barrier flush/invalidate runs
    output reg           idle,
    // ---- DEBUG snapshot (issue #34 HW wedge probe) -----------------------------
    // Continuously-driven live state for HW post-mortem: published by the scanout
    // reader into VSYNC_ADDR's HIGH 32 bits (0x3A070004) each frame — the reader
    // stays alive when the blitter wedges, so devmem 0x3A070004 reveals WHERE the
    // blitter is stuck. dbg[5:0]=state, [22:15]=0, [14:6]=0 (legacy dx/dy retired with
    // the per-pixel renderer), [23]=rd_issued, [31:24]=stuck-count (cycles-in-state >>
    // 16, saturates 0xFF = frozen). No effect on the datapath.
    output wire [31:0]   dbg
);
    localparam [5:0]
        S_POLL_SUBMIT=6'd0, S_POLL_DONE=6'd1, S_CHK_NEW=6'd2,
        S_GOT_CMDCNT=6'd3,  S_GOT_TARGET=6'd4, S_GOT_FLAGS=6'd5, S_GOT_CLEAR=6'd6,
        S_CLR_WR=6'd7,      S_FETCH=6'd8,  S_COLLECT=6'd9, S_DECODE=6'd10,
        S_SETUP=6'd11,      S_NEXT_CMD=6'd19,
        S_FRAME_VCTRL=6'd20, S_WR_DONE=6'd21, S_WR_STATUS=6'd22,
        S_RD_WAIT=6'd23,    S_WR_WAIT=6'd24,
        S_GOT_SRCSEL=6'd30, // control-fetch: latch C_SRCSEL after C_FLAGS
        // ---- BLT_OP_STAGE DDR3->SDRAM copy FSM (issue #19) ----
        S_STAGE_RD=6'd32,     // issue the DDR3 read of beat i (SRC_QW + off + i*8)
        S_STAGE_GOT=6'd33,    // capture the beat; begin writing its 4 words to SDRAM
        S_STAGE_WR=6'd34,     // issue one 16-bit SDRAM word write
        S_STAGE_WR_WAIT=6'd35,// hold the SDRAM write until the arbiter accepts it
        S_WR_THROTTLE=6'd36,  // [#34] idle WR_THROTTLE cycles after a write (scanout bandwidth)
        S_PIPE_WAIT=6'd37,    // FILL/BLIT handed to comp_pipeline; await blit_done
        // ---- intra-frame STAGE->P_SRC coherency barrier (commit ch1 + inval ch5) ----
        S_STAGE_BARRIER=6'd38,     // pulse stage_barrier after a STAGE completes
        S_STAGE_BARRIER_WAIT=6'd39,// HOLD until the barrier flush/invalidate completes
        // ---- ch0->P_SRC carry-forward barrier (commit ch0 + inval ch5), pre F_SRC_FB BLIT -
        S_DST_BARRIER=6'd40,       // pulse dst_barrier before a carry-forward (F_SRC_FB) BLIT
        S_DST_BARRIER_WAIT=6'd41;  // HOLD until the barrier flush/invalidate completes

    localparam [7:0] OP_NOP=8'd0, OP_END=8'd1, OP_FILL=8'd2, OP_BLIT=8'd3, OP_STAGE=8'd4;
    // [v2 escape-elim] blend_mode now spans 0..5 (ADD=4, MULTIPLY=5). The decode just
    // forwards c_blend to comp_pipeline, which maps it onto comp_mixer modes.
    localparam [7:0] BLEND_KEY=8'd1, BLEND_ALPHA=8'd2, BLEND_PALPHA=8'd3,
                     BLEND_ADD=8'd4, BLEND_MULTIPLY=8'd5;
    localparam [7:0] F_HFLIP=8'h01, F_VFLIP=8'h02, F_COLORKEY=8'h04, F_STAGE_DST=8'h08,
                     F_SRC_SDRAM=8'h10,  // [#34] per-command source mux: this BLIT reads SDRAM
                     F_SRC_FB=8'h20,     // carry-forward: src is a framebuffer written by ch0
                                         // (P_DST) — fire the dst-barrier (commit ch0 +
                                         // invalidate ch5) before this BLIT's P_SRC read.
                     F_COLORMOD=8'h40;   // [v2 escape-elim] _pad bytes carry an RGB888 tint
                                         // (cr,cg,cb) modulating the SOURCE before the blend.
    // Source pixel formats (cmd.format). Both are 16bpp: RGB565 and ARGB4444
    // ({A4,R4,G4,B4}); BLEND_PALPHA just reinterprets the fetched 16-bit source
    // pixel. comp_pipeline owns the source addressing/fetch now.
    localparam [7:0] FMT_RGB565=8'd0, FMT_ARGB4444=8'd1;

    reg  [5:0]  state, rd_ret, wr_ret;
    reg         rd_issued;   // read accepted by the bus, now awaiting dout_ready
    // ---- legacy-FSM master signals (muxed onto mem_* at the bottom) ----
    reg  [AW-1:0] bm_addr;
    reg           bm_rd, bm_wr;
    reg  [63:0]   bm_din;
    reg  [7:0]    bm_be;
    // ---- comp_pipeline (Spec A) routing — the sole render datapath ----
    reg           pipe_start;    // 1-cycle blit_start pulse to comp_pipeline
    reg           pipe_busy;     // 1 while a comp_pipeline blit owns the mem_* bus
    reg           pipe_busy_q;   // [#44 timing] lockstep duplicate of pipe_busy for the owner-mux select (low fanout)
    // comp_pipeline master outputs + done (instantiated at the bottom)
    wire [31:0]   p_mem_addr;
    wire          p_mem_rd, p_mem_wr;
    wire  [7:0]   p_mem_burstcnt;
    wire [63:0]   p_mem_din;
    wire  [7:0]   p_mem_be;
    wire          p_blit_done;
    // comp_pipeline is the only consumer of the read-only SDRAM source port.
    wire [26:0]   p_src_sdram_addr;
    wire          p_src_sdram_rd;
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
    // [collapse-single-source] The per-blit source read is ALWAYS from SDRAM now
    // (single source pipeline). The old C_SRCSEL bit0 (DDR3-vs-SDRAM source mux,
    // `srcsel`) and the DDR3 live-source datapath were removed; the C_SRCSEL control
    // word is still read but ONLY for its throttle field (bits[15:8]).
    reg  [31:0] target_base, cfg_flags, clr_idx;
    reg  [15:0] clear_color;
    reg  [63:0] cmd_qw [0:3];
    reg  [1:0]  fetch_k;

    reg  [7:0]  c_opcode, c_blend, c_format, c_flags, c_alpha;
    reg  [31:0] c_src_off;
    reg  [15:0] c_src_stride, c_src_x, c_src_y, c_w, c_h, c_colorkey, c_color;
    reg  signed [15:0] c_dst_x, c_dst_y;
    // [v2 escape-elim] color-mod (tint) bytes, valid when c_flags & F_COLORMOD.
    reg  [7:0]  c_cmod_r, c_cmod_g, c_cmod_b;

    // ---- DEBUG: live state snapshot for the #34 HW wedge probe (no datapath effect)
    reg  [5:0]  dbg_state_q;
    reg  [23:0] dbg_stuck;            // cycles since `state` last changed (saturating)
    always @(posedge clk) begin
        if (rst) begin dbg_state_q <= 6'd0; dbg_stuck <= 24'd0; end
        else begin
            dbg_state_q <= state;
            if (state != dbg_state_q) dbg_stuck <= 24'd0;
            else if (~&dbg_stuck)     dbg_stuck <= dbg_stuck + 24'd1;
        end
    end
    // [31:24]=stuck>>16 (0xFF=frozen >~167ms), [23]=rd_issued (read accepted, waiting
    // for data = NOT starved), [5:0]=state. The legacy dx/dy fields are retired with
    // the per-pixel renderer; comp_pipeline owns per-pixel progress now, so those
    // bits are zeroed (state+stuck+rd_issued remain the HW wedge post-mortem signal).
    assign dbg = {dbg_stuck[23:16], rd_issued, 8'd0, 9'd0, state};

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
    // [stage-barrier] tracks that stage_barrier_busy was observed HIGH after a
    // barrier request, so S_STAGE_BARRIER_WAIT releases only on the busy FALLING
    // edge (flush+invalidate complete) — never racing past a not-yet-asserted busy.
    reg         barrier_seen_busy;
    // [dst-barrier] same seen-busy guard for the frame-start ch0->ch5 carry-forward
    // barrier: S_DST_BARRIER_WAIT releases only on dst_barrier_busy's FALLING edge.
    reg         dst_barrier_seen_busy;

    // [collapse-single-source] The per-blit source read is HARDWIRED to SDRAM. The
    // old per-command mux (C_SRCSEL `srcsel` & F_SRC_SDRAM) and the DDR3 live-source
    // datapath are gone: every BLIT now fetches its source through comp_pipeline's
    // P_SRC (ch5) cache-ok port. The engine stages all atlas sources DDR3->SDRAM
    // unconditionally, so there is a single source datapath to debug. F_SRC_SDRAM is
    // therefore a no-op (kept in the protocol constants for ring-format compatibility).
    wire src_in_sdram = 1'b1;

    // ---- clip (combinational off decoded c_*) --------------------------
    wire signed [31:0] sdx = c_dst_x, sdy = c_dst_y;
    wire signed [31:0] xe = sdx + c_w, ye = sdy + c_h;
    wire signed [31:0] clip_x0 = (sdx<0)?0:sdx;
    wire signed [31:0] clip_y0 = (sdy<0)?0:sdy;
    wire signed [31:0] clip_x1 = (xe>`FB_W)?`FB_W:xe;
    wire signed [31:0] clip_y1 = (ye>`FB_H)?`FB_H:ye;
    wire empty = (clip_x0>=clip_x1) || (clip_y0>=clip_y1);

    // video control word (drop-in producer): frame_counter[31:2] | buf[1:0]
    wire [31:0] vctrl_val = ((frame_counter + 32'd1) << 2) | {31'd0, target_buf[0]};

    always @(posedge clk) begin
        if (rst) begin
            state<=S_POLL_SUBMIT; bm_rd<=0; bm_wr<=0; bm_be<=0;
            bm_addr<=0; bm_din<=0; idle<=1; frame_counter<=0;
            cmd_idx<=0; fetch_k<=0; submit_reg<=0; done_reg<=0; rd_issued<=0;
            throttle_cnt<=8'd0; throttle_cfg<=8'd0;
            pipe_start<=1'b0;
            src_sdram_we<=1'b0; src_sdram_din<=16'd0; src_sdram_waddr<=27'd0;
            src_sdram_we_burst<=1'b0; src_sdram_din64<=64'd0;
            stage_barrier<=1'b0; barrier_seen_busy<=1'b0;
            dst_barrier<=1'b0; dst_barrier_seen_busy<=1'b0;
        end else begin
            bm_rd<=1'b0;
            pipe_start<=1'b0;     // single-cycle blit_start pulse to comp_pipeline
            stage_barrier<=1'b0;  // single-cycle barrier request unless re-asserted in S_STAGE_BARRIER
            dst_barrier<=1'b0;    // single-cycle barrier request unless re-asserted in S_DST_BARRIER
            src_sdram_we<=1'b0;   // single-cycle write request unless re-asserted (held in S_STAGE_WR_WAIT)
            src_sdram_we_burst<=1'b0; // single-cycle burst-write request unless re-asserted
            case (state)
            S_POLL_SUBMIT: begin
                idle<=1; bm_rd<=1; bm_addr<=`BLTCTRL_QW+`C_SUBMIT;
                rd_ret<=S_POLL_DONE; state<=S_RD_WAIT;
            end
            S_POLL_DONE: begin
                submit_reg<=rd_data[31:0];
                bm_rd<=1; bm_addr<=`BLTCTRL_QW+`C_DONE;
                rd_ret<=S_CHK_NEW; state<=S_RD_WAIT;
            end
            S_CHK_NEW: begin
                done_reg<=rd_data[31:0];
                if (rd_data[31:0]==submit_reg) state<=S_POLL_SUBMIT;   // idle: keep polling
                else begin
                    idle<=0; bm_rd<=1; bm_addr<=`BLTCTRL_QW+`C_CMDCOUNT;
                    rd_ret<=S_GOT_CMDCNT; state<=S_RD_WAIT;
                end
            end
            S_GOT_CMDCNT: begin
                cmd_count<=rd_data[31:0];
                bm_rd<=1; bm_addr<=`BLTCTRL_QW+`C_TARGET;
                rd_ret<=S_GOT_TARGET; state<=S_RD_WAIT;
            end
            S_GOT_TARGET: begin
                target_buf<=rd_data[1:0];
                // C_TARGET==2 -> compose into the OFF-SCREEN bg-cache (no display flip);
                // 0/1 -> framebuffer BUF0/BUF1.
                target_base<=(rd_data[1:0]==2'd2) ? `CACHE_QW :
                             (rd_data[0] ? `FB1_QW : `FB0_QW);
                bm_rd<=1; bm_addr<=`BLTCTRL_QW+`C_FLAGS;
                rd_ret<=S_GOT_FLAGS; state<=S_RD_WAIT;
            end
            S_GOT_FLAGS: begin
                cfg_flags<=rd_data[31:0];
                // fetch C_SRCSEL next (appended control word). bit0 (source mux) is
                // now dead — source is always SDRAM — but the word still carries the
                // f2h write-throttle in bits[15:8], so we still read it.
                bm_rd<=1; bm_addr<=`BLTCTRL_QW+`C_SRCSEL;
                rd_ret<=S_GOT_SRCSEL; state<=S_RD_WAIT;
            end
            S_GOT_SRCSEL: begin
                // [collapse-single-source] bit0 (DDR3-vs-SDRAM source select) ignored:
                // the source read is hardwired to SDRAM. Only the throttle field is used.
                throttle_cfg<=rd_data[15:8];      // [#34] f2h write-throttle (spare bits)
                // C_PIPE bit (bit1) is also a documented no-op: comp_pipeline is the
                // sole renderer and every FILL/BLIT routes to it unconditionally.
                bm_rd<=1; bm_addr<=`BLTCTRL_QW+`C_CLEAR;
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
                    bm_wr<=1; bm_be<=8'hFF; bm_addr<=target_base+clr_idx;
                    bm_din<={4{clear_color}}; clr_idx<=clr_idx+1;
                    wr_ret<=S_CLR_WR; state<=S_WR_WAIT;
                end
            end

            S_FETCH: begin
                if (cmd_idx>=cmd_count) state<=S_FRAME_VCTRL;
                else begin
                    fetch_k<=0; bm_rd<=1; bm_addr<=`RING_QW+cmd_idx*4;
                    rd_ret<=S_COLLECT; state<=S_RD_WAIT;
                end
            end
            S_COLLECT: begin
                cmd_qw[fetch_k]<=rd_data;
                if (fetch_k==2'd3) state<=S_DECODE;
                else begin
                    bm_rd<=1; bm_addr<=`RING_QW+cmd_idx*4+(fetch_k+2'd1);
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
                c_colorkey  <= cmd_qw[3][15:0];   // u32[6][15:0]
                c_alpha     <= cmd_qw[3][23:16];  // u32[6][23:16]
                c_color     <= cmd_qw[3][47:32];  // u32[7][15:0]
                // [v2 escape-elim] color-mod (tint) bytes. WIRE-ABI CONTRACT (host
                // blt_pack_cmd, RTL decode, and the C model MUST agree): the RGB888
                // tint reuses the two free reserved bytes of qw[3] —
                //   cb = u32[6][31:24]  (the legacy/unused "priority" byte)
                //   cr = u32[7][23:16]  (color high byte 0)
                //   cg = u32[7][31:24]  (color high byte 1)
                // i.e. u32[6] = colorkey | alpha<<16 | cb<<24,
                //      u32[7] = color    | cr<<16    | cg<<24.
                c_cmod_b    <= cmd_qw[3][31:24];  // u32[6][31:24]
                c_cmod_r    <= cmd_qw[3][55:48];  // u32[7][23:16]
                c_cmod_g    <= cmd_qw[3][63:56];  // u32[7][31:24]
                state<=S_SETUP;
            end
            S_SETUP: begin
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
                else if (c_opcode==OP_BLIT && (c_flags & F_SRC_FB)) begin
                    // Carry-forward FB->FB copy: its source FB was written by the
                    // compositor via ch0 (P_DST), but this BLIT reads it through ch5
                    // (P_SRC) — a SEPARATE cache. Commit ch0 + invalidate ch5 first so
                    // the source fetch is coherent, THEN dispatch to comp_pipeline.
                    state <= S_DST_BARRIER;
                end
                else begin
                    // FILL/BLIT -> comp_pipeline, the sole render datapath. The decoded
                    // c_* + target_base are stable; pipe_start pulses one cycle and
                    // pipe_busy hands comp_pipeline the mem_* / src_sdram_* bus.
                    pipe_start <= 1'b1;
                    state      <= S_PIPE_WAIT;
                end
            end
            // Carry-forward coherency barrier: pulse dst_barrier and HOLD until it
            // engages (busy rises) and completes (busy falls) — ch0 committed + ch5
            // invalidated — then dispatch the carry-forward BLIT to comp_pipeline.
            // Mirrors the STAGE-barrier seen-busy handshake.
            S_DST_BARRIER: begin
                dst_barrier           <= 1'b1;   // one-cycle request
                dst_barrier_seen_busy <= 1'b0;
                state<=S_DST_BARRIER_WAIT;
            end
            S_DST_BARRIER_WAIT: begin
                if (dst_barrier_busy)           dst_barrier_seen_busy <= 1'b1;
                else if (dst_barrier_seen_busy) begin
                    pipe_start <= 1'b1;
                    state      <= S_PIPE_WAIT;
                end
            end

            // ---- BLT_OP_STAGE DDR3->SDRAM copy (issue #19) ----
            // Read one 64-bit beat from DDR3 at SRC_QW + (off+stage_byte)>>3 (the
            // staged region is qword-aligned: off is qword-aligned in practice and
            // stage_byte advances by 8). The shared read master + S_RD_WAIT carry it.
            S_STAGE_RD: begin
                bm_rd<=1; bm_addr<=`SRC_QW + ((stage_off + stage_byte) >> 3);
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
            // [#44] cache-ok handshake: HOLD src_sdram_we_burst until the cache STAGE
            // channel (ch1) accepts the qword (src_sdram_ok). The default block
            // deasserts we_burst each cycle, so re-assert it while waiting; on ok,
            // let it drop and advance one beat (or finish). (Earlier this treated the
            // write as immediately accepted because the outputs were unconnected — that
            // dropped writes under cache backpressure -> garbage source atlas.)
            S_STAGE_WR_WAIT: begin
                if (src_sdram_ok) begin
                    // write accepted; advance one beat or finish.
                    if (stage_byte + 32'd8 >= stage_size) state<=S_STAGE_BARRIER;
                    else begin
                        stage_byte <= stage_byte + 32'd8;
                        state<=S_STAGE_RD;
                    end
                end else begin
                    src_sdram_we_burst <= 1'b1;   // hold the request until ok
                end
            end

            // [stage-barrier] STAGE finished: the atlas is in cache ch1 but not yet
            // in SDRAM, and ch5 (P_SRC) may hold stale lines for these addresses.
            // Pulse stage_barrier (commit ch1 + invalidate ch5) and HOLD until it
            // completes, so the consuming BLIT's source fetch is coherent. (The engine
            // emits STAGE+BLIT in the same frame, so vsync is too late.)
            S_STAGE_BARRIER: begin
                stage_barrier     <= 1'b1;   // one-cycle request
                barrier_seen_busy <= 1'b0;
                state<=S_STAGE_BARRIER_WAIT;
            end
            // Wait for the barrier to actually engage (busy rises) and then finish
            // (busy falls). Releasing on the falling edge guarantees ch1 is committed
            // and ch5 invalidated before the next command can read P_SRC.
            S_STAGE_BARRIER_WAIT: begin
                if (stage_barrier_busy)      barrier_seen_busy <= 1'b1;
                else if (barrier_seen_busy)  state<=S_NEXT_CMD;
            end

            S_NEXT_CMD: begin cmd_idx<=cmd_idx+1; state<=S_FETCH; end

            // C_PIPE: the FSM holds here (driving no bus traffic — bm_* idle,
            // pipe_busy hands mem_* to comp_pipeline) until the pipelined blit
            // signals blit_done, then advances to the next command.
            S_PIPE_WAIT: if (p_blit_done) state<=S_NEXT_CMD;

            S_FRAME_VCTRL: begin
                // OFF-SCREEN cache pass (target==2): do NOT publish a new frame — skip
                // the vctrl write + frame_counter bump so the scanout keeps displaying
                // the previous (complete) frame while the cache is composed invisibly.
                // Still signals C_DONE below so the engine's handshake completes.
                if (target_buf==2'd2) begin
                    state<=S_WR_DONE;
                end else begin
                    bm_wr<=1; bm_be<=8'h0F; bm_addr<=`VCTRL_QW;
                    bm_din<={32'd0, vctrl_val};
                    frame_counter<=frame_counter+1;
                    wr_ret<=S_WR_DONE; state<=S_WR_WAIT;
                end
            end
            S_WR_DONE: begin
                bm_wr<=1; bm_be<=8'h0F; bm_addr<=`BLTCTRL_QW+`C_DONE;
                bm_din<={32'd0, submit_reg};
                wr_ret<=S_WR_STATUS; state<=S_WR_WAIT;
            end
            S_WR_STATUS: begin
                bm_wr<=1; bm_be<=8'h0F; bm_addr<=`BLTCTRL_QW+`C_STATUS;
                bm_din<=64'd0; wr_ret<=S_POLL_SUBMIT; state<=S_WR_WAIT;
            end

            // Backpressure-safe generic read: hold bm_rd until the bus accepts
            // it (~mem_busy), then await dout_ready. (mem_busy = ddram busy OR not
            // granted by the arbiter; on the never-busy sim model this is a no-op.)
            S_RD_WAIT: begin
                if (!rd_issued) begin
                    bm_rd <= 1'b1;                       // hold request
                    if (!mem_busy) rd_issued <= 1'b1;     // accepted this cycle
                end else if (mem_dout_ready) begin
                    rd_data <= mem_dout; rd_issued <= 1'b0; state <= rd_ret;
                end
            end
            // Backpressure-safe generic write: bm_wr/addr/din/be held from the
            // issue state; clear + advance only once the bus accepts (~mem_busy).
            S_WR_WAIT: if (!mem_busy) begin
                bm_wr <= 1'b0; bm_be <= 8'h00;
                // [#34] after the write is accepted, idle the bus for throttle_cfg cycles
                // so the scanout reader can refill its FIFO (un-throttled back-to-back
                // writes saturate the f2h write FIFO -> ddram_busy -> scanout starves).
                if (throttle_cfg != 8'd0) begin
                    throttle_cnt <= throttle_cfg; state <= S_WR_THROTTLE;
                end else state <= wr_ret;
            end
            // [#34] bus held idle (bm_rd/bm_wr both 0 here) -> the arbiter sees the
            // blitter not requesting and the reader gets the bus. Then resume the FSM.
            S_WR_THROTTLE:
                if (throttle_cnt != 8'd0) throttle_cnt <= throttle_cnt - 8'd1;
                else state <= wr_ret;
            default: state<=S_POLL_SUBMIT;
            endcase
        end
    end

    // ════════════════════════════════════════════════════════════════════════
    //  comp_pipeline: the sole render datapath (Spec A) + mem_* OWNER MUX
    // ════════════════════════════════════════════════════════════════════════
    // comp_pipeline executes one FILL/BLIT at a time. It owns the shared mem_*
    // master ONLY while pipe_busy=1 (set when pipe_start pulses, cleared on
    // blit_done). Outside that window the FSM's bm_* drive the bus for the command
    // ring, screen-clear, STAGE, and status/vctrl writes.
    comp_pipeline u_pipe (
        .clk(clk), .rst(rst),
        .blit_start(pipe_start),
        .c_opcode(c_opcode), .c_blend(c_blend), .c_format(c_format), .c_flags(c_flags),
        .c_src_off(c_src_off), .c_src_stride(c_src_stride),
        .c_src_x(c_src_x), .c_src_y(c_src_y),
        .c_w(c_w), .c_h(c_h), .c_colorkey(c_colorkey), .c_alpha(c_alpha),
        .c_color(c_color),
        .c_cmod_r(c_cmod_r), .c_cmod_g(c_cmod_g), .c_cmod_b(c_cmod_b),  // [v2] tint
        .c_dst_x(c_dst_x), .c_dst_y(c_dst_y),
        .target_base(target_base),
        // shared mem_* inputs (same bus as the FSM)
        .mem_addr(p_mem_addr), .mem_rd(p_mem_rd), .mem_wr(p_mem_wr),
        .mem_burstcnt(p_mem_burstcnt),
        .mem_din(p_mem_din), .mem_be(p_mem_be),
        .mem_dout(mem_dout), .mem_dout_ready(mem_dout_ready), .mem_busy(mem_busy),
        // P_SRC cache-ok channel (Task 5). c_srcsel is hardwired to 1
        // (src_in_sdram=1): every source read goes through the SDRAM P_SRC port —
        // there is no DDR3 live-source path anymore (single source pipeline).
        .c_srcsel(src_in_sdram),
        .p0_addr(p_src_sdram_addr), .p0_rd(p_src_sdram_rd),
        .p0_dout(p0_dout), .p0_ok(p0_ok),
        .blit_done(p_blit_done));

    // owner mux: comp_pipeline drives the bus only while pipe_busy; otherwise the
    // FSM's bm_* drive it for ring/clear/STAGE/status traffic.
    //
    // [#44 timing] The select uses pipe_busy_q — a LOCKSTEP DUPLICATE of pipe_busy
    // dedicated to these ~100 bits of owner mux. pipe_busy itself also fans out into
    // the FSM + dbg, so the fitter cannot isolate it; the critical setup path
    // pipe_busy -> mem_addr mux -> vram_demux is_fb -> ddr_blitter_arb ddram_we ->
    // HPS f2sdram failed setup by -0.068ns. pipe_busy_q is set/cleared by the SAME
    // conditions on the SAME cycle (identical value every cycle — no functional or
    // latency change), but as a low-fanout register the placer can put it next to the
    // demux, shortening the select routing. Source mux (p0_*) keeps pipe_busy: it is
    // not on the failing f2sdram path.
    assign mem_addr     = pipe_busy_q ? p_mem_addr     : bm_addr;
    assign mem_rd       = pipe_busy_q ? p_mem_rd       : bm_rd;
    assign mem_wr       = pipe_busy_q ? p_mem_wr       : bm_wr;
    assign mem_burstcnt = pipe_busy_q ? p_mem_burstcnt : 8'd1;   // FSM traffic is single-beat
    assign mem_din      = pipe_busy_q ? p_mem_din      : bm_din;
    assign mem_be       = pipe_busy_q ? p_mem_be       : bm_be;

    // P_SRC read port (read-only): comp_pipeline is the only renderer, so it drives
    // the cache-ok p0_* source port directly (idle p0_rd=0 when not fetching). The
    // write/STAGE source ports (src_sdram_we/din/waddr/we_burst/din64) stay driven by
    // the FSM's STAGE path — comp_pipeline never stages.
    assign p0_addr = p_src_sdram_addr;
    assign p0_rd   = p_src_sdram_rd;

    // pipe_busy bookkeeping: raised when pipe_start pulses (S_SETUP hands a blit
    // to the pipeline), lowered on blit_done. pipe_busy_q is a LOCKSTEP DUPLICATE
    // (same set/clear, same cycle) used ONLY for the owner-mux select — see the mux
    // above ([#44 timing] fanout-isolation for the f2sdram setup path).
    always @(posedge clk) begin
        if (rst) begin
            pipe_busy   <= 1'b0;
            pipe_busy_q <= 1'b0;
        end else begin
            if (pipe_start)       begin pipe_busy <= 1'b1; pipe_busy_q <= 1'b1; end
            else if (p_blit_done) begin pipe_busy <= 1'b0; pipe_busy_q <= 1'b0; end
        end
    end
endmodule
`default_nettype wire
