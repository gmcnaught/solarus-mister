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
    // ---- [Stage 5 Phase 2] snapshot WORK->comp_fbram SCAN write port — REMOVED ----
    // The on-chip SCAN half of comp_fbram is gone (Task 2/3): the frame's scanout copy
    // now lives in a DDR3 double-buffer. u_snap is a fb_ddr_writer that streams WORK out
    // to DDR3 via the shared mem_* master (see the owner mux below) during vblank, so
    // there is no dedicated snap write port on this module anymore. Solarus.sv drops the
    // comp_fbram SCAN port + these connections in Task 8.
    // ---- ch0 (P_DST) write port ------------------------------------------------
    // sdram_fb_cache's ch0 (P_DST) write side has been idle since PR #49 retired
    // the SDRAM-dest compositor (FB-in-BRAM composites on-chip now); the one-time
    // background-plane bake that briefly repurposed it was removed in Stage 3b
    // Phase B2. ch0's write side now carries no traffic and has no port here.
    // ---- SDRAM STAGE WRITE path (issue #19, BLT_OP_STAGE) ----------------------
    // A BLT_OP_STAGE command copies a source region from DDR3 (SRC_QW + off) into
    // SDRAM at the heap-relative byte offset `off` (exactly the address the SDRAM
    // source read uses). These single-16-bit-word write outputs route through the
    // cache STAGE channel (ch1). They are IDLE (we=0) outside staging.
    output reg           src_sdram_we,     // request one 16-bit word write (held until granted)
    output reg  [15:0]   src_sdram_din,    // the word to write
    // The 3 burst-write outputs are continuous-assigns of the OP_STAGE atlas FSM's
    // private stage_*_fsm regs (declared below), hence `wire` rather than a
    // directly FSM-driven `reg`.
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
        // (6'd40 reclaimed by S_GRID_SETUP2 below, Stage 3b B2 timing split;
        // 6'd41 reclaimed by S_GRID_BOUNDS below, same timing split)
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
        // (6'd54/6'd55 retired with the background-plane bake FSM, Stage 3b Phase B2 —
        // returned to the reclaimable pool)
        // ---- [PAL8 v1] BLT_OP_CLUT_UPLOAD: stream CLUTBUF DDR -> clut_bram ----
        S_CLUT_RD=6'd56,    S_CLUT_WR=6'd57,   // mirrors S_FRT_RD/S_FRT_WR
        // ---- [Stage 2] BLT_OP_SPRITELIST: ordered sprite batch from SP_BUF ----
        // Three ALIGNED qword fetches per 24-byte entry (no tl_bitoff barrel shift:
        // the entry size is a whole number of qwords by construction), then a latch
        // that converges on the SHARED S_TL_ISSUE/S_TL_WAIT cull+issue+wait loop —
        // exactly the convergence S_TLR_SLICE uses.
        S_SPR_FETCH0=6'd58, S_SPR_FETCH1=6'd59, S_SPR_FETCH2=6'd60,
        S_SPR_LATCH=6'd61,
        // ---- [Stage 3b B2] BLT_OP_TILEMAP grid-walk (5 reclaimed 6-bit slots) ----
        // Shares S_TLR_CFT/S_TLR_FRT resolve + the comp_pipeline handshake; keeps its
        // OWN slice/wait so the shared S_TL_ISSUE/S_TL_WAIT tail is untouched.
        S_GRID_SETUP=6'd14, S_GRID_FETCH=6'd27, S_GRID_DECODE=6'd28,
        S_GRID_SLICE=6'd29, S_GRID_WAIT=6'd31,
        // [timing] row_base=cy*grid_w split off S_GRID_SETUP into its own cycle
        // (reclaimed 6'd40 slot, see the retired dst_barrier note above) so the
        // multiply operates on the REGISTERED cy, not the combinational g_cy0
        // subtract->shift chain -- closes the -0.964ns row_base[*] violation.
        S_GRID_SETUP2=6'd40,
        // [timing] cell-bounds (cx0/cx1/cy0/cy1) split off S_GRID_SETUP into its
        // own cycle (reclaimed 6'd41 slot) so the c_h -> cy1 chain (*8 -> +gby ->
        // min -> -gby -> +7 -> >>3 -> min(c_h)) computes off the REGISTERED pixel
        // window (v_lo/hi_x/y) instead of chaining off combinational c_h/c_w --
        // closes the residual -0.229ns From c_h[*] To cy1[8] setup violation.
        S_GRID_BOUNDS=6'd41;

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
    reg           snap_start;    // 1-cycle WORK->DDR3 snapshot trigger (vblank)
    // [Stage 5 P2] fb_ddr_writer done + fence bookkeeping.
    wire          w_snap_done;       // combinational 1-cyc pulse: last WORK->DDR3 beat drained
    reg           snap_done;         // registered copy — the S_SNAP_DRAIN -> S_FRAME_VCTRL trigger
    reg           fence_done_seen;   // sticky per-frame: the WORK->DDR3 drain completed this frame (SVA)
    // fb_ddr_writer DDR write-master outputs — funneled onto the shared mem_* master
    // while snap_busy (owner mux below). Gappy burst (per-beat mem_wr, burstcnt re-presented
    // each beat) accepted by ~mem_busy, IDENTICAL to comp_burst's write handshake.
    wire          w_snap_mem_wr;
    wire [28:0]   w_snap_mem_addr;
    wire [63:0]   w_snap_mem_din;
    wire [7:0]    w_snap_mem_be;
    wire [7:0]    w_snap_mem_burstcnt;
    // (the one-time WORK->SDRAM background-plane bake trigger/state was retired
    // in Stage 3b Phase B2, along with the rest of the plane-bake RTL)
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
    // [Stage 5 P2 review fix] Fabric-owned DDR3 double-buffer index -- decoupled from
    // target_buf, which the host reloads from C_TARGET (currently always 0, single-buffer
    // mode) every frame in S_GOT_TARGET and so cannot carry a persistent flip. fb_bank is
    // NEVER loaded from the ring; it means "the DDR3 buffer currently ACTIVE (scanned)" and
    // toggles exactly once per frame in S_FRAME_VCTRL, giving a real write/publish/read
    // ping-pong (FB1,FB0,FB1,... written each frame, opposite published active each frame).
    reg         fb_bank;
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

    // ---- [Stage 2] BLT_OP_SPRITELIST entry loop ----
    // tl_spr selects the sprite path (24-byte entries in SP_BUF) when the shared
    // tile-list batch state above is driven by OP_SPRITELIST. It is mutually
    // exclusive with tl_res: TILELIST leaves both 0 (12-byte TL_BUF entries),
    // TILELIST_RES sets tl_res (8-byte TL_BUF entries), SPRITELIST sets tl_spr
    // (24-byte SP_BUF entries). tl_count/tl_entry_ptr/tl_idx/tl_byte and the
    // res_bias_x/y header bias are reused as-is; tl_qw0/tl_qw1 hold the first two
    // of the entry's three qwords (the third arrives in rd_data at S_SPR_LATCH).
    // No TL_BUF storage and none of the resident-tile machinery is involved.
    reg          tl_spr;            // 1 = SPRITELIST (sprite) entry loop
    // 24-byte entry address. Aligned by construction (24 is a multiple of 8 and the
    // host's entry-array base is qword-aligned), so unlike tl_entry_qw this needs no
    // companion bit-offset: entry_byte[2:0] is always 0 for a well-formed batch.
    wire [31:0]  spr_entry_byte = tl_entry_ptr + tl_byte;
    wire [28:0]  spr_entry_qw   = `SP_BUF_QW + spr_entry_byte[31:3];

`ifdef FABRIC_ASSERT
    // [Stage 2 SVA] spr_entry_byte[2:0] must always be 0 while the sprite loop is
    // active: this is the alignment precondition the comment above claims ("aligned
    // by construction"), made checkable. The fabric deliberately does NOT re-align a
    // misaligned entry_byte (no barrel shifter here -- that would forfeit the whole
    // reason the entry size is a qword multiple, see the 24-byte-stride comment at
    // tl_entry_stride below); alignment is guaranteed HOST-side (blt_sprite_channel_push
    // / blt_sprite_list only ever advance sp_used by BLT_SPRITE_ENTRY_BYTES=24 from an
    // 8-aligned OFF_SPBUF base). This assertion exists only to catch a host-side
    // regression in sim -- it is not a runtime guard.
    always @(posedge clk) if (!rst && tl_spr)
      assert (spr_entry_byte[2:0] == 3'b0)
      else $display("FABRIC-ASSERT FAIL [blitter_top]: spr_entry_byte misaligned: byte=%h low3=%b @%0t -- host emitter violated the 8-aligned-base/24-byte-stride precondition", spr_entry_byte, spr_entry_byte[2:0], $time);

    // [Stage 5 P2 SVA] TEAR-FREE FENCE: the video control word (VCTRL_QW) must never be
    // published before the WORK->DDR3 burst for THIS frame has fully drained. fence_done_seen
    // is armed (cleared) at frame start (S_CHK_NEW) and latched when fb_ddr_writer.done fires
    // (last beat accepted). The FSM only reaches S_FRAME_VCTRL from S_SNAP_DRAIN on snap_done,
    // so this is a structural guard that a future FSM reorder can't silently break the fence.
    always @(posedge clk) if (!rst && bm_wr && (bm_addr == `VCTRL_QW))
      assert (fence_done_seen)
      else $display("FABRIC-ASSERT FAIL [blitter_top]: VCTRL published before WORK->DDR3 drain completed this frame (tear-free fence violated) @%0t", $time);

    // [Stage 5 P2 review fix SVA] bm_wr/bm_din (capturing S_FRAME_VCTRL's writes) and
    // fb_bank (capturing S_FRAME_VCTRL's own flip) update via NBA on the SAME cycle, so by
    // the cycle this fires, fb_bank already holds the FLIPPED (post-publish) value -- i.e.
    // exactly the active bit that was just published. Checking bm_din[0] == fb_bank catches
    // any future edit that re-derives the published bit from target_buf (or anything else)
    // instead of the fabric-owned fb_bank, which is exactly the bug this fix corrects.
    always @(posedge clk) if (!rst && bm_wr && (bm_addr == `VCTRL_QW))
      assert (bm_din[0] == fb_bank)
      else $display("FABRIC-ASSERT FAIL [blitter_top]: VCTRL active bit (%b) != post-flip fb_bank (%b) @%0t -- published buffer index diverged from the fabric-owned fb_bank double-buffer", bm_din[0], fb_bank, $time);
`endif

    // ---- [#52 resident / Tier B] BLT_OP_TILELIST_RES + FRT/CFT tables ----
    // tl_res selects the resident path (8-byte pattern-indexed entries) when the
    // tile-list batch state above is driven by OP_TILELIST_RES; the TILELIST state
    // (12-byte resolved entries) leaves it 0. tl_byte advances by 8 (res) vs 12.
    reg          tl_res;            // 1 = TILELIST_RES (resident) entry loop
    // Entry stride + loop re-entry point for the SHARED S_TL_ISSUE/S_TL_WAIT tail,
    // now three-way: 24 B SP_BUF (sprite, tl_spr) / 8 B TL_BUF (resident, tl_res) /
    // 12 B TL_BUF (resolved TILELIST). tl_spr and tl_res are never both set.
    wire [31:0]  tl_entry_stride = tl_spr ? 32'd24 : (tl_res ? 32'd8  : 32'd12);
    wire [5:0]   tl_next_fetch   = tl_spr ? S_SPR_FETCH0
                                          : (tl_res ? S_TLR_FETCH : S_TL_FETCH0);
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
    // ---- [Stage 3b B2] BLT_OP_TILEMAP grid-walk state ----
    // The grid walker is the resident-tile path (S_TLR*) with a 2D run-coalescing
    // front end: it walks the GRID_BUF cell array row-major over the visible cell
    // window, resolves each non-empty cell through the SHARED S_TLR_CFT/S_TLR_FRT
    // path (cft_mem[pid] -> frt_bram[pid*MAXF+f]), and issues one run*8 x 8 blit per
    // coalesced horizontal run through its OWN S_GRID_SLICE/S_GRID_WAIT (so the
    // S_TL_ISSUE/S_TL_WAIT tail the 3 shipping list ops share stays untouched).
    reg  [15:0] grid_w;                // grid width in 8px cells (from header w); used in row-advance.
                                       // (grid_h isn't stored: the cy1 row bound is the c_h-clamped
                                       // window ceil, so the height clamp uses c_h directly.)
    reg  [20:0] cells_off;             // byte offset of the cell array within GRID_BUF
    reg  [8:0]  cx, cx0, cx1;          // cell-column cursor / window [cx0,cx1)
    reg  [8:0]  cy, cy1;               // cell-row cursor / window end (cy0 folded into setup)
    reg  [16:0] row_base;              // cy*grid_w, maintained incrementally (+grid_w per row)
    reg  signed [31:0] v_lo_x, v_hi_x, v_lo_y, v_hi_y;   // [timing] registered pixel window;
                                        // cell bounds computed from these in S_GRID_BOUNDS
    reg  [3:0]  g_sub_x, g_sub_y;      // sub-pattern offset of the current run
    reg  [4:0]  g_run;                 // coalesced run length in cells (1..16)
    reg         tl_grid;               // 1 = resolve path terminates in S_GRID_SLICE
    reg         cell_half;             // 1 = current cell is the high 32 bits of its qword
    // ── S_GRID_SETUP visible-cell-window math (combinational off c_w/c_h/res_bias) ──
    // Bit-exact to blt_ref_tilemap: intersect the biased grid with the framebuffer in
    // PIXEL space, then convert to cell indices (cx0/cy0 = floor, cx1/cy1 = ceil). The
    // ceil on the hi edge is load-bearing (it keeps partially-visible edge cells). All
    // subtraction numerators are >= 0 (vis_lo >= bias, a max against 0), so the
    // arithmetic shifts are exact floor/ceil with no negative-division pitfall.
    wire signed [31:0] gpx_w  = $signed({16'd0, c_w}) << 3;   // grid_w * 8 (pixels)
    wire signed [31:0] gpx_h  = $signed({16'd0, c_h}) << 3;   // grid_h * 8
    wire signed [31:0] gbx    = res_bias_x;
    wire signed [31:0] gby    = res_bias_y;
    wire signed [31:0] g_vlo_x = (gbx > 0) ? gbx : 32'sd0;
    wire signed [31:0] g_vhi_x = ((gbx + gpx_w) < `FB_W) ? (gbx + gpx_w) : `FB_W;
    wire signed [31:0] g_vlo_y = (gby > 0) ? gby : 32'sd0;
    wire signed [31:0] g_vhi_y = ((gby + gpx_h) < `FB_H) ? (gby + gpx_h) : `FB_H;
    wire        g_cull  = (c_w == 16'd0) || (c_h == 16'd0)
                       || (g_vlo_x >= g_vhi_x) || (g_vlo_y >= g_vhi_y);
    // g_cx*/g_cy* are valid in S_GRID_BOUNDS, off the REGISTERED pixel window
    // (v_lo/hi_x/y, latched in S_GRID_SETUP) rather than the combinational
    // g_vlo/g_vhi -- this breaks the c_h -> cy1 combinational chain across a
    // register stage (closed the residual -0.229ns setup violation).
    wire [31:0] g_cx0     = (v_lo_x - gbx) >>> 3;              // floor
    wire [31:0] g_cx1_raw = (v_hi_x - gbx + 32'sd7) >>> 3;     // ceil
    wire [31:0] g_cx1     = (g_cx1_raw > c_w) ? c_w : g_cx1_raw;
    wire [31:0] g_cy0     = (v_lo_y - gby) >>> 3;
    wire [31:0] g_cy1_raw = (v_hi_y - gby + 32'sd7) >>> 3;
    wire [31:0] g_cy1     = (g_cy1_raw > c_h) ? c_h : g_cy1_raw;
    // (g_row0 = g_cy0*c_w removed [timing]: row_base is now computed in
    // S_GRID_SETUP2 from the REGISTERED cy, see that state below.)
    // ── cell fetch address (row-major, incremental row_base; the only per-cell math) ──
    wire [17:0] grid_cell_idx  = row_base + cx;                 // cy*grid_w + cx
    wire [21:0] grid_cell_boff = cells_off + (grid_cell_idx << 2); // 4 bytes/cell
    wire [28:0] grid_cell_qw   = `GRID_BUF_QW + (grid_cell_boff >> 3);
    // ── cell decode (combinational off rd_data in S_GRID_DECODE) ──
    wire [31:0] grid_cell_word = cell_half ? rd_data[63:32] : rd_data[31:0];
    wire [11:0] grid_pid   = grid_cell_word[GRID_CELL_PID_W-1:0];        // [11:0]
    wire [3:0]  grid_sub_x = grid_cell_word[GRID_CELL_SUBX_LSB+3 -: 4];  // [15:12]
    wire [3:0]  grid_sub_y = grid_cell_word[GRID_CELL_SUBY_LSB+3 -: 4];  // [19:16]
    wire [4:0]  grid_run   = grid_cell_word[GRID_CELL_RUN_LSB +3 -: 4] + 5'd1; // run_m1+1 (1..16)
    // frame-rect table: MAXP*MAXF qwords, {h,w,src_y,src_x} (LE). Single write port
    // (FRT_UPLOAD) + single registered read (resolve) -> infers M10K. Explicit
    // ramstyle (Task 3 LAB-overflow chase, final candidate from fix-timing's
    // static sweep of the whole fpga/ tree): same AUTO-inference-fragility class
    // as comp_src_linebuf.sv/comp_pipeline.sv's span table (this task) -- don't
    // rely on AUTO here either.
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
    // The OP_STAGE atlas FSM's private copies of the three burst-write outputs;
    // the port wires src_sdram_we_burst/din64/waddr are continuous-assigns of
    // these (Stage 3b Phase B2: no longer muxed against a bake stream).
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

    // video control word (drop-in producer): frame_counter[31:2] | active_buf[0].
    // [Stage 5 P2 review fix] The active buffer is the one the WORK->DDR3 writer JUST
    // filled, which is the INACTIVE buffer at snapshot time = ~fb_bank (base_qw = fb_bank ?
    // FB0 : FB1, so the written buffer index is ~fb_bank). S_FRAME_VCTRL flips fb_bank to
    // this value the same cycle it publishes it (see below). fb_bank is fabric-owned and
    // NEVER reloaded from target_buf/C_TARGET -- see fb_bank's declaration above.
    wire [31:0] vctrl_val = ((frame_counter + 32'd1) << 2) | {31'd0, ~fb_bank};

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
            snap_done<=1'b0; fence_done_seen<=1'b0;   // [Stage 5 P2] WORK->DDR3 fence bookkeeping
            fb_bank<=1'b0;      // [Stage 5 P2 review fix] fabric-owned DDR3 buffer index
            tl_count<=32'd0; tl_entry_ptr<=32'd0; tl_idx<=32'd0; tl_byte<=32'd0;
            tl_qw0<=64'd0; tl_qw1<=64'd0; tl_bitoff<=6'd0;
            tl_res<=1'b0; tl_spr<=1'b0; frt_count<=32'd0; frt_idx<=32'd0; cft_idx<=32'd0;
            tl_grid<=1'b0;   // [Stage 3b B2] grid resolve-branch select
            clut_cnt<=32'd0; clut_idx<=32'd0;
            res_pid<=16'd0; res_dx<=16'sd0; res_dy<=16'sd0; frt_q<=64'd0; cft_q<=16'd0;
            res_bias_x<=16'sd0; res_bias_y<=16'sd0;
        end else begin
            bm_rd<=1'b0;
            pipe_start<=1'b0;     // single-cycle blit_start pulse to comp_pipeline
            stage_barrier<=1'b0;  // single-cycle barrier request unless re-asserted in S_STAGE_BARRIER
            src_sdram_we<=1'b0;   // single-cycle write request unless re-asserted (held in S_STAGE_WR_WAIT)
            stage_we_burst_fsm<=1'b0; // single-cycle burst-write request unless re-asserted
            snap_start<=1'b0;     // single-cycle WORK->DDR3 snapshot trigger
            // [#104] vs_rise now comes from the dedicated vs_sync 3-FF synchronizer
            // [Stage 5 P2] register the writer's combinational done; latch the per-frame
            // fence flag when it fires (cleared at frame start in S_CHK_NEW below).
            snap_done <= w_snap_done;
            if (w_snap_done) fence_done_seen <= 1'b1;

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
                    fence_done_seen<=1'b0;   // [Stage 5 P2] arm the WORK->DDR3 fence for this frame
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
                if (cmd_idx>=cmd_count) state<=S_SNAP_WAIT;   // [Stage 5 P2] drain WORK->DDR3 BEFORE VCTRL
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
                if (c_opcode==OP_END)       state<=S_SNAP_WAIT;   // [Stage 5 P2] drain WORK->DDR3 BEFORE VCTRL
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
                    tl_spr       <= 1'b0;
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
                    tl_spr       <= 1'b0;
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
                // (The background-plane bake opcode's decode arm was retired in
                // Stage 3b Phase B2 along with the rest of that RTL; the opcode value
                // stays RESERVED on the host side and is simply never issued.)
                else if (c_opcode==OP_SPRITELIST) begin
                    // [Stage 2] BLT_OP_SPRITELIST: SAME header packing as OP_TILELIST
                    // (w|h<<16 = N, dst_x|dst_y<<16 = entry-array byte offset,
                    // src_x/src_y = signed per-batch dst bias). Shared blend/format/
                    // alpha/colorkey/flags/stride stay latched in c_*; each entry
                    // overrides src_off, the source rect, dst, AND the palette word.
                    // (Must precede the `empty` test below for the same reason
                    //  OP_TILELIST does — c_w/c_h here are N, not a rect.) N==0 => no-op.
                    tl_count     <= {c_h, c_w};
                    tl_entry_ptr <= {c_dst_y, c_dst_x};
                    tl_idx       <= 32'd0;
                    tl_byte      <= 32'd0;
                    tl_res       <= 1'b0;
                    tl_spr       <= 1'b1;
                    res_bias_x   <= $signed(c_src_x);
                    res_bias_y   <= $signed(c_src_y);
                    state        <= ({c_h, c_w} == 32'd0) ? S_NEXT_CMD : S_SPR_FETCH0;
                end
                else if (c_opcode==OP_TILEMAP) begin
                    // [Stage 3b B2] BLT_OP_TILEMAP: walk the GRID_BUF cell array.
                    // w|h<<16 = grid_w|grid_h (CELLS); dst_x|dst_y<<16 = cells_off (byte
                    // offset in GRID_BUF); src_x/src_y = signed per-batch dst bias (same
                    // convention as every list op). Latch the bias (c_src_x/c_src_y get
                    // overwritten per run from frt_q in S_GRID_SLICE, so latch here), then
                    // enter the grid-walk. (Must precede the `empty` test — c_w/c_h here
                    // are cell counts, not a pixel rect.)
                    res_bias_x <= $signed(c_src_x);
                    res_bias_y <= $signed(c_src_y);
                    state      <= S_GRID_SETUP;
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
                    tl_byte <= tl_byte + tl_entry_stride;
                    state   <= (tl_idx + 32'd1 == tl_count) ? S_NEXT_CMD : tl_next_fetch;
                end else begin
                    pipe_start <= 1'b1;          // issue this entry to comp_pipeline
                    state      <= S_TL_WAIT;
                end
            end
            S_TL_WAIT: if (p_blit_done) begin
                tl_idx  <= tl_idx + 32'd1;
                tl_byte <= tl_byte + tl_entry_stride;
                state   <= (tl_idx + 32'd1 == tl_count) ? S_NEXT_CMD : tl_next_fetch;
            end

            // ---- [Stage 2] BLT_OP_SPRITELIST per-entry loop ----
            // Three ALIGNED qword reads of the current 24-byte entry from SP_BUF
            // (bm_* master, same DDR3 path the TILELIST loop uses), then slice the
            // six little-endian fields + per-entry src_off and palette into c_*, and
            // converge on S_TL_ISSUE. No barrel shift: 24 bytes = 3 whole qwords.
            S_SPR_FETCH0: begin
                bm_rd<=1'b1; bm_addr <= spr_entry_qw;
                rd_ret<=S_SPR_FETCH1; state<=S_RD_WAIT;
            end
            S_SPR_FETCH1: begin
                tl_qw0 <= rd_data;                       // bytes 0-7
                bm_rd<=1'b1; bm_addr <= spr_entry_qw + 29'd1;
                rd_ret<=S_SPR_FETCH2; state<=S_RD_WAIT;
            end
            S_SPR_FETCH2: begin
                tl_qw1 <= rd_data;                       // bytes 8-15
                bm_rd<=1'b1; bm_addr <= spr_entry_qw + 29'd2;
                rd_ret<=S_SPR_LATCH; state<=S_RD_WAIT;
            end
            S_SPR_LATCH: begin
                // rd_data now holds bytes 16-23. blt_sprite_entry_t (little-endian):
                //   qw0 = bytes  0-7 : u32 src_off | u16 src_x | u16 src_y
                //   qw1 = bytes  8-15: u16 w | u16 h | i16 dst_x | i16 dst_y
                //   qw2 = bytes 16-23: u16 color | u16 _rsvd | u32 _rsvd2
                c_src_off <= tl_qw0[31:0];               // [Stage 2] PER ENTRY (unlike TILELIST)
                c_src_x   <= tl_qw0[47:32];
                c_src_y   <= tl_qw0[63:48];
                c_w       <= tl_qw1[15:0];
                c_h       <= tl_qw1[31:16];
                // per-entry dst + the header's per-batch bias -> screen dst (same
                // convention as S_TL_LATCH / S_TLR_SLICE).
                c_dst_x   <= $signed(tl_qw1[47:32]) + res_bias_x;
                c_dst_y   <= $signed(tl_qw1[63:48]) + res_bias_y;
                // [Task 4b] PER-ENTRY palette word. c_pal_id/c_base_off are the same
                // combinational slices of c_color the OP_TILELIST PAL8 path uses
                // (they are just c_color[12:8]/c_color[7:0]) — so overriding c_color
                // here is exactly what makes the CLUT lookup resolve per sprite,
                // which a tile layer never needs (one tileset = one palette).
                c_color   <= rd_data[15:0];
                state     <= S_TL_ISSUE;
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
                // [Stage 3b B2] the grid walk shares this resolve but terminates in its
                // own slice (implicit cell-derived dst + run width), so branch on tl_grid.
                state <= tl_grid ? S_GRID_SLICE : S_TLR_SLICE;
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

            // ════════════════════════════════════════════════════════════════════
            //  [Stage 3b B2] BLT_OP_TILEMAP grid walk — bit-exact to blt_ref_tilemap
            // ════════════════════════════════════════════════════════════════════
            // Latch the grid geometry + the visible PIXEL window (all computed
            // combinationally above off c_w/c_h/res_bias), or cull the WHOLE op if the
            // biased grid is entirely off-screen (matches the golden's early return —
            // this is what makes a fully-off-screen bias emit zero blits instead of a
            // blit at a negative dst). The cell-bounds conversion (cx0/cx1/cy0/cy1) is
            // [timing] deferred to S_GRID_BOUNDS below so it operates on the REGISTERED
            // window (v_lo/hi_x/y) instead of chaining off combinational c_h/c_w
            // (closed the residual -0.229ns From c_h[*] To cy1[8] setup violation).
            S_GRID_SETUP: begin
                if (g_cull) state <= S_NEXT_CMD;
                else begin
                    grid_w    <= c_w;
                    cells_off <= {c_dst_y, c_dst_x};    // packed byte offset (low 21 bits)
                    v_lo_x    <= g_vlo_x;
                    v_hi_x    <= g_vhi_x;
                    v_lo_y    <= g_vlo_y;
                    v_hi_y    <= g_vhi_y;
                    state     <= S_GRID_BOUNDS;
                end
            end
            // [timing] cell bounds from the REGISTERED pixel window latched above (a
            // clean register->arith->register path per axis). Bit-identical to the
            // old combinational g_cx0/g_cx1/g_cy0/g_cy1, just +1 cycle of latency
            // (once per grid op).
            S_GRID_BOUNDS: begin
                cx0   <= g_cx0[8:0];
                cx1   <= g_cx1[8:0];
                cx    <= g_cx0[8:0];
                cy    <= g_cy0[8:0];
                cy1   <= g_cy1[8:0];
                state <= S_GRID_SETUP2;
            end
            // [timing] row_base = cy*grid_w on the REGISTERED cy latched above (a
            // clean register->multiply->register path). cy[8:0] == g_cy0 here since
            // cy0 < grid_h <= 282 < 512, so this is bit-identical to the old
            // single-cycle g_cy0*c_w, just +1 cycle of latency (once per grid op).
            S_GRID_SETUP2: begin
                row_base <= cy * c_w;
                state    <= S_GRID_FETCH;
            end
            // Read cell (cx,cy) as one 32-bit half of its GRID_BUF qword. grid_cell_qw /
            // grid_cell_idx are combinational off the current row_base/cx.
            S_GRID_FETCH: begin
                bm_rd     <= 1'b1;
                bm_addr   <= grid_cell_qw;
                cell_half <= grid_cell_idx[0];
                rd_ret    <= S_GRID_DECODE;
                state     <= S_RD_WAIT;
            end
            // Decode the cell. EMPTY -> advance one column (or row-advance at the window
            // edge). Non-empty -> clamp the run to the window right edge, latch the
            // resolve inputs (implicit dst = cx*8 / cy*8 into res_dx/res_dy, inheriting
            // the shared #24 signed clip via comp_pipeline), and enter the SHARED resolve.
            S_GRID_DECODE: begin
                if (grid_pid == GRID_CELL_PID_EMPTY) begin
                    if (cx + 9'd1 >= cx1) begin
                        // ROW-ADVANCE: next row, back to cx0, row_base += grid_w.
                        cy       <= cy + 9'd1;
                        cx       <= cx0;
                        row_base <= row_base + grid_w;
                        state    <= (cy + 9'd1 >= cy1) ? S_NEXT_CMD : S_GRID_FETCH;
                    end else begin
                        cx    <= cx + 9'd1;
                        state <= S_GRID_FETCH;
                    end
                end else begin
                    res_pid <= {4'd0, grid_pid};
                    res_dx  <= {{4{1'b0}}, cx, 3'b000};      // cx*8 (>=0)
                    res_dy  <= {{4{1'b0}}, cy, 3'b000};      // cy*8 (>=0)
                    g_sub_x <= grid_sub_x;
                    g_sub_y <= grid_sub_y;
                    // clamp: a run may not pass the window right edge (work-avoidance;
                    // comp_pipeline's per-pixel clip already discards off-screen columns).
                    g_run   <= (cx + grid_run > cx1) ? (cx1 - cx) : grid_run;
                    tl_grid <= 1'b1;
                    state   <= S_TLR_CFT;                    // cft_mem[pid] -> frt_bram resolve
                end
            end
            // Resolve done (frt_q valid): slice the resolved rect + sub-offset + run
            // width into the shared blit fields and issue to comp_pipeline. c_* are held
            // stable through S_GRID_WAIT (comp_pipeline reads them live until blit_done).
            S_GRID_SLICE: begin
                c_src_x    <= frt_q[15:0]  + (g_sub_x << 3);
                c_src_y    <= frt_q[31:16] + (g_sub_y << 3);
                c_w        <= g_run << 3;
                c_h        <= 16'd8;
                c_dst_x    <= $signed(res_dx) + res_bias_x;
                c_dst_y    <= $signed(res_dy) + res_bias_y;
                pipe_start <= 1'b1;
                state      <= S_GRID_WAIT;
            end
            // Hold (c_* stable) until the run blit completes, then advance cx by the run
            // (or row-advance at the window right edge).
            S_GRID_WAIT: if (p_blit_done) begin
                if (cx + g_run >= cx1) begin
                    cy       <= cy + 9'd1;
                    cx       <= cx0;
                    row_base <= row_base + grid_w;
                    state    <= (cy + 9'd1 >= cy1) ? S_NEXT_CMD : S_GRID_FETCH;
                end else begin
                    cx    <= cx + g_run;
                    state <= S_GRID_FETCH;
                end
            end

            S_NEXT_CMD: begin cmd_idx<=cmd_idx+1; tl_grid<=1'b0; state<=S_FETCH; end

            // C_PIPE: the FSM holds here (driving no bus traffic — bm_* idle,
            // pipe_busy hands mem_* to comp_pipeline) until the pipelined blit
            // signals blit_done, then advances to the next command.
            S_PIPE_WAIT: if (p_blit_done) state<=S_NEXT_CMD;

            // [Stage 5 P2 review fix] Reached ONLY from S_SNAP_DRAIN on snap_done, i.e. AFTER
            // the WORK->DDR3 burst for this frame has fully drained into the inactive buffer —
            // the tear-free fence. Publishing here FLIPS the active buffer to the one just
            // written (~fb_bank) so scanout swaps to the fresh frame atomically. fb_bank is
            // fabric-owned and toggles ONLY here — never reloaded from target_buf/C_TARGET —
            // so consecutive frames alternate FB1/FB0/FB1/... instead of pinning to one buffer.
            S_FRAME_VCTRL: begin
                // Publish the new frame: write vctrl + bump frame_counter, then signal
                // C_DONE. (The retired off-screen cache pass used to skip this for
                // target==2; that path no longer exists.)
                bm_wr<=1; bm_be<=8'h0F; bm_addr<=`VCTRL_QW;
                bm_din<={32'd0, vctrl_val};           // active buf = ~fb_bank (just written)
                fb_bank<=~fb_bank;   // flip: fabric-owned DDR3 double-buffer swap (target_buf untouched)
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
                // [Stage 5 P2] VCTRL/C_DONE/C_STATUS now come AFTER the WORK->DDR3 drain
                // (the fence, see below), so the frame is done — resume polling.
                wr_ret<=S_POLL_SUBMIT;
                state<=S_WR_WAIT;
            end

            // [Stage 5 P2] TEAR-FREE FENCE. Reached right after compositing (S_FETCH/
            // S_SETUP), BEFORE VCTRL. Wait for vblank rising (scanout not fetching the FB),
            // then run the WORK->DDR3 burst; only when it fully drains (snap_done) do we
            // advance to S_FRAME_VCTRL to publish/flip the buffer. The burst is held
            // STRICTLY in vblank (vs_rise) because the writer holds the arbiter grant for
            // the whole line-granular burst — safe only while the reader isn't scanning.
            S_SNAP_WAIT: if (vs_rise) begin snap_start<=1'b1; state<=S_SNAP_BUSY; end
            // snap_start pulsed; wait for the writer to raise busy.
            S_SNAP_BUSY: if (snap_busy) state<=S_SNAP_DRAIN;
            // hold here (not compositing, so the WORK buffer is stable) until the last beat
            // drains (snap_done, registered from fb_ddr_writer.done), THEN publish VCTRL.
            S_SNAP_DRAIN: if (snap_done) state<=S_FRAME_VCTRL;

            // (The background-plane bake's trigger/drain states were retired in
            // Stage 3b Phase B2 along with the rest of that RTL.)

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

    // ── WORK->DDR3 snapshot writer [Stage 5 Phase 2] ────────────────────────────
    // Once per frame during vblank (state S_SNAP_* sequences it), streams the completed
    // WORK buffer out to the DDR3 INACTIVE double-buffer via the shared mem_* master
    // (owner mux below). It borrows comp_fbram's WORK read port, so fb_rd_* is muxed: the
    // writer owns it while snap_busy (comp_pipeline is idle between frames), otherwise
    // comp_pipeline's RMW read drives it. base_qw is the INACTIVE buffer = opposite of the
    // active bit VCTRL is about to publish (fb_bank ? FB0 : FB1); the written buffer index
    // is therefore ~fb_bank, which S_FRAME_VCTRL then flips in and publishes. fb_bank is the
    // fabric-owned DDR3 double-buffer index (see its declaration above) — decoupled from
    // target_buf, which the host still reloads from C_TARGET every frame (currently a
    // constant 0 / single-buffer mode) for its other, unrelated bg-cache-era semantics.
    // (`FB0_QW/`FB1_QW == vram_defs.vh `FB_DDR0_QW/`FB_DDR1_QW by construction — same DDR
    // qword bases — and are already in scope via blitter_defs.vh, so no extra include.)
    fb_ddr_writer #(.FB_QWORDS(`FB_QWORDS), .AW(15)) u_snap (
        .clk(clk), .rst(rst),
        .start(snap_start), .base_qw(fb_bank ? `FB0_QW : `FB1_QW),
        .busy(snap_busy), .done(w_snap_done),
        .rd_en(snap_rd_en), .rd_qw(snap_rd_qw), .rd_qword(fb_rd_qword),
        .mem_wr(w_snap_mem_wr), .mem_addr(w_snap_mem_addr), .mem_din(w_snap_mem_din),
        .mem_be(w_snap_mem_be), .mem_burstcnt(w_snap_mem_burstcnt),
        .mem_accept(~mem_busy));   // gappy-burst accept — IDENTICAL to comp_burst's !mem_busy
    // (The background-plane bake's ch0-write streamer + per-cell coverage tracker
    // were retired in Stage 3b Phase B2. ch0 (P_DST) now carries no traffic at all
    // and has no port on this module; the STAGE burst outputs below are plain
    // continuous-assigns of the OP_STAGE atlas FSM's own regs, no longer muxed
    // against a bake stream.)
    assign src_sdram_we_burst = stage_we_burst_fsm;
    assign src_sdram_din64    = stage_din64_fsm;
    assign src_sdram_waddr    = stage_waddr_fsm;

    // 2-way fb_rd mux: snapshot (vblank) > normal compositor. (Was 3-way with the
    // background-plane bake's read side before Stage 3b Phase B2.)
    assign fb_rd_en = snap_busy ? snap_rd_en : pipe_fb_rd_en;
    assign fb_rd_qw = snap_busy ? snap_rd_qw : pipe_fb_rd_qw;

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
    // [Stage 5 P2] Three-way owner mux: comp_pipeline (pipe_busy_q) > WORK->DDR3 writer
    // (snap_busy) > FSM bm_*. The three windows are mutually exclusive: the vblank snap
    // runs between frames after compositing finishes, so pipe_busy_q=0 during snap_busy,
    // and the FSM parks in S_SNAP_BUSY/S_SNAP_DRAIN with bm_rd=bm_wr=0 while it drains.
    // The writer emits a GAPPY line-granular burst (per-beat mem_wr, real burstcnt each
    // beat — NEVER 8'd1), so mem_burstcnt carries w_snap_mem_burstcnt during snap.
    assign mem_addr     = pipe_busy_q ? p_mem_addr     : (snap_busy ? {3'd0, w_snap_mem_addr} : bm_addr);
    assign mem_rd       = pipe_busy_q ? p_mem_rd       : (snap_busy ? 1'b0                    : bm_rd);
    assign mem_wr       = pipe_busy_q ? p_mem_wr       : (snap_busy ? w_snap_mem_wr           : bm_wr);
    assign mem_burstcnt = pipe_busy_q ? p_mem_burstcnt : (snap_busy ? w_snap_mem_burstcnt     : 8'd1);
    assign mem_din      = pipe_busy_q ? p_mem_din      : (snap_busy ? w_snap_mem_din          : bm_din);
    assign mem_be       = pipe_busy_q ? p_mem_be       : (snap_busy ? w_snap_mem_be           : bm_be);

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
