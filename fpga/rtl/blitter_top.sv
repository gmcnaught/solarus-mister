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
`include "comp_clut.vh"

module blitter_top #(
    parameter AW = 32
) (
    input  wire          clk,
    input  wire          rst,
    input  wire          vs,          // scanout vblank (synced) — gates the work->scan snapshot
    // [OSD mirror] raw status[] levels sampled once per frame (S_WR_STATUS) into
    // C_STATUS low32 bits[1:0] — this reuses the control block's dead low32 (it
    // was always written 0 and never read by the ARM side) instead of adding a
    // new register/offset. See docs/superpowers/specs/2026-07-07-osd-driven-
    // features-design.md for why a new register was the original sketch.
    input  wire          osd_restart, // status[19]: Restart Quest (momentary toggle)
    input  wire          osd_fps_on,  // status[20]: FPS Overlay on/off
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
    // ---- on-chip framebuffer (comp_fbram) dest port [FB-in-BRAM] ----------------
    // comp_pipeline's composite destination now lives in on-chip M10K (comp_fbram),
    // wired up at the integration layer (Solarus.sv). u_pipe drives these directly.
    // (Threaded out in Task 1; the mixer is routed through them at the Task 2 cutover.)
    output wire          fb_wr_en,
    output wire [14:0]   fb_wr_qw,
    output wire [1:0]    fb_wr_lane,
    output wire [15:0]   fb_wr_pix,
    output wire          fb_rd_en,        // muxed: comp_pipeline RMW read, OR the snapshot source read
    output wire [14:0]   fb_rd_qw,
    input  wire [63:0]   fb_rd_qword,
    // ---- snapshot (work->scan) write port to comp_fbram [FB-in-BRAM double-buffer] ----
    // Once per frame, during vblank, the entire WORK buffer is copied to the SCAN buffer
    // so the scanout reads a stable (tear-free) image. Driven by u_snap (fbram_snapshot).
    output wire          fb_snap_we,
    output wire [14:0]   fb_snap_qw,
    output wire [63:0]   fb_snap_qword,
    // ---- ch0 (P_DST) write port [Phase 3b bg-plane bake] -----------------------
    // sdram_fb_cache's ch0 (P_DST) write side is idle since PR #49 retired the
    // SDRAM-dest compositor (FB-in-BRAM composites on-chip now). Repurposed here
    // for the one-time OP_BGPLANE_WRITE bake. Port names match sdram_fb_cache's
    // own dst_* ports 1:1 (sdram_fb_cache.sv:79-85) for a trivial direct connection
    // at the integration layer. Cache-ok protocol: dst_wr held until dst_ok
    // (mirrors vram_demux's sd_wr/sd_ok hold, vram_demux.sv:8).
    output wire          dst_wr,
    output wire [26:0]   dst_addr,   // byte address (qword-aligned)
    output wire [63:0]   dst_din,
    output wire [7:0]    dst_wdsn,   // active-low byte-select; full write = 8'h00
    input  wire          dst_ok,
    // bgw_active: 1 while the drain FSM below is actively holding a ch0 write
    // request (dst_wr asserted, awaiting dst_ok). The integration layer
    // (Solarus.sv) uses this as a priority-mux select so this rare one-time
    // bake can share ch0's write side with vram_demux without a multi-driver
    // conflict — see that file's bgw_active-gated dst_wr/addr/din/wdsn mux.
    output wire          bgw_active,
    // ---- SDRAM STAGE WRITE path (issue #19, BLT_OP_STAGE) ----------------------
    // A BLT_OP_STAGE command copies a source region from DDR3 (SRC_QW + off) into
    // SDRAM at the heap-relative byte offset `off` (exactly the address the SDRAM
    // source read uses). These single-16-bit-word write outputs route through the
    // cache STAGE channel (ch1). They are IDLE (we=0) outside staging.
    output reg           src_sdram_we,     // request one 16-bit word write (held until granted)
    output reg  [15:0]   src_sdram_din,    // the word to write
    // [bgplane bake -> STAGE reroute] the 3 burst-write outputs are now MUXED (see the
    // assigns near u_bgw): the OP_STAGE atlas FSM drives them via stage_*_fsm regs, and
    // the OP_BGPLANE_WRITE bake stream overrides them whenever bgw_active. They are
    // therefore `wire` (continuous-assign) rather than FSM-driven `reg`.
    output wire [26:0]   src_sdram_waddr,  // byte address (bit0=0, 16-bit mode) of the word
    // ---- BL=4 BURST staging write (issue #19) ----
    // One 64-bit DDR3 beat -> ONE SDRAM burst write (4 words) instead of 4 single
    // writes. src_sdram_waddr carries the 8-byte-aligned beat byte address.
    output wire          src_sdram_we_burst, // request one 4-word burst write (held until granted)
    output wire [63:0]   src_sdram_din64,    // the 64-bit beat to burst-write
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
    // [retired 2026-06-26] The ch0->P_SRC carry-forward coherency barrier (dst_barrier)
    // is gone: FB-in-BRAM composites into the on-chip comp_fbram, so the engine no longer
    // emits the F_SRC_FB SDRAM FB->FB carry-forward copy (single_buf full-redraw) and ch0
    // (P_DST) is never written. The stage_barrier (ch1 STAGE atlas -> ch5 P_SRC) stays.
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
        // [FB-in-BRAM] CLEAR routes through comp_pipeline as a full-screen FILL
        S_CLR_FILL=6'd12,   S_CLR_FILL_WAIT=6'd13,
        // ---- BLT_OP_TILELIST batch FSM (#52 dumb emitter) ----
        // Read N 12-byte entries from the TL buffer (DDR3, bm_* master) and issue
        // each as a per-entry blit through the SAME comp_pipeline path OP_BLIT uses.
        S_TL_FETCH0=6'd15,  S_TL_FETCH1=6'd16, S_TL_FETCH2=6'd17,
        S_TL_LATCH=6'd18,   S_TL_ISSUE=6'd25,  S_TL_WAIT=6'd26,
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
        // (6'd40/6'd41 retired with the dst_barrier carry-forward barrier)
        // ---- work->scan snapshot [FB-in-BRAM double-buffer] -------------------------
        S_SNAP_WAIT=6'd42,         // frame composited: wait for vblank rising, then trigger
        S_SNAP_BUSY=6'd43,         // snapshot started: wait for busy to assert
        S_SNAP_DRAIN=6'd44,        // wait for the work->scan copy to finish, then poll submit
        // ---- [#52 resident / Tier B] BLT_OP_FRT_UPLOAD + BLT_OP_TILELIST_RES ----
        S_FRT_RD=6'd45,     S_FRT_WR=6'd46,    // stream FRT DDR -> frt_bram (once/scene)
        S_CFT_RD=6'd47,     S_CFT_WR=6'd48,    // preload CFT DDR -> cft array (per command)
        S_TLR_FETCH=6'd49,  S_TLR_LATCH=6'd50, // read one 8-byte resident entry (pid,dst)
        S_TLR_CFT=6'd51,    S_TLR_FRT=6'd52,   // cft_mem[pid] -> frt_bram[pid*MAXF+f]
        S_TLR_SLICE=6'd53,                     // slice resolved rect -> c_* -> S_TL_ISSUE
        // ---- [Phase 3b] BLT_OP_BGPLANE_WRITE: one-time WORK->SDRAM plane bake ----
        // Not vsync-gated (unlike S_SNAP_WAIT/BUSY/DRAIN): this trigger fires
        // immediately, mid-frame. bgw_busy (fbram_to_sdram's own `busy` output,
        // wired straight through at the u_bgw instantiation below) stays high until
        // the LAST write has been ACCEPTED by ch0 (dst_ok), not merely produced, so
        // 2 states (mirroring S_SNAP_BUSY+S_SNAP_DRAIN's roles) suffice.
        S_BGW_WAIT=6'd54,          // OP_BGPLANE_WRITE decoded: bgw_start pulsed; wait for bgw_busy to rise
        S_BGW_BUSY=6'd55,          // wait for bgw_busy to fall (last write accepted by ch0)
        // ---- [PAL8 v1] BLT_OP_CLUT_UPLOAD: stream CLUTBUF DDR -> clut_bram ----
        S_CLUT_RD=6'd56,    S_CLUT_WR=6'd57;   // mirrors S_FRT_RD/S_FRT_WR

    localparam [7:0] OP_NOP=8'd0, OP_END=8'd1, OP_FILL=8'd2, OP_BLIT=8'd3, OP_STAGE=8'd4;
    // [v2 escape-elim] blend_mode now spans 0..5 (ADD=4, MULTIPLY=5). The decode just
    // forwards c_blend to comp_pipeline, which maps it onto comp_mixer modes.
    localparam [7:0] BLEND_KEY=8'd1, BLEND_ALPHA=8'd2, BLEND_PALPHA=8'd3,
                     BLEND_ADD=8'd4, BLEND_MULTIPLY=8'd5;
    localparam [7:0] F_HFLIP=8'h01, F_VFLIP=8'h02, F_COLORKEY=8'h04, F_STAGE_DST=8'h08,
                     F_SRC_SDRAM=8'h10,  // [#34] per-command source mux: this BLIT reads SDRAM
                     F_SRC_FB=8'h20,     // [retired] was the carry-forward FB->FB copy flag;
                                         // no longer emitted (FB-in-BRAM), now a no-op. Kept in
                                         // the protocol constants for ring-format compatibility.
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
    // ---- work->scan snapshot routing [FB-in-BRAM double-buffer] ----
    wire          pipe_fb_rd_en; wire [14:0] pipe_fb_rd_qw;  // comp_pipeline's work-read (pre-mux)
    wire          snap_busy, snap_rd_en; wire [14:0] snap_rd_qw;
    reg           snap_start;    // 1-cycle work->scan snapshot trigger
    // ---- [Phase 3b] OP_BGPLANE_WRITE: one-time WORK->SDRAM plane-write trigger ----
    reg           bgw_start;       // 1-cycle trigger to fbram_to_sdram
    reg  [23:0]   bgw_base_qw;     // absolute plane qword offset for this cell
    reg  [23:0]   bgw_stride_qw;   // this map's plane row stride (qwords)
    // [ARGB4444 plane bake] latched from BLT_F_BGCOV at the OP_BGPLANE_WRITE
    // S_SETUP decode below.
    reg           bgw_argb4444;    // 1=pack the streamed plane as ARGB4444 via u_bgcov
    wire          bgw_busy;        // forward-declared: driven near u_bgw below, read by
                                    // the S_BGW_WAIT/BUSY FSM states above it in the file
    // [ARGB4444 plane bake] forward-declared (same reason as bgw_busy above):
    // u_bgcov (bgplane_coverage) is instantiated after u_bgw in this file, but
    // u_bgw's rd_cov port needs bgcov_rd_nibble wired in at ITS instantiation
    // site, which is textually earlier.
    wire [3:0]    bgcov_rd_nibble;
    // [#104] Synchronize vs (scanout vblank; may cross from the video clock) through a
    // 3-FF chain BEFORE the rising-edge detect, detecting between the two RESOLVED stages
    // ([2]&[1]). The old single vs_q edge-detected a still-async vs -> a metastable sample
    // could mis-time the WORK->SCAN snapshot trigger (S_SNAP_WAIT). +1-2 clk latency is
    // negligible for a per-frame vblank.
    reg   [2:0]   vs_sync;
    wire          vs_rise = ~vs_sync[2] & vs_sync[1];
    always @(posedge clk or posedge rst) begin
        if (rst) vs_sync <= 3'b0;
        else     vs_sync <= {vs_sync[1:0], vs};
    end
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
    // ── per-frame perf counters (HW attribution: A9 vs fabric) ──────────────────
    // perf_frame_cyc counts clk_sys cycles the fabric is busy on a frame (from the
    // submit/done mismatch that starts it, through the done write-back); perf_pipe_cyc
    // counts the subset where comp_pipeline owns the bus (pipe_busy). Both reset at
    // frame start and are published in the HIGH 32 bits of the C_DONE / C_STATUS
    // control qwords (the low 32 hold done_seq / status; high 32 were unused). The A9
    // reads them via devmem at C_DONE+4 / C_STATUS+4. fabric_busy/pipe_busy vs the
    // vsync interval (0x3A070000) tells you whether the A9 or the fabric is the limit.
    reg  [31:0] perf_frame_cyc, perf_pipe_cyc;
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

    // [ARGB4444 plane bake] bgplane_coverage's wr_clear select. High for the whole
    // duration of a BLT_F_BGCOV-flagged OP_FILL -- gates wr_clear so this fill's
    // own pixel-write loop clears coverage instead of setting it. Combinational:
    // c_opcode/c_flags are already latched (S_DECODE) and held stable for the
    // whole blit (S_DECODE through blit completion), same lifetime pipe_start/
    // pipe_busy already rely on. (Task 1 stub was tied 0 here; this is that
    // one-line RHS swap.)
    wire c_bgcov_clear = (c_opcode == OP_FILL) && ((c_flags & 8'h80) != 0);

    // [PAL8 v1.1] per-blit palette selector + CLUT index base offset, packed into
    // c_color (pal_id<<8 | base_off) — meaningful only when c_format==COMP_PAL8,
    // but harmless (unused) otherwise. pal_id is 5 bits (bits[12:8]) -> 32 banks.
    wire [4:0] c_pal_id   = c_color[12:8];
    wire [7:0] c_base_off = c_color[7:0];

    // ---- BLT_OP_TILELIST batch state (#52) ----
    // A TILELIST header reuses the blit-rect fields for batch params (see the C
    // reference blt_execute): w|h<<16 = entry count N; dst_x|dst_y<<16 = byte
    // offset of the N-entry array within the TL buffer. The shared texture/blend
    // params (c_src_off/c_src_stride/c_blend/c_format/c_flags/c_alpha/c_colorkey/
    // c_color/tint) stay latched from the header and apply to every entry; only the
    // per-entry rect (src_x/src_y/w/h/dst_x/dst_y) is overwritten in S_TL_LATCH.
    // (The header's src_x/src_y carry the tileset texture bounds — informational;
    //  the bit-exact golden does not use them, so they are not separately latched.)
    reg  [31:0] tl_count;       // N (entry count)
    reg  [31:0] tl_entry_ptr;   // entry-array byte offset within the TL buffer
    reg  [31:0] tl_idx;         // current entry index
    reg  [31:0] tl_byte;        // running byte offset of the current entry (= idx*12)
    reg  [63:0] tl_qw0, tl_qw1; // first two qwords of the 3-qword entry read window
    reg  [5:0]  tl_bitoff;      // bit offset of the entry within {qw2,qw1,qw0} (0..56)
    // Each 12-byte entry can straddle qword boundaries; read 3 consecutive qwords
    // (24-byte window) so any byte alignment of tl_entry_ptr is covered, then
    // right-shift to the entry's first byte and slice the 6 little-endian fields.
    wire [31:0] tl_entry_byte = tl_entry_ptr + tl_byte;
    wire [28:0] tl_entry_qw   = `TL_BUF_QW + tl_entry_byte[31:3];   // byte>>3 + base
    wire [191:0] tl_window    = {rd_data, tl_qw1, tl_qw0} >> tl_bitoff;

    // ---- [#52 resident / Tier B] BLT_OP_TILELIST_RES + FRT/CFT tables ----
    // tl_res selects the resident path (8-byte pattern-indexed entries) when the
    // tile-list batch state above is driven by OP_TILELIST_RES; the TILELIST state
    // (12-byte resolved entries) leaves it 0. tl_byte advances by 8 (res) vs 12.
    reg          tl_res;            // 1 = TILELIST_RES (resident) entry loop
    reg  [31:0]  frt_count;         // FRT_UPLOAD qword count
    reg  [31:0]  frt_idx;           // FRT_UPLOAD write index
    reg  [31:0]  cft_idx;           // CFT preload qword index (0..MAXP/4-1)
    reg  [15:0]  res_pid;           // current entry pattern_id
    reg  signed [15:0] res_dx, res_dy;  // current entry dst (latched, applied after resolve)
    // [#52 camera-independent] signed per-batch dst bias (map-coord -> screen),
    // latched from the header's src_x/src_y slots at OP_TILELIST_RES decode and
    // added to every resolved entry's dst in S_TLR_SLICE. (c_src_x/c_src_y are
    // overwritten per entry from frt_q, so bias must be latched separately.)
    reg  signed [15:0] res_bias_x, res_bias_y;
    // frame-rect table: MAXP*MAXF qwords, {h,w,src_y,src_x} (LE). Single write port
    // (FRT_UPLOAD) + single registered read (resolve) -> infers M10K. Explicit
    // ramstyle (Task 3 LAB-overflow chase, final candidate from fix-timing's
    // static sweep of the whole fpga/ tree): same AUTO-inference-fragility class
    // as bgplane_coverage.sv (Task 1) and comp_src_linebuf.sv/comp_pipeline.sv's
    // span table (this task) -- don't rely on AUTO here either.
    (* ramstyle = "no_rw_check, M10K" *) reg  [63:0]  frt_bram [0:MAXP*MAXF-1];
    reg  [63:0]  frt_q;
    // current-frame table: MAXP u16, written 4-wide during CFT preload (small -> flops),
    // registered read into cft_q at resolve time.
    reg  [15:0]  cft_mem [0:MAXP-1];
    reg  [15:0]  cft_q;
    // 8-byte resident entry address (one aligned qword: pattern_id|dst_x<<16|dst_y<<32).
    wire [31:0]  tlr_entry_byte = tl_entry_ptr + tl_byte;
    wire [28:0]  tlr_entry_qw   = `TL_BUF_QW + tlr_entry_byte[31:3];
    // frame-rect address = pattern_id*MAXF + final_frame_index (MAXF=8 -> pid<<3 | f).
    wire [$clog2(MAXP*MAXF)-1:0] frt_addr =
        (res_pid[$clog2(MAXP)-1:0] << 3) + cft_q[2:0];

    // ---- [PAL8 v1] CLUT (palette lookup table) BRAM + upload FSM ------------------
    // BLT_OP_CLUT_UPLOAD streams `CLUT_BANKS*`CLUT_ENTRIES 32-bit entries (one per
    // 64-bit DDR qword, low 32 bits; high 32 unused/zero on the wire) from the
    // `CLUT_BUF_QW DDR region into clut_bram, mirroring FRT_UPLOAD's frt_bram
    // streaming FSM (S_FRT_RD/S_FRT_WR) exactly. clut_cnt/clut_idx play the role of
    // frt_count/frt_idx.
    reg  [31:0]  clut_cnt;          // CLUT_UPLOAD qword count (== entry count)
    reg  [31:0]  clut_idx;          // CLUT_UPLOAD write index
    // Same ramstyle attr as frt_bram (Task 3 LAB-overflow chase): don't rely on
    // AUTO inference here either. 2048 x 32b (CLUT_BANKS*CLUT_ENTRIES entries).
    (* ramstyle = "no_rw_check, M10K" *) reg  [31:0]  clut_bram [0:`CLUT_BANKS*`CLUT_ENTRIES-1];
    reg  [31:0]  clut_q;
    // [Task 1.2] clut_rd_addr is now internal — driven by comp_pipeline (u_pipe)
    // combinationally from its served index (see comp_pipeline.sv's clut_rd_addr
    // assign) and consumed back into u_pipe.clut_rd_data below. Registered read
    // keeps clut_bram inferred as M10K (not flops), matching frt_bram's frt_q
    // read discipline.
    wire [12:0]  pipe_clut_addr;   // [PAL8 v1.1] 13 bits: 32 banks*256 = 8192 clut_bram entries.
                                   // driven by u_pipe's clut_rd_addr output (connected in
                                   // the port map below). MUST be a real port connection, not
                                   // a hierarchical reference (u_pipe.clut_rd_addr): Quartus
                                   // A&S rejects hierarchical reads of an unconnected output
                                   // (Error 10207) though iverilog accepts them.
    always @(posedge clk) clut_q <= clut_bram[pipe_clut_addr];

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

    // ---- OSD Restart Quest: sticky pulse latch ----------------------------------
    // status[19] (T[19] CONF_STR type) is a MOMENTARY TRIGGER: Main_MiSTer pulses it
    // briefly then clears it — it is not held as a persistent level. S_WR_STATUS only
    // samples once per composited frame (~60Hz), far slower than the pulse width, so a
    // raw level read (the original implementation) essentially never catches it. This
    // latch runs every clk_sys cycle (~98MHz) so it cannot miss the pulse, and holds
    // the pending flag until S_WR_STATUS consumes (and clears) it — guaranteeing the
    // ARM side sees exactly one clean rising edge per OSD activation.
    reg osd_restart_pending;
    reg osd_restart_prev;
    always @(posedge clk) begin
        if (rst) begin
            osd_restart_pending <= 1'b0;
            osd_restart_prev    <= 1'b0;
        end else begin
            osd_restart_prev <= osd_restart;
            if (osd_restart && !osd_restart_prev)
                osd_restart_pending <= 1'b1;
            else if (state == S_WR_STATUS)
                osd_restart_pending <= 1'b0;
        end
    end

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
    // [bgplane bake -> STAGE reroute] the OP_STAGE atlas FSM's private copies of the
    // three burst-write outputs; the port wires src_sdram_we_burst/din64/waddr mux
    // between these and the OP_BGPLANE_WRITE bake stream on bgw_active (see near u_bgw).
    reg          stage_we_burst_fsm;
    reg  [63:0]  stage_din64_fsm;
    reg  [26:0]  stage_waddr_fsm;
    // [stage-barrier] tracks that stage_barrier_busy was observed HIGH after a
    // barrier request, so S_STAGE_BARRIER_WAIT releases only on the busy FALLING
    // edge (flush+invalidate complete) — never racing past a not-yet-asserted busy.
    reg         barrier_seen_busy;

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
            perf_frame_cyc<=32'd0; perf_pipe_cyc<=32'd0;
            throttle_cnt<=8'd0; throttle_cfg<=8'd0;
            pipe_start<=1'b0;
            src_sdram_we<=1'b0; src_sdram_din<=16'd0; stage_waddr_fsm<=27'd0;
            stage_we_burst_fsm<=1'b0; stage_din64_fsm<=64'd0;
            stage_barrier<=1'b0; barrier_seen_busy<=1'b0;
            snap_start<=1'b0;   // [#104] vs edge-detect moved to the dedicated vs_sync 3-FF chain
            tl_count<=32'd0; tl_entry_ptr<=32'd0; tl_idx<=32'd0; tl_byte<=32'd0;
            tl_qw0<=64'd0; tl_qw1<=64'd0; tl_bitoff<=6'd0;
            tl_res<=1'b0; frt_count<=32'd0; frt_idx<=32'd0; cft_idx<=32'd0;
            clut_cnt<=32'd0; clut_idx<=32'd0;
            res_pid<=16'd0; res_dx<=16'sd0; res_dy<=16'sd0; frt_q<=64'd0; cft_q<=16'd0;
            res_bias_x<=16'sd0; res_bias_y<=16'sd0;
            // [ARGB4444 plane bake] bgw_argb4444 is only assigned inside the
            // OP_BGPLANE_WRITE branch below, so it needs an explicit reset --
            // without one it would read X before the first bake ever runs,
            // corrupting u_bgw's argb4444_mode input (and hence its
            // raw-RGB565 fallback path) even when no bake is running.
            bgw_argb4444<=1'b0;
        end else begin
            bm_rd<=1'b0;
            pipe_start<=1'b0;     // single-cycle blit_start pulse to comp_pipeline
            stage_barrier<=1'b0;  // single-cycle barrier request unless re-asserted in S_STAGE_BARRIER
            src_sdram_we<=1'b0;   // single-cycle write request unless re-asserted (held in S_STAGE_WR_WAIT)
            stage_we_burst_fsm<=1'b0; // single-cycle burst-write request unless re-asserted
            snap_start<=1'b0;     // single-cycle work->scan snapshot trigger
            // [#104] vs_rise now comes from the dedicated vs_sync 3-FF synchronizer

            // per-frame perf accumulation (idle=1 only while polling between frames;
            // a frame-start reset in S_CHK_NEW overrides this on its cycle via NBA).
            if (!idle) begin
                perf_frame_cyc <= perf_frame_cyc + 32'd1;
                if (pipe_busy) perf_pipe_cyc <= perf_pipe_cyc + 32'd1;
            end

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
                    perf_frame_cyc<=32'd0; perf_pipe_cyc<=32'd0;   // frame start: reset perf
                end
            end
            S_GOT_CMDCNT: begin
                cmd_count<=rd_data[31:0];
                bm_rd<=1; bm_addr<=`BLTCTRL_QW+`C_TARGET;
                rd_ret<=S_GOT_TARGET; state<=S_RD_WAIT;
            end
            S_GOT_TARGET: begin
                target_buf<=rd_data[1:0];
                // 0/1 -> framebuffer BUF0/BUF1. (The off-screen bg-cache pass, C_TARGET==2
                // -> CACHE_QW, is retired: the bg-cache is disabled and single-buffer mode
                // never emits target 2.)
                target_base<=(rd_data[0] ? `FB1_QW : `FB0_QW);
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
                if (cfg_flags[0]) begin
                    // [FB-in-BRAM] CLEAR-before-list: the old bm_* SDRAM clear loop
                    // (S_CLR_WR, now dead) wrote the SDRAM FB, which is no longer the
                    // framebuffer. Route the clear through comp_pipeline as a full-screen
                    // FILL(clear_color) so it writes the on-chip comp_fbram via fb_wr_*.
                    c_opcode    <= 8'd2;          // OP_FILL
                    c_blend     <= 8'd0;
                    c_format    <= 8'd0;
                    c_flags     <= 8'd0;          // no colour-mod / flip / key
                    c_src_off   <= 32'd0; c_src_stride <= 16'd0;
                    c_src_x     <= 16'd0; c_src_y <= 16'd0;
                    c_w         <= 16'd320; c_h <= 16'd240;
                    c_colorkey  <= 16'd0; c_alpha <= 8'd0;
                    c_color     <= rd_data[15:0]; // clear_color is the FILL colour
                    c_cmod_r    <= 8'd255; c_cmod_g <= 8'd255; c_cmod_b <= 8'd255; // identity
                    c_dst_x     <= 16'sd0; c_dst_y <= 16'sd0;
                    state       <= S_CLR_FILL;
                end
                else begin cmd_idx<=0; fetch_k<=0; state<=S_FETCH; end
            end
            // Dispatch the full-screen clear FILL to comp_pipeline, then start the
            // ring command list (mirrors the FILL/BLIT dispatch in S_SETUP, but the
            // post-blit return is S_FETCH instead of S_NEXT_CMD).
            S_CLR_FILL: begin
                pipe_start <= 1'b1;
                state      <= S_CLR_FILL_WAIT;
            end
            S_CLR_FILL_WAIT: if (p_blit_done) begin
                cmd_idx<=0; fetch_k<=0; state<=S_FETCH;
            end
            // (dead since FB-in-BRAM — kept to avoid disturbing wr_ret references)
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
                else if (c_opcode==OP_TILELIST) begin
                    // BLT_OP_TILELIST: w|h<<16 = N, dst_x|dst_y<<16 = entry-array
                    // byte offset. Shared params stay in c_*; each of the N entries
                    // is read from the TL buffer and issued as a per-entry blit.
                    // (Must precede the `empty` test below — c_w/c_h here are N, not
                    //  a rect, so the clip math would be meaningless.) N==0 => no-op.
                    tl_count     <= {c_h, c_w};
                    tl_entry_ptr <= {c_dst_y, c_dst_x};
                    tl_idx       <= 32'd0;
                    tl_byte      <= 32'd0;
                    tl_res       <= 1'b0;
                    // [static tile-list] latch the header per-batch dst bias (src_x/src_y
                    // slots) so S_TL_LATCH can bias each 12-byte entry's map-coord dst.
                    res_bias_x   <= $signed(c_src_x);
                    res_bias_y   <= $signed(c_src_y);
                    state        <= ({c_h, c_w} == 32'd0) ? S_NEXT_CMD : S_TL_FETCH0;
                end
                else if (c_opcode==OP_FRT_UPLOAD) begin
                    // [#52 resident] stream {c_h,c_w} qwords of the frame-rect table from
                    // the FRT DDR region into frt_bram. No framebuffer effect.
                    frt_count <= {c_h, c_w};
                    frt_idx   <= 32'd0;
                    state     <= ({c_h, c_w} == 32'd0) ? S_NEXT_CMD : S_FRT_RD;
                end
                else if (c_opcode==OP_TILELIST_RES) begin
                    // [#52 resident] pattern-indexed tile list. Same header packing as
                    // TILELIST (w|h<<16=N, dst_x|dst_y<<16=entry byte offset); each entry
                    // is 8 bytes {pattern_id, dst_x, dst_y}. Preload the per-pattern
                    // current-frame table (CFT) into cft_mem, then run the entry loop.
                    tl_count     <= {c_h, c_w};
                    tl_entry_ptr <= {c_dst_y, c_dst_x};
                    tl_idx       <= 32'd0;
                    tl_byte      <= 32'd0;
                    tl_res       <= 1'b1;
                    cft_idx      <= 32'd0;
                    // [#52 camera-independent] latch the header's per-batch dst bias
                    // (src_x/src_y slots); c_src_x/c_src_y are not read again until
                    // S_TLR_SLICE overwrites them from frt_q, so latch here.
                    res_bias_x   <= $signed(c_src_x);
                    res_bias_y   <= $signed(c_src_y);
                    state        <= ({c_h, c_w} == 32'd0) ? S_NEXT_CMD : S_CFT_RD;
                end
                else if (c_opcode==OP_CLUT_UPLOAD) begin
                    // [PAL8 v1] stream {c_h,c_w} qwords (== entries) of the CLUT from
                    // the CLUTBUF DDR region into clut_bram. No framebuffer effect.
                    clut_cnt <= {c_h, c_w};
                    clut_idx <= 32'd0;
                    state    <= ({c_h, c_w} == 32'd0) ? S_NEXT_CMD : S_CLUT_RD;
                end
                else if (c_opcode==OP_BGPLANE_WRITE) begin
                    // [Phase 3b] one-time WORK->SDRAM plane bake. Same dst_x|dst_y<<16
                    // header field-reuse idiom as OP_TILELIST/OP_TILELIST_RES's
                    // tl_entry_ptr<={c_dst_y,c_dst_x} above: here it packs the cell's
                    // ABSOLUTE destination plane qword offset (Task 1's
                    // bgplane_cell_plane_byte_offset(...)/8, host-computed). src_x
                    // carries the map's plane row stride (qwords); no src/bias fields.
                    bgw_base_qw   <= {c_dst_y, c_dst_x};
                    bgw_stride_qw <= {8'd0, c_src_x};
                    bgw_argb4444  <= (c_flags & 8'h80) != 0;   // [ARGB4444 plane bake] BLT_F_BGCOV
                    bgw_start     <= 1'b1;
                    state         <= S_BGW_WAIT;
                end
                else if (empty)             state<=S_NEXT_CMD;
                else begin
                    // FILL/BLIT -> comp_pipeline, the sole render datapath. The decoded
                    // c_* + target_base are stable; pipe_start pulses one cycle and
                    // pipe_busy hands comp_pipeline the mem_* / src_sdram_* bus.
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
                stage_waddr_fsm    <= (stage_sdram_off + stage_byte) & 27'h7FFFFF8; // 8-byte align (#32 decoupled dest)
                stage_din64_fsm    <= stage_beat;
                stage_we_burst_fsm <= 1'b1;
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
                    stage_we_burst_fsm <= 1'b1;   // hold the request until ok
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

            // ---- BLT_OP_TILELIST per-entry loop (#52) ----
            // Read the current 12-byte entry as a 3-qword window from the TL buffer
            // (bm_* master, same DDR3 path as the command ring), slice the rect into
            // c_*, then issue it through comp_pipeline exactly like OP_BLIT. Entry
            // reads (bm_*) and comp source reads (p0_*/P_SRC) are on disjoint ports
            // AND sequential (fetch -> issue -> wait done -> next), so no bus clash.
            S_TL_FETCH0: begin
                bm_rd<=1'b1; bm_addr <= tl_entry_qw;
                tl_bitoff <= {tl_entry_byte[2:0], 3'b0};   // (byte & 7) * 8
                rd_ret<=S_TL_FETCH1; state<=S_RD_WAIT;
            end
            S_TL_FETCH1: begin
                tl_qw0 <= rd_data;
                bm_rd<=1'b1; bm_addr <= tl_entry_qw + 29'd1;
                rd_ret<=S_TL_FETCH2; state<=S_RD_WAIT;
            end
            S_TL_FETCH2: begin
                tl_qw1 <= rd_data;
                bm_rd<=1'b1; bm_addr <= tl_entry_qw + 29'd2;
                rd_ret<=S_TL_LATCH; state<=S_RD_WAIT;
            end
            S_TL_LATCH: begin
                // rd_data now holds qw2; tl_window = {qw2,qw1,qw0} >> tl_bitoff.
                // Entry layout (LE): u16 src_x,src_y,w,h ; i16 dst_x,dst_y.
                c_src_x <= tl_window[15:0];
                c_src_y <= tl_window[31:16];
                c_w     <= tl_window[47:32];
                c_h     <= tl_window[63:48];
                // [static tile-list] map-coord dst + per-batch header bias -> screen dst.
                c_dst_x <= $signed(tl_window[79:64]) + res_bias_x;
                c_dst_y <= $signed(tl_window[95:80]) + res_bias_y;
                state   <= S_TL_ISSUE;
            end
            S_TL_ISSUE: begin
                // Same cull as the OP_BLIT path: a fully-offscreen entry (empty)
                // emits zero writes, matching the C golden's per-pixel clip; a
                // partial-offscreen entry is clipped inside comp_pipeline (bit-exact).
                if (empty) begin
                    tl_idx  <= tl_idx + 32'd1;
                    // entry stride: 8 bytes (resident) vs 12 bytes (resolved TILELIST).
                    tl_byte <= tl_byte + (tl_res ? 32'd8 : 32'd12);
                    state   <= (tl_idx + 32'd1 == tl_count) ? S_NEXT_CMD
                                                            : (tl_res ? S_TLR_FETCH : S_TL_FETCH0);
                end else begin
                    pipe_start <= 1'b1;          // issue this entry to comp_pipeline
                    state      <= S_TL_WAIT;
                end
            end
            S_TL_WAIT: if (p_blit_done) begin
                tl_idx  <= tl_idx + 32'd1;
                tl_byte <= tl_byte + (tl_res ? 32'd8 : 32'd12);
                state   <= (tl_idx + 32'd1 == tl_count) ? S_NEXT_CMD
                                                        : (tl_res ? S_TLR_FETCH : S_TL_FETCH0);
            end

            // ---- [#52 resident / Tier B] FRT upload: DDR FRT region -> frt_bram ----
            S_FRT_RD: begin
                bm_rd<=1'b1; bm_addr <= `FRT_BUF_QW + frt_idx[28:0];
                rd_ret<=S_FRT_WR; state<=S_RD_WAIT;
            end
            S_FRT_WR: begin
                frt_bram[frt_idx[$clog2(MAXP*MAXF)-1:0]] <= rd_data;
                frt_idx <= frt_idx + 32'd1;
                state   <= (frt_idx + 32'd1 == frt_count) ? S_NEXT_CMD : S_FRT_RD;
            end

            // ---- [PAL8 v1] CLUT upload: DDR CLUTBUF region -> clut_bram ----
            S_CLUT_RD: begin
                bm_rd<=1'b1; bm_addr <= `CLUT_BUF_QW + clut_idx[28:0];
                rd_ret<=S_CLUT_WR; state<=S_RD_WAIT;
            end
            S_CLUT_WR: begin
                clut_bram[clut_idx[$clog2(`CLUT_BANKS*`CLUT_ENTRIES)-1:0]] <= rd_data[31:0];
                clut_idx <= clut_idx + 32'd1;
                state    <= (clut_idx + 32'd1 == clut_cnt) ? S_NEXT_CMD : S_CLUT_RD;
            end

            // ---- [#52 resident] CFT preload: DDR CFT region -> cft_mem (4 u16/qword) ----
            S_CFT_RD: begin
                bm_rd<=1'b1; bm_addr <= `CFT_BUF_QW + cft_idx[28:0];
                rd_ret<=S_CFT_WR; state<=S_RD_WAIT;
            end
            S_CFT_WR: begin
                cft_mem[cft_idx[$clog2(MAXP)-3:0]*4 + 0] <= rd_data[15:0];
                cft_mem[cft_idx[$clog2(MAXP)-3:0]*4 + 1] <= rd_data[31:16];
                cft_mem[cft_idx[$clog2(MAXP)-3:0]*4 + 2] <= rd_data[47:32];
                cft_mem[cft_idx[$clog2(MAXP)-3:0]*4 + 3] <= rd_data[63:48];
                cft_idx <= cft_idx + 32'd1;
                // MAXP u16 = MAXP/4 qwords. After preload, run the entry loop.
                state   <= (cft_idx + 32'd1 == (MAXP/4)) ? S_TLR_FETCH : S_CFT_RD;
            end

            // ---- [#52 resident] per-entry: read 8-byte entry, resolve src from tables ----
            S_TLR_FETCH: begin
                bm_rd<=1'b1; bm_addr <= tlr_entry_qw;   // one aligned qword per entry
                rd_ret<=S_TLR_LATCH; state<=S_RD_WAIT;
            end
            S_TLR_LATCH: begin
                // Entry (LE): u16 pattern_id ; i16 dst_x ; i16 dst_y ; u16 _rsvd.
                res_pid <= rd_data[15:0];
                res_dx  <= rd_data[31:16];
                res_dy  <= rd_data[47:32];
                state   <= S_TLR_CFT;            // cft_mem[pid] -> cft_q (registered read)
            end
            S_TLR_CFT: begin
                cft_q <= cft_mem[res_pid[$clog2(MAXP)-1:0]];   // registered read
                state <= S_TLR_FRT;
            end
            S_TLR_FRT: begin
                // cft_q now valid; frt_addr = pid*MAXF + final_frame_index. REGISTERED
                // read of frt_bram (keeps it inferred as M10K, not flops).
                frt_q <= frt_bram[frt_addr];
                state <= S_TLR_SLICE;
            end
            S_TLR_SLICE: begin
                // Slice the resolved rect into the shared blit fields and issue like OP_BLIT.
                c_src_x <= frt_q[15:0];
                c_src_y <= frt_q[31:16];
                c_w     <= frt_q[47:32];
                c_h     <= frt_q[63:48];
                c_dst_x <= $signed(res_dx) + res_bias_x;
                c_dst_y <= $signed(res_dy) + res_bias_y;
                state   <= S_TL_ISSUE;          // shared cull + comp_pipeline issue + advance
            end

            S_NEXT_CMD: begin cmd_idx<=cmd_idx+1; state<=S_FETCH; end

            // C_PIPE: the FSM holds here (driving no bus traffic — bm_* idle,
            // pipe_busy hands mem_* to comp_pipeline) until the pipelined blit
            // signals blit_done, then advances to the next command.
            S_PIPE_WAIT: if (p_blit_done) state<=S_NEXT_CMD;

            S_FRAME_VCTRL: begin
                // Publish the new frame: write vctrl + bump frame_counter, then signal
                // C_DONE. (The retired off-screen cache pass used to skip this for
                // target==2; that path no longer exists.)
                bm_wr<=1; bm_be<=8'h0F; bm_addr<=`VCTRL_QW;
                bm_din<={32'd0, vctrl_val};
                frame_counter<=frame_counter+1;
                wr_ret<=S_WR_DONE; state<=S_WR_WAIT;
            end
            S_WR_DONE: begin
                // low32 = done_seq (handshake); high32 = fabric-busy cyc this frame.
                bm_wr<=1; bm_be<=8'hFF; bm_addr<=`BLTCTRL_QW+`C_DONE;
                bm_din<={perf_frame_cyc, submit_reg};
                wr_ret<=S_WR_STATUS; state<=S_WR_WAIT;
            end
            S_WR_STATUS: begin
                // low32 = OSD mirror bits (bit0=osd_restart_pending, the sticky-latched
                // trigger — see the latch above; bit1=osd_fps_on, a genuine persistent
                // level so it's read raw); high32 = compositor-busy (pipe_busy) cyc this
                // frame — unchanged.
                bm_wr<=1; bm_be<=8'hFF; bm_addr<=`BLTCTRL_QW+`C_STATUS;
                bm_din<={perf_pipe_cyc, 30'd0, osd_fps_on, osd_restart_pending};
                // [FB-in-BRAM double-buffer] after the frame, snapshot the completed work
                // buffer into the scan buffer (during vblank). C_DONE was already written
                // (S_WR_DONE), so the engine's handshake completes and its next-frame prep
                // overlaps the snapshot; we hold off polling the next submit until it ends.
                wr_ret<=S_SNAP_WAIT;
                state<=S_WR_WAIT;
            end

            // Wait for vblank to start (scanout not fetching scan-buffer lines), then
            // trigger the work->scan copy.
            S_SNAP_WAIT: if (vs_rise) begin snap_start<=1'b1; state<=S_SNAP_BUSY; end
            // snap_start pulsed; wait for the controller to raise busy.
            S_SNAP_BUSY: if (snap_busy) state<=S_SNAP_DRAIN;
            // hold here (not compositing, so the work buffer is stable) until the copy
            // completes, then resume polling for the next frame.
            S_SNAP_DRAIN: if (!snap_busy) state<=S_POLL_SUBMIT;

            // ---- [Phase 3b] OP_BGPLANE_WRITE: trigger + hold until fully drained ----
            // No vsync gate (unlike S_SNAP_WAIT): bgw_start was already pulsed in the
            // S_SETUP decode above, so just wait for bgw_busy to rise then fall.
            // bgw_busy (fbram_to_sdram's own `busy` output, wired straight through at
            // the u_bgw instantiation below) stays high until the streamer's read/
            // produce loop is done AND its last presented write has been ACCEPTED by
            // ch0 (dst_ok) -- unlike snap (an on-chip BRAM write with no latency), ch0
            // is a cache-ok port whose write acceptance can lag production by many
            // cycles, so the streamer paces itself off dst_ok directly (see
            // fbram_to_sdram.sv) rather than needing a separate drain-tail signal
            // here. Returns to S_NEXT_CMD (not S_POLL_SUBMIT) like every other opcode,
            // so the ring continues normally (e.g. the OP_END that follows still runs
            // the usual S_FRAME_VCTRL -> S_SNAP_* -> S_POLL_SUBMIT handshake).
            S_BGW_WAIT: begin bgw_start<=1'b0; if (bgw_busy) state<=S_BGW_BUSY; end
            // [bgplane bake -> STAGE reroute] the bake streamed through the STAGE (ch1)
            // channel; its dirty lines are in ch1 but not yet in SDRAM, and ch5 (P_SRC)
            // may hold stale lines. Reuse the STAGE barrier to commit ch1 + invalidate
            // ch5 before the next command (the per-frame COPY reads the plane via P_SRC,
            // so it MUST see the just-baked data). S_STAGE_BARRIER_WAIT returns to
            // S_NEXT_CMD, so the bake ends exactly where it did before, now coherent.
            S_BGW_BUSY: if (!bgw_busy) state<=S_STAGE_BARRIER;

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
        // [PAL8 v1, Task 1.2] palette selector + CLUT lookup (registered read in
        // clut_bram above; addr is u_pipe's OWN output, fed back via pipe_clut_addr).
        .c_pal_id(c_pal_id), .c_base_off(c_base_off),
        .clut_rd_addr(pipe_clut_addr), .clut_rd_data(clut_q),
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
        // on-chip framebuffer (comp_fbram) dest port — threaded straight out [FB-in-BRAM].
        // The work WRITE port is comp_pipeline's alone; the work READ port is shared with
        // the snapshot controller (mux below), so comp_pipeline drives pipe_fb_rd_*.
        .fb_wr_en(fb_wr_en), .fb_wr_qw(fb_wr_qw), .fb_wr_lane(fb_wr_lane), .fb_wr_pix(fb_wr_pix),
        .fb_rd_en(pipe_fb_rd_en), .fb_rd_qw(pipe_fb_rd_qw), .fb_rd_qword(fb_rd_qword),
        .blit_done(p_blit_done));

    // ── work->scan snapshot controller [FB-in-BRAM double-buffer] ────────────────
    // Streams the completed WORK buffer into the SCAN buffer once per frame during
    // vblank (state S_SNAP_* sequences it). It borrows comp_fbram's work read port, so
    // fb_rd_* is muxed: the snapshot owns it while snap_busy (comp_pipeline is idle
    // between frames), otherwise comp_pipeline's RMW read drives it.
    fbram_snapshot #(.FB_QWORDS(`FB_QWORDS), .AW(15)) u_snap (   // [#97] single-source from blitter_defs.vh
        .clk(clk), .rst(rst), .start(snap_start), .busy(snap_busy),
        .rd_en(snap_rd_en), .rd_qw(snap_rd_qw), .rd_qword(fb_rd_qword),
        .snap_we(fb_snap_we), .snap_qw(fb_snap_qw), .snap_qword(fb_snap_qword));
    // ── [Phase 3b] OP_BGPLANE_WRITE: fbram_to_sdram -> ch0 (P_DST) direct ──────────
    // fbram_to_sdram now paces itself off consumer_ready (dst_ok): it presents each
    // qword on sdram_wr_en/addr/data and HOLDS it stable until dst_ok accepts (see
    // that module's header), so its own hold-until-ok output plugs straight into
    // ch0's dst_wr/dst_ok contract with no elastic buffer in between. (An earlier
    // version paired a no-backpressure streamer with a 32768-entry FIFO here to
    // survive ch0's cold-miss latency without ever overflowing; that FIFO alone
    // needed ~205 M10K blocks and blew the Quartus fit -- "needs more than 553" --
    // against ~118 blocks of headroom. Backpressure removes the FIFO entirely.)
    // sdram_wr_addr is RELATIVE (cell-local); this cell's absolute plane base
    // (bgw_base_qw, latched from the command header at bgw_start) is added below.
    wire          bgw_rd_en; wire [14:0] bgw_rd_qw;
    wire          bgw_sdram_wr_en;
    wire [23:0]   bgw_sdram_wr_addr;   // RELATIVE -- absolute addr added below
    wire [63:0]   bgw_sdram_wr_data;

    localparam integer BGW_CELL_ROW_QW = 80;
    fbram_to_sdram #(.FB_QWORDS(`FB_QWORDS), .AW(15), .CELL_ROW_QW(BGW_CELL_ROW_QW), .CELL_ROWS(`FB_H)) u_bgw (   // [#97] single-source from blitter_defs.vh
        .clk(clk), .rst(rst), .start(bgw_start), .dst_stride_qw(bgw_stride_qw),
        .argb4444_mode(bgw_argb4444), .rd_cov(bgcov_rd_nibble),
        .busy(bgw_busy),
        .rd_en(bgw_rd_en), .rd_qw(bgw_rd_qw), .rd_qword(fb_rd_qword),
        .sdram_wr_en(bgw_sdram_wr_en), .sdram_wr_addr(bgw_sdram_wr_addr),
        .sdram_wr_data(bgw_sdram_wr_data),
        // [bgplane bake -> STAGE reroute] pace off the STAGE (ch1) cache-ok, not ch0's
        // dst_ok: the bake now streams through ch1 (see the src_sdram_* mux below).
        .consumer_ready(src_sdram_ok)
    );

    // ── [ARGB4444 plane bake] per-cell coverage tracker ─────────────────────
    // Write side taps comp_pipeline's own fb_wr_* directly (fan-out — comp_fbram
    // remains the sole consumer of record; this is a passive mirror). wr_clear is
    // driven by c_bgcov_clear (declared above, real BLT_F_BGCOV-on-OP_FILL
    // decode). Read side taps the already-muxed fb_rd_* bus so it tracks
    // whichever consumer (only bgw ever reads it in practice) currently owns
    // it. bgcov_rd_nibble is forward-declared near the other bgw_* signals
    // (u_bgw's rd_cov port needs it at an earlier point in this file — see
    // the declaration there).
    bgplane_coverage #(.AW(15)) u_bgcov (
        .clk(clk), .rst(rst),
        .wr_en(fb_wr_en), .wr_qw(fb_wr_qw), .wr_lane(fb_wr_lane),
        .wr_clear(c_bgcov_clear),
        .rd_en(fb_rd_en), .rd_qw(fb_rd_qw), .rd_nibble(bgcov_rd_nibble)
    );

    // [bgplane bake -> STAGE ch1 reroute] OP_BGPLANE_WRITE now streams through the STAGE
    // (ch1) write channel instead of ch0 (P_DST). WHY: ch1 shares ch5/P_SRC's SDRAM
    // address space (OFFSET1==SRC_OFFSET_W) and its barrier commits ch1 + invalidates ch5
    // (INVAL_MASK1), so the baked plane is coherent with the COPY's P_SRC read. The ch0
    // path was architecturally wrong for P_SRC-read data (separate cache, its flush
    // invalidates only ch0) AND its writes did not commit to physical SDRAM on HW —
    // proven via SOLARUS_BGW_PROBE: an OP_BGPLANE_WRITE region read back BLACK while a
    // blt_stage_to (ch1) region read back correctly, same COPY. The bgw stream drives the
    // STAGE burst port COMBINATIONALLY (identical hold-until-ok timing to the old ch0
    // assign) whenever bgw_active; the OP_STAGE atlas FSM (stage_*_fsm) owns it otherwise.
    // The two never run concurrently (atlas staging is load-time; the bake is a gameplay
    // per-map event). The S_BGW_BUSY -> S_STAGE_BARRIER transition then commits ch1 +
    // invalidates ch5 before the next command.
    assign bgw_active         = bgw_sdram_wr_en;   // STAGE-port mux select (also the now-idle ch0 mux select)
    // [#101] Widen the plane-address add to 25 bits to DETECT a carry out of the 24-bit
    // qword space (2^24 qw = 128 MiB, the physical SDRAM). Both operands are 24-bit, so
    // the native add (bgw_base_qw + bgw_sdram_wr_addr) silently drops any carry -> the
    // write WRAPS to a low address and corrupts an UNRELATED region (a different plane /
    // the atlas). On overflow, CLAMP to the top valid qword: the hold-until-dst_ok bake
    // streamer cannot have writes silently dropped (it would wedge waiting for dst_ok), so
    // the write must complete — clamping keeps it IN-BOUNDS (bounded corruption of the
    // plane's own top qword) instead of a wild low-address wrap. The #97 FABRIC_ASSERT
    // flags the misconfig in sim; the real cure is host-side plane placement. NEEDS-HW.
    wire [24:0] bgw_qw_sum  = {1'b0, bgw_base_qw} + {1'b0, bgw_sdram_wr_addr};
    wire [23:0] bgw_qw_safe = bgw_qw_sum[24] ? 24'hFF_FFFF : bgw_qw_sum[23:0];
    assign src_sdram_we_burst = bgw_active ? bgw_sdram_wr_en  : stage_we_burst_fsm;
    assign src_sdram_din64    = bgw_active ? bgw_sdram_wr_data : stage_din64_fsm;
    assign src_sdram_waddr    = bgw_active ? {bgw_qw_safe, 3'b000}   // qword -> byte, clamped in-bounds
                                           : stage_waddr_fsm;
    // ch0 (P_DST) is left idle — the bake no longer uses it (vram_demux's FB writes are
    // also dead, so ch0's write side carries no traffic at all now).
    assign dst_wr   = 1'b0;
    assign dst_addr = 27'd0;
    assign dst_din  = 64'd0;
    assign dst_wdsn = 8'hFF;   // active-low byte-select: mask all 8 lanes (never write ch0)

`ifdef FABRIC_ASSERT
    // [#97 SVA] bgplane bake address in-bounds: bgw_base_qw (absolute plane base, qword)
    // + the cell-relative offset must NOT carry out of the 24-bit qword address space
    // (128 MiB / 8 = 2^24 qwords). A carry WRAPS the base to a low SDRAM address — the
    // #101 truncation/wrap class — silently corrupting an unrelated region. Widen the
    // add and flag any bit-24 carry. Holds on every current TB (in-die bases); it is the
    // net that catches the wrap once a 128 MiB-scale base is exercised.
    always @(posedge clk) if (!rst && bgw_active)
      assert (({1'b0, bgw_base_qw} + {1'b0, bgw_sdram_wr_addr}) < 25'h100_0000)
      else $display("FABRIC-ASSERT FAIL [blitter_top]: bgw plane addr WRAP: base=%h + off=%h carries out of 24b @%0t", bgw_base_qw, bgw_sdram_wr_addr, $time);
`endif

    // bgw_busy (fbram_to_sdram's own `busy` output, wired directly above) now covers
    // the WHOLE operation by itself: the module holds `busy` high until the LAST
    // write has been ACCEPTED by dst_ok, not merely produced, so no separate drain-
    // tail bookkeeping is needed in this file any more.

    // 3-way fb_rd mux: snapshot (vblank) > bg-write (rare bake) > normal compositor.
    // These two rare consumers are mutually exclusive in time (bg-write only runs
    // mid-frame during a bake with the compositor otherwise idle; snapshot only runs
    // in vblank) so priority order between them doesn't matter in practice, but snap
    // must never be starved by a stuck bg-write, hence this order.
    assign fb_rd_en = snap_busy ? snap_rd_en : (bgw_busy ? bgw_rd_en : pipe_fb_rd_en);
    assign fb_rd_qw = snap_busy ? snap_rd_qw : (bgw_busy ? bgw_rd_qw : pipe_fb_rd_qw);

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
