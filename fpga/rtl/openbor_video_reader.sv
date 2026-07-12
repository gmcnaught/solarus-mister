`include "vram_defs.vh"
//============================================================================
//
//  OpenBOR Native Video DDR3 Reader
//
//  Reads 320x240 RGB565 frames from DDR3 and outputs them 1:1 (no scaling).
//
//  OpenBOR's software render path produces 320x240 pixels natively, so we
//  do not need pixel doubling or line doubling like the PICO-8 reader does.
//  This simplifies the pixel output state machine considerably.
//
//  Cart loading via ioctl is PRESERVED from the PICO-8 design — PAKs are
//  loaded via the MiSTer OSD file browser exactly the way PICO-8 cartridges
//  are. Same ioctl byte collection, same flow control via ioctl_wait, same
//  state machine integration with the video reader.
//
//  DDR3 Memory Map (physical addresses):
//    0x3A000000 + 0x000     : Control word (frame_counter[31:2], active_buffer[1:0])
//    0x3A000000 + 0x008     : Joystick data (FPGA writes, ARM reads)
//    0x3A000000 + 0x010     : Cart control (file_size, ARM polls)
//    0x3A000000 + 0x018     : Joystick P2
//    0x3A000000 + 0x020     : Joystick P3
//    0x3A000000 + 0x028     : Joystick P4
//    0x3A000000 + 0x030     : Audio ring write pointer (ARM writes)
//    0x3A000000 + 0x038     : Audio ring read pointer  (FPGA writes)
//    0x3A000000 + 0x040     : Buffer 0 (320x240 RGB565 = 153,600 bytes; 256KB region)
//    0x3A040040             : Buffer 1 (320x240 RGB565; 256KB region)
//    0x3A080000             : Cart data buffer (past video buffers)
//    0x3A0D0000             : Audio ring buffer (64 KiB, 16,384 stereo S16 frames)
//
//  Bandwidth: 153,600 bytes x 60fps = 9.2 MB/s (DDR3 can do >1000)
//
//  Adapted from MiSTer_PICO-8 by MiSTer Organize
//  Copyright (C) 2026 MiSTer Organize -- GPL-3.0
//
//============================================================================

module openbor_video_reader (
    // DDR3 Avalon-MM master
    input  wire        ddr_clk,
    input  wire        ddr_busy,
    output reg   [7:0] ddr_burstcnt,
    output reg  [28:0] ddr_addr,
    input  wire [63:0] ddr_dout,
    input  wire        ddr_dout_ready,
    output reg         ddr_rd,
    output reg  [63:0] ddr_din,
    output wire  [7:0] ddr_be,
    output reg         ddr_we,

    // SDRAM framebuffer read master (P_SCAN) — per-qword cache ok protocol
    output reg  [26:0] scan_addr,
    output reg         scan_rd,
    input  wire [63:0] scan_dout,
    input  wire        scan_ok,

    // Pixel output (clk_vid domain)
    input  wire        clk_vid,
    input  wire        ce_pix,
    input  wire        reset,

    // Timing inputs (from openbor_video_timing)
    input  wire        de,
    input  wire        hblank,
    input  wire        vblank,
    input  wire        new_frame,
    input  wire        new_line,
    input  wire  [8:0] vcount,

    // Cart loading via ioctl (from hps_io)
    input  wire        ioctl_download,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire  [7:0] ioctl_dout,
    output wire        ioctl_wait,

    // Joystick input for all 4 players (from hps_io, clk_sys domain = ddr_clk domain)
    input  wire [31:0] joystick_0,
    input  wire [31:0] joystick_1,
    input  wire [31:0] joystick_2,
    input  wire [31:0] joystick_3,
    input  wire [15:0] joystick_l_analog_0,

    // Pixel output
    output reg   [7:0] r_out,
    output reg   [7:0] g_out,
    output reg   [7:0] b_out,

    // Audio output (clk_audio domain)
    input  wire        clk_audio,       // 24.576 MHz
    output reg  [15:0] audio_l,
    output reg  [15:0] audio_r,

    // Control
    input  wire        enable,
    output wire        frame_ready,

    // DEBUG (issue #34): live blitter state snapshot, published into VSYNC_ADDR's
    // HIGH 32 bits (0x3A070004) each displayed frame. The reader stays alive when
    // the blitter wedges, so devmem 0x3A070004 reveals the frozen blitter state.
    input  wire [31:0] dbg_blt,
    // DEBUG (#34): the blitter's live mem_addr, published to 0x3A070008 (VSYNC_ADDR
    // +1 qword low) so a wedge reveals the EXACT stuck read address.
    input  wire [31:0] dbg_addr,
    // DEBUG (#34): capture-miss diagnostic, published to 0x3A07000C (VSYNC_ADDR+1
    // qword high — previously a redundant copy of dbg_addr). Decisively tests the
    // "blitter missed a delivered SDRAM dst beat" hypothesis vs "beat never
    // delivered". [31:16]=dst_dready beats delivered, [15:8]=delivered-but-missed
    // events, [0]=missed-ever sticky.
    input  wire [31:0] dbg_diag
);

// DDR3 byte enable (always all bytes)
assign ddr_be  = 8'hFF;

// -- DDR3 Address Constants --------------------------------------------
// 29-bit qword addresses = physical >> 3
//
// Buffer layout: 320*240*2 = 153,600 bytes per buffer.
// Round up to 256KB per buffer for clean addressing and headroom.
// 256KB = 0x40000 bytes = 0x8000 qwords.
//
//   Physical          Qword (>>3)        Purpose
//   0x3A000000        29'h07400000       Control word
//   0x3A000008        29'h07400001       Joystick P1 data
//   0x3A000010        29'h07400002       Cart control
//   0x3A000018        29'h07400003       Joystick P2 data
//   0x3A000020        29'h07400004       Joystick P3 data
//   0x3A000028        29'h07400005       Joystick P4 data
//   0x3A000040        29'h07400008       Buffer 0 base
//   0x3A040040        29'h07408008       Buffer 1 base
//   0x3A080000        29'h07410000       Cart data buffer (past video buffers)
//
// Each buffer holds 240 lines × 320 pixels × 2 bytes = 153,600 bytes
// = 19,200 qwords. The next buffer starts 256KB later (0x40000 bytes
// = 0x8000 qwords) leaving plenty of headroom. Cart data lives well
// past the end of BUF1 to allow hot-swap during gameplay without overlap.
localparam [28:0] CTRL_ADDR      = 29'h07400000;  // 0x3A000000 >> 3
localparam [28:0] JOY0_ADDR      = 29'h07400001;  // 0x3A000008 >> 3
localparam [28:0] CART_CTRL_ADDR = 29'h07400002;  // 0x3A000010 >> 3
localparam [28:0] JOY1_ADDR      = 29'h07400003;  // 0x3A000018 >> 3
localparam [28:0] JOY2_ADDR      = 29'h07400004;  // 0x3A000020 >> 3
localparam [28:0] JOY3_ADDR      = 29'h07400005;  // 0x3A000028 >> 3
localparam [28:0] AUDIO_WR_ADDR   = 29'h07400006;  // 0x3A000030 >> 3
localparam [28:0] AUDIO_RD_ADDR   = 29'h07400007;  // 0x3A000038 >> 3
localparam [28:0] BUF0_ADDR      = 29'h07400008;  // 0x3A000040 >> 3
localparam [28:0] BUF1_ADDR      = 29'h07408008;  // 0x3A040040 >> 3
localparam [28:0] CART_DATA_ADDR = 29'h07410000;  // 0x3A080000 >> 3
localparam [28:0] AUDIO_RING_ADDR = 29'h0741A000; // 0x3A0D0000 >> 3
// VSYNC writeback (anti-tearing): the scanout writes an incrementing counter here at
// the start of EACH displayed frame (vblank) so the ARM/engine can vsync-PACE its
// producer — produce exactly one frame per scan into the non-displayed buffer instead
// of free-running at ~60fps and racing the buffer switch (which tore the analog output).
localparam [28:0] VSYNC_ADDR      = 29'h0740E000; // 0x3A070000 >> 3 (free gap post-buffers)
localparam [31:0] AUDIO_RING_BYTES = 32'h00010000; // 64 KiB
localparam [31:0] AUDIO_RING_MASK  = 32'h0000FFFF;

// Audio refill threshold: trigger a fetch when FIFO has < this qwords used.
// FIFO is 512 entries deep; 384 leaves 128 qwords (~5.3 ms) headroom.
localparam [9:0]  AUDIO_REFILL_THRESHOLD = 10'd384;

// 320 pixels × 2 bytes / 8 bytes per qword = 80 beats per scanline
localparam [7:0]  LINE_BURST   = 8'd80;
// Each scanline takes 80 qword addresses
localparam [28:0] LINE_STRIDE  = 29'd80;
// Display lines (no doubling — source = display)
localparam [8:0]  V_ACTIVE     = 9'd240;

localparam [19:0] TIMEOUT_MAX = 20'hF_FFFF;

// --- Blitter paint test (fpga-hw-blitter #003 minimal HW spike) ---------
// When enabled, the reader writes a solid rectangle into the active
// framebuffer each new frame (right after selecting the buffer, before
// scanout). Proves the fabric can WRITE the DDR framebuffer region and have
// it appear on screen, reusing the reader's already-proven DDR master.
// Set to 1'b0 for a normal (no-overlay) core.
localparam        BLT_PAINT_TEST = 1'b0;  // borrow-spike off; arbiter+producer now
localparam [6:0]  RECT_X_QW   = 7'd32;     // left edge, in qwords (px 128)
localparam [3:0]  RECT_W_QW   = 4'd15;     // last col offset (16 qwords = 64 px)
localparam [8:0]  RECT_Y      = 9'd100;    // top line
localparam [8:0]  RECT_BOT    = 9'd131;    // bottom line (inclusive, 32 tall)
localparam [15:0] RECT_COLOR  = 16'h07E0;  // green (RGB565)

// -- Enable synchronizer ----------------------------------------------
reg [1:0] enable_sync;
always @(posedge ddr_clk) begin
    if (reset)
        enable_sync <= 2'b0;
    else
        enable_sync <= {enable_sync[0], enable};
end
wire enable_ddr = enable_sync[1];

// -- CDC: new_frame ----------------------------------------------------
// [#103] 3-FF synchronizer, edge-detect on the two RESOLVED stages ([2]&[1]). The old
// 2-FF chain edge-detected `~sync[1] & sync[0]`, but sync[0] is only ONE flop from the
// async new_frame and can still be metastable -> a runt/double new_frame_ddr. Detecting
// between two resolved stages (both >=2 flops deep) is the correct idiom, matching the
// vcount gray CDC below. Costs one ddr_clk of edge latency (negligible at the DDR rate).
reg [2:0] new_frame_sync;
always @(posedge ddr_clk) begin
    if (reset)
        new_frame_sync <= 3'b0;
    else
        new_frame_sync <= {new_frame_sync[1:0], new_frame};
end
wire new_frame_ddr = ~new_frame_sync[2] & new_frame_sync[1];

// Latch new_frame so it can't be missed during cart writes
reg new_frame_pending;
reg synced;  // Set after first ctrl read -- prevents displaying stale DDR3 data

// -- CDC: new_line -----------------------------------------------------
// [#103] 3-FF synchronizer, edge-detect on the two RESOLVED stages ([2]&[1]) — see the
// new_frame note above. A metastable sync[0] here could runt/double new_line_ddr ->
// display_line double-advance -> same-parity linebuf read/write collision (intermittent
// scanline). Detecting between resolved stages removes the still-metastable node.
reg [2:0] new_line_sync;
always @(posedge ddr_clk) begin
    if (reset)
        new_line_sync <= 3'b0;
    else
        new_line_sync <= {new_line_sync[1:0], new_line};
end
wire new_line_ddr = ~new_line_sync[2] & new_line_sync[1];

// -- CDC: vblank level -------------------------------------------------
reg [1:0] vblank_sync;
always @(posedge ddr_clk) begin
    if (reset)
        vblank_sync <= 2'b0;
    else
        vblank_sync <= {vblank_sync[0], vblank};
end
wire vblank_ddr = vblank_sync[1];

// -- CDC: vcount (clk_vid) -> ddr_clk via gray code -------------------
// The fill re-anchors its fetch to the live scan line (display_line = vcount+1)
// so a sustained f2h underflow recovers within ONE line instead of lagging for
// the rest of the frame (issue #34: cumulative scroll). vcount crosses domains
// as gray code (exactly one bit changes per line) -> a plain 2-FF sync can never
// latch an incoherent multi-bit value. The ONE non-monotonic step is the vcount
// 261->0 wrap (multi-bit), but that occurs inside vblank, and vcount_ddr's only
// consumer (the ST_WAIT_DISPLAY re-anchor) is gated by !vblank_ddr -> the wrap's
// transient is never sampled where it matters.
function [8:0] gray_to_bin9(input [8:0] g);
    integer i;
    reg [8:0] b;
    begin
        b[8] = g[8];
        for (i = 7; i >= 0; i = i - 1)
            b[i] = b[i+1] ^ g[i];
        gray_to_bin9 = b;
    end
endfunction

reg [8:0] vcount_gray;
always @(posedge clk_vid) vcount_gray <= vcount ^ (vcount >> 1);

reg [8:0] vcg_s1, vcg_s2;
always @(posedge ddr_clk) begin
    if (reset) begin
        vcg_s1 <= 9'd0;
        vcg_s2 <= 9'd0;
    end
    else begin
        vcg_s1 <= vcount_gray;
        vcg_s2 <= vcg_s1;
    end
end
wire [8:0] vcount_ddr = gray_to_bin9(vcg_s2);

// -- Reset synchronizer for clk_vid -----------------------------------
reg [1:0] reset_vid_sync;
always @(posedge clk_vid or posedge reset)
    if (reset) reset_vid_sync <= 2'b11;
    else       reset_vid_sync <= {reset_vid_sync[0], 1'b0};
wire reset_vid = reset_vid_sync[1];

// -- CDC: frame_ready --------------------------------------------------
reg frame_ready_reg;
reg [1:0] frame_ready_sync;
always @(posedge clk_vid) begin
    if (reset_vid)
        frame_ready_sync <= 2'b0;
    else
        frame_ready_sync <= {frame_ready_sync[0], frame_ready_reg};
end
wire frame_ready_vid = frame_ready_sync[1];
assign frame_ready = frame_ready_vid;

// -- DDR3 Read State Machine ------------------------------------------
localparam [4:0] ST_IDLE            = 5'd0;
localparam [4:0] ST_POLL_CTRL       = 5'd1;
localparam [4:0] ST_WAIT_CTRL       = 5'd2;
localparam [4:0] ST_CHECK_CTRL      = 5'd3;
localparam [4:0] ST_READ_LINE       = 5'd4;
localparam [4:0] ST_WAIT_LINE       = 5'd5;
localparam [4:0] ST_LINE_DONE       = 5'd6;
localparam [4:0] ST_WAIT_DISPLAY    = 5'd7;
localparam [4:0] ST_WRITE_JOY0      = 5'd8;
localparam [4:0] ST_WRITE_JOY1      = 5'd9;
localparam [4:0] ST_WRITE_JOY2      = 5'd10;
localparam [4:0] ST_WRITE_JOY3      = 5'd11;
localparam [4:0] ST_WRITE_CART      = 5'd12;
localparam [4:0] ST_WRITE_CART_SIZE = 5'd13;
// Audio-path states -- interleaved into idle windows of the video flow.
localparam [4:0] ST_POLL_AUDIO_WR   = 5'd14;
localparam [4:0] ST_WAIT_AUDIO_WR   = 5'd15;
localparam [4:0] ST_PLAN_AUDIO      = 5'd16;
localparam [4:0] ST_READ_AUDIO_RING = 5'd17;
localparam [4:0] ST_WAIT_AUDIO_RING = 5'd18;
localparam [4:0] ST_WRITE_AUDIO_RD  = 5'd19;
localparam [4:0] ST_PAINT            = 5'd20;  // blitter paint-test rectangle
localparam [4:0] ST_WRITE_VSYNC      = 5'd21;  // vblank counter writeback (anti-tearing)

reg  [4:0]  state;
reg  [31:0] ctrl_word;
reg  [29:0] prev_frame_counter;
reg         active_buffer;
reg  [31:0] vsync_count;      // increments each displayed frame; written to VSYNC_ADDR
reg  [26:0] buf_base_addr;   // SDRAM byte base (27-bit)
reg  [8:0]  display_line;     // 0..239 (output display line, also = source line)
reg  [6:0]  beat_count;
// [#44] The P_SCAN cache asserts scan_ok for TWO consecutive cycles per served
// qword (verified in sim, tb_scan_qworddup). The line-fill capture/advance below
// keyed off the scan_ok LEVEL, so it captured each qword twice (2nd capture sees
// the still-unchanged dout) and advanced scan_addr twice — dropping every odd
// qword and duplicating every even one (the "A,B,C,D drawn as A,A,C,C" banding).
// scan_ok_d lets us act only on the RISING edge of scan_ok: exactly one accept
// per serve.
reg         scan_ok_d;
// [#39 probe] OR-accumulate every scan_dout (FB data read from SDRAM ch4) over a
// frame; published in the VSYNC writeback high word (0x3A070004). Non-zero ->
// the FB IS in SDRAM and the reader reads it (so a black screen is a reader-data/
// display bug); zero -> the FB never landed in the SDRAM region we read
// (coherency flush / eviction). Reset each frame at the vsync writeback.
    // [#39] Debug scanout probe (reader display-side state -> VSYNC_ADDR high
    // word 0x3A070004, + scan_acc/max_dline tracking). Compile-time optional:
    // OFF by default (ships clean, low word 0x3A070000 = engine vsync pacing);
    // build with +define+SOLARUS_DBG_PROBES (sim) or VERILOG_MACRO SOLARUS_DBG_PROBES
    // (Quartus qsf) to re-enable for hardware bring-up.
    reg  [31:0] scan_acc;
// [#39 probe v2] peak display_line ever reached. If first_frame_loaded never sets
// and this sticks below 239, the vcount-anchored fetch skips past line 239 (never
// completes a frame -> frame_ready never asserts -> pure black).
reg  [8:0]  max_dline;
reg         first_frame_loaded;
reg  [4:0]  stale_vblank_count;
reg         preloading;
reg  [19:0] timeout_cnt;
reg  [9:0]  paint_cnt;       // blitter paint-test: rect qword counter

// Audio state
reg  [31:0] audio_wr_ptr;
reg  [31:0] audio_rd_ptr;
reg  [7:0]  audio_burst_rem;
reg  [31:0] audio_burst_bytes;
reg  [19:0] audio_backoff;

// Cart loading registers
reg  [63:0] cart_buf;
reg   [2:0] cart_byte_cnt;
reg         cart_write_pending;
reg  [28:0] cart_write_addr;
reg  [63:0] cart_write_data;
reg         cart_size_pending;
reg  [26:0] cart_total_bytes;
reg         cart_dl_prev;
reg         cart_loading;

assign ioctl_wait = cart_write_pending & ioctl_download;

// -- Line buffers (position-addressed ping-pong scanout) --------------
// Two display lines of RGB565, stored as 80 x 64-bit words each (4 px/word),
// addressed by line parity: line L always lives in buffer L%2. Write port is
// ddr_clk (fill), read port is clk_vid (scanout) -> true dual-clock BRAM (M10K),
// which carries the data CDC. Index = {buf(1), word(7)} -> 0..255.
// [LAB-overflow fix] explicit ramstyle: comment above always intended M10K, but
// nothing enforced it -- AUTO silently de-inferred this to ~16K flip-flops once
// unrelated M10K pressure appeared elsewhere in the design (bgw_argb4444 going
// real). no_rw_check is safe: line-parity addressing means write/read never
// target the same half concurrently.
(* ramstyle = "no_rw_check, M10K" *) reg  [63:0] linebuf [0:255];
reg         lb_we;
reg  [7:0]  lb_waddr;
reg  [63:0] lb_wdata;

// -- Audio FIFO write signals -----------------------------------------
reg         audio_fifo_wr;
reg  [63:0] audio_fifo_wr_data;
wire        audio_fifo_empty;
wire [9:0]  audio_fifo_wrusedw;
wire        audio_fifo_low = (audio_fifo_wrusedw < AUDIO_REFILL_THRESHOLD);

// Audio fetch eligibility (combinational)
wire [31:0] audio_bytes_avail = (audio_wr_ptr - audio_rd_ptr) & AUDIO_RING_MASK;
wire        audio_wake        = enable_ddr && audio_fifo_low && (audio_backoff == 20'd0);

// Burst planning (combinational, used in ST_PLAN_AUDIO).
wire [31:0] audio_plan_cand_a  = (audio_bytes_avail > 32'd256) ? 32'd256 : audio_bytes_avail;
wire [31:0] audio_plan_wrap    = AUDIO_RING_BYTES - (audio_rd_ptr & AUDIO_RING_MASK);
wire [31:0] audio_plan_cand_b  = (audio_plan_cand_a > audio_plan_wrap) ? audio_plan_wrap : audio_plan_cand_a;
wire [31:0] audio_plan_bytes   = audio_plan_cand_b & 32'hFFFFFFF8;
wire [7:0]  audio_plan_qwords  = audio_plan_bytes[10:3];

// -- FIFO async clear -------------------------------------------------
reg [3:0] fifo_aclr_cnt;
wire fifo_aclr_ddr_active = (fifo_aclr_cnt != 4'd0);

// -- Main state machine -----------------------------------------------
always @(posedge ddr_clk) begin
    if (reset) begin
        state              <= ST_IDLE;
        ddr_rd             <= 1'b0;
        ddr_we             <= 1'b0;
        ddr_din            <= 64'd0;
        ddr_burstcnt       <= 8'd1;
        ddr_addr           <= 29'd0;
        ctrl_word          <= 32'd0;
        prev_frame_counter <= 30'd0;
        active_buffer      <= 1'b0;
        vsync_count        <= 32'd0;
        buf_base_addr      <= 27'd0;
        scan_addr          <= 27'd0;
        scan_rd            <= 1'b0;
        scan_ok_d          <= 1'b0;
        display_line       <= 9'd0;
        beat_count         <= 7'd0;
        scan_acc           <= 32'd0;
        max_dline          <= 9'd0;
        first_frame_loaded <= 1'b0;
        frame_ready_reg    <= 1'b0;
        stale_vblank_count <= 5'd0;
        preloading         <= 1'b0;
        timeout_cnt        <= 20'd0;
        paint_cnt          <= 10'd0;
        lb_we              <= 1'b0;
        lb_waddr           <= 8'd0;
        lb_wdata           <= 64'd0;
        fifo_aclr_cnt      <= 4'd0;
        cart_buf           <= 64'd0;
        cart_byte_cnt      <= 3'd0;
        cart_write_pending <= 1'b0;
        cart_write_addr    <= 29'd0;
        cart_write_data    <= 64'd0;
        cart_size_pending  <= 1'b0;
        cart_total_bytes   <= 27'd0;
        cart_dl_prev       <= 1'b0;
        cart_loading       <= 1'b0;
        new_frame_pending  <= 1'b0;
        synced             <= 1'b0;
        audio_wr_ptr       <= 32'd0;
        audio_rd_ptr       <= 32'd0;
        audio_burst_rem    <= 8'd0;
        audio_burst_bytes  <= 32'd0;
        audio_backoff      <= 20'd0;
        audio_fifo_wr      <= 1'b0;
        audio_fifo_wr_data <= 64'd0;
    end
    else begin
        lb_we         <= 1'b0;
        audio_fifo_wr <= 1'b0;
        if (audio_backoff != 20'd0) audio_backoff <= audio_backoff - 20'd1;
        if (fifo_aclr_cnt != 4'd0) fifo_aclr_cnt <= fifo_aclr_cnt - 4'd1;
        if (!ddr_busy) ddr_rd <= 1'b0;
        if (!ddr_busy) ddr_we <= 1'b0;
        scan_rd <= 1'b0;
        scan_ok_d <= scan_ok;   // [#44] for rising-edge detect of the 2-cycle scan_ok

        // Latch new_frame pulse so cart writes can't cause it to be missed
        if (new_frame_ddr) new_frame_pending <= 1'b1;

        // Beat capture -> back line buffer. Line L fills buffer L%2 at word=beat.
        // (display_line is the line being fetched; it increments in ST_LINE_DONE.)
        // Line fetch now comes from the P_SCAN cache channel (scan_dout/scan_ok).
        // [#44] Capture on the RISING edge of scan_ok only — scan_ok is asserted
        // for 2 cycles per served qword; the 2nd cycle carries the SAME (stale)
        // dout, so capturing on the level duplicated qwords (A,A,C,C).
        if (state == ST_WAIT_LINE && scan_ok && !scan_ok_d) begin
            lb_we      <= 1'b1;
            lb_waddr   <= {display_line[0], beat_count};
            lb_wdata   <= scan_dout;
            beat_count <= beat_count + 7'd1;
            timeout_cnt<= 20'd0;
`ifdef SOLARUS_DBG_PROBES
            scan_acc   <= scan_acc | scan_dout[63:32] | scan_dout[31:0];  // [#39 probe]
`endif
        end

        // -- Cart byte collection (runs in parallel) --------------
        cart_dl_prev <= ioctl_download;

        // Download start
        if (ioctl_download && !cart_dl_prev) begin
            cart_loading     <= 1'b1;
            cart_byte_cnt    <= 3'd0;
            cart_buf         <= 64'd0;
            cart_total_bytes <= 27'd0;
        end

        // Collect bytes — cap DDR3 writes at 256KB to prevent overflow
        // (SC0 mount — ARM reads PAK path from .s0, loads from SD directly)
        if (ioctl_download && ioctl_wr && !cart_write_pending) begin
            cart_total_bytes <= ioctl_addr + 27'd1;

            if (ioctl_addr < 27'h40000) begin
                case (cart_byte_cnt)
                    3'd0: cart_buf[ 7: 0] <= ioctl_dout;
                    3'd1: cart_buf[15: 8] <= ioctl_dout;
                    3'd2: cart_buf[23:16] <= ioctl_dout;
                    3'd3: cart_buf[31:24] <= ioctl_dout;
                    3'd4: cart_buf[39:32] <= ioctl_dout;
                    3'd5: cart_buf[47:40] <= ioctl_dout;
                    3'd6: cart_buf[55:48] <= ioctl_dout;
                    3'd7: cart_buf[63:56] <= ioctl_dout;
                endcase

                if (cart_byte_cnt == 3'd7) begin
                    cart_write_pending <= 1'b1;
                    cart_write_addr    <= CART_DATA_ADDR + {2'd0, ioctl_addr[26:3]};
                    cart_write_data    <= {ioctl_dout, cart_buf[55:0]};
                    cart_byte_cnt      <= 3'd0;
                end
                else begin
                    cart_byte_cnt <= cart_byte_cnt + 3'd1;
                end
            end
        end

        // Download end -- flush partial + write size
        if (!ioctl_download && cart_dl_prev && cart_loading) begin
            cart_loading      <= 1'b0;
            cart_size_pending <= 1'b1;
            if (cart_byte_cnt != 3'd0 && !cart_write_pending && cart_total_bytes <= 27'h40000) begin
                cart_write_pending <= 1'b1;
                cart_write_addr    <= CART_DATA_ADDR + {2'd0, cart_total_bytes[26:3]};
                cart_write_data    <= cart_buf;
                cart_byte_cnt      <= 3'd0;
            end
        end

        case (state)
            ST_IDLE: begin
                // Frame reads always get priority -- video must never be starved.
                // Cart writes happen between frame reads.
                // Audio fetches happen last, only when nothing else is pending.
                // new_frame_pending is latched so it can't be missed.
                if (enable_ddr && new_frame_pending) begin
                    new_frame_pending <= 1'b0;  // consumed
                    state <= ST_WRITE_JOY0;
                end
                else if (cart_write_pending)
                    state <= ST_WRITE_CART;
                else if (cart_size_pending)
                    state <= ST_WRITE_CART_SIZE;
                else if (audio_wake)
                    state <= ST_POLL_AUDIO_WR;
            end

            ST_WRITE_JOY0: begin
                // Write joystick_0 (P1) to DDR3 so ARM can read it
                if (!ddr_busy) begin
                    ddr_addr     <= JOY0_ADDR;
                    ddr_din      <= {32'd0, joystick_0};
                    ddr_burstcnt <= 8'd1;
                    ddr_we       <= 1'b1;
                    state        <= ST_WRITE_JOY1;
                end
            end

            ST_WRITE_JOY1: begin
                // Write joystick_1 (P2) to DDR3
                if (!ddr_busy) begin
                    ddr_addr     <= JOY1_ADDR;
                    ddr_din      <= {32'd0, joystick_1};
                    ddr_burstcnt <= 8'd1;
                    ddr_we       <= 1'b1;
                    state        <= ST_WRITE_JOY2;
                end
            end

            ST_WRITE_JOY2: begin
                // Write joystick_2 (P3) to DDR3
                if (!ddr_busy) begin
                    ddr_addr     <= JOY2_ADDR;
                    ddr_din      <= {32'd0, joystick_2};
                    ddr_burstcnt <= 8'd1;
                    ddr_we       <= 1'b1;
                    state        <= ST_WRITE_JOY3;
                end
            end

            ST_WRITE_JOY3: begin
                // Write joystick_3 (P4) to DDR3, then write the vsync counter
                if (!ddr_busy) begin
                    ddr_addr     <= JOY3_ADDR;
                    ddr_din      <= {32'd0, joystick_3};
                    ddr_burstcnt <= 8'd1;
                    ddr_we       <= 1'b1;
                    state        <= ST_WRITE_VSYNC;
                end
            end

            ST_WRITE_VSYNC: begin
                // Anti-tearing: at each frame start (vblank) publish an incrementing
                // counter so the ARM/engine can vsync-pace its producer (one frame per
                // scan into the non-displayed buffer) instead of racing the buffer swap.
                if (!ddr_busy) begin
                    ddr_addr     <= VSYNC_ADDR;
                    // low 32 = vsync_count (engine pacing, 0x3A070000);
                    // [#39 probe v2] high 32 (0x3A070004) = reader display-side state:
                    //   [31]=first_frame_loaded [30]=frame_ready_reg [29]=synced
                    //   [28]=preloading [27:9]=scan_acc[18:0](FB-read activity)
                    //   [8:0]=max_dline (peak display_line ever fetched; 239 = full frame).
`ifdef SOLARUS_DBG_PROBES
                    ddr_din      <= {first_frame_loaded, frame_ready_reg, synced,
                                     preloading, scan_acc[18:0], max_dline, vsync_count};
`else
                    ddr_din      <= {32'd0, vsync_count};   // ship: low word = engine vsync pacing
`endif
                    ddr_burstcnt <= 8'd1;
                    ddr_we       <= 1'b1;
                    vsync_count  <= vsync_count + 32'd1;
`ifdef SOLARUS_DBG_PROBES
                    scan_acc     <= 32'd0;   // [#39 probe] reset for the next frame
`endif
                    state        <= ST_POLL_CTRL;
                end
            end

            ST_WRITE_CART: begin
                // Write 8 bytes of cart data to DDR3
                if (!ddr_busy) begin
                    ddr_addr           <= cart_write_addr;
                    ddr_din            <= cart_write_data;
                    ddr_burstcnt       <= 8'd1;
                    ddr_we             <= 1'b1;
                    cart_write_pending <= 1'b0;
                    cart_buf           <= 64'd0;
                    // If download ended and this was the flush, write size next
                    if (!cart_loading && cart_size_pending)
                        state <= ST_WRITE_CART_SIZE;
                    else
                        state <= ST_IDLE;
                end
            end

            ST_WRITE_CART_SIZE: begin
                // Write file size to cart control address
                if (!ddr_busy) begin
                    ddr_addr          <= CART_CTRL_ADDR;
                    ddr_din           <= {32'd0, 5'd0, cart_total_bytes};
                    ddr_burstcnt      <= 8'd1;
                    ddr_we            <= 1'b1;
                    cart_size_pending <= 1'b0;
                    state             <= ST_IDLE;
                end
            end

            ST_POLL_CTRL: begin
                if (!ddr_busy) begin
                    ddr_addr     <= CTRL_ADDR;
                    ddr_burstcnt <= 8'd1;
                    ddr_rd       <= 1'b1;
                    timeout_cnt  <= 20'd0;
                    state        <= ST_WAIT_CTRL;
                end
            end

            ST_WAIT_CTRL: begin
                if (ddr_dout_ready) begin
                    ctrl_word   <= ddr_dout[31:0];
                    timeout_cnt <= 20'd0;
                    state       <= ST_CHECK_CTRL;
                end
                else if (timeout_cnt == TIMEOUT_MAX)
                    state <= ST_IDLE;
                else
                    timeout_cnt <= timeout_cnt + 20'd1;
            end

            ST_CHECK_CTRL: begin
                if (!synced) begin
                    // First read after reset -- capture stale DDR3 counter
                    // without displaying anything. Prevents showing old game
                    // data that persists in DDR3 across reboots.
                    prev_frame_counter <= ctrl_word[31:2];
                    synced <= 1'b1;
                    state <= ST_IDLE;
                end
                else if (ctrl_word[31:2] != prev_frame_counter) begin
                    // New frame available
                    prev_frame_counter <= ctrl_word[31:2];
                    active_buffer      <= ctrl_word[0];
                    stale_vblank_count <= 5'd0;
                    // [FB-in-BRAM] Single on-chip framebuffer (comp_fbram): the scan
                    // fetch addresses one buffer at base 0, so scan_addr = line*640 +
                    // beat*8 and the fbram_scan_adapter maps scan_addr[17:3] -> qword.
                    // (active_buffer is still tracked but no longer selects a base.)
                    buf_base_addr      <= 27'd0;
                    display_line       <= 9'd0;
                    preloading         <= 1'b1;
                    fifo_aclr_cnt      <= 4'd8;
                    paint_cnt          <= 10'd0;
                    // Paint the test rectangle into the just-committed buffer
                    // (post-ARM-write, pre-scanout) before reading lines.
                    state              <= BLT_PAINT_TEST ? ST_PAINT : ST_READ_LINE;
                end
                else if (first_frame_loaded) begin
                    // Stale frame -- re-read previous buffer
                    if (stale_vblank_count < 5'd30)
                        stale_vblank_count <= stale_vblank_count + 5'd1;
                    if (stale_vblank_count >= 5'd29)
                        frame_ready_reg <= 1'b0;
                    display_line  <= 9'd0;
                    preloading    <= 1'b1;
                    fifo_aclr_cnt <= 4'd8;
                    state         <= ST_READ_LINE;
                end
                else
                    state <= ST_IDLE;
            end

            ST_READ_LINE: begin
                if (!fifo_aclr_ddr_active) begin
                    // No vertical doubling -- source line == display line.
                    // Each scanline is 640 bytes (SDRAM_FB_STRIDE), 80 qwords.
                    // Issue first per-qword cache read (scan_rd=1 with scan_addr).
                    // The cache ok protocol requires no sdram_busy check — there
                    // is no sdram_busy in the P_SCAN channel; the reader just
                    // pulses scan_rd and waits for scan_ok before advancing.
                    scan_addr    <= buf_base_addr + ({18'd0, display_line} * `SDRAM_FB_STRIDE);
                    scan_rd      <= 1'b1;
                    beat_count   <= 7'd0;
                    timeout_cnt  <= 20'd0;
                    state        <= ST_WAIT_LINE;
                end
            end

            ST_WAIT_LINE: begin
                if (beat_count == LINE_BURST[6:0]) begin
                    // All 80 qwords captured; scan_rd already cleared by the
                    // default clear above (fires the cycle after the last ok).
                    state <= ST_LINE_DONE;
                end
                // P_SCAN ok protocol with HOLD-until-ok backpressure: scan_rd is
                // held high while the request is outstanding (the else branch),
                // dropped for one cycle on the accepted (rising-edge) scan_ok, then
                // re-asserted for the next qword's address. A starve only DELAYS
                // scan_ok; the held request completes when it lifts.
                // [#44] Advance on the RISING edge of scan_ok only (one accept per
                // served qword) — see scan_ok_d. The 2nd scan_ok cycle now falls to
                // the else branch (re-assert/hold), NOT a second advance, so no qword
                // is skipped.
                else if (scan_ok && !scan_ok_d) begin
                    // Beat captured in the shared block above; advance to the next
                    // qword. After beat 79 do NOT advance/re-issue — beat_count
                    // reaches 80 next cycle and we go to ST_LINE_DONE.
                    if (beat_count != (LINE_BURST[6:0] - 7'd1))
                        scan_addr <= scan_addr + 27'd8;   // next qword (8 bytes)
                end
                else begin
                    // Request outstanding (or the 2nd, stale scan_ok cycle): hold
                    // scan_rd until the next fresh serve.
                    scan_rd <= 1'b1;
                    if (timeout_cnt == TIMEOUT_MAX)
                        state <= ST_IDLE;          // safety: avoid a true hang
                    else
                        timeout_cnt <= timeout_cnt + 20'd1;
                end
            end

            ST_LINE_DONE: begin
                display_line <= display_line + 9'd1;
`ifdef SOLARUS_DBG_PROBES
                if (display_line > max_dline) max_dline <= display_line;  // [#39 probe v2]
`endif

                if (display_line == V_ACTIVE - 9'd1) begin
                    first_frame_loaded <= 1'b1;
                    frame_ready_reg    <= 1'b1;
                    preloading         <= 1'b0;
                    state              <= ST_IDLE;
                end
                else begin
                    // Preload exactly line 0; thereafter each new_line in
                    // ST_WAIT_DISPLAY fetches line N+1 while line N is displayed
                    // (one full line of fill slack, 2-buffer ping-pong).
                    preloading <= 1'b0;
                    state      <= ST_WAIT_DISPLAY;
                end
            end

            ST_WAIT_DISPLAY: begin
                if (display_line < V_ACTIVE && new_line_ddr && !vblank_ddr) begin
                    // Re-anchor the fetch to the live scan position so a sustained
                    // underflow recovers within one line instead of lagging for the
                    // rest of the frame (issue #34: cumulative scroll). In normal
                    // operation display_line is already == vcount+1, so this only
                    // fires after the fill has fallen behind the display. Clamped so
                    // we never target a line past the active region.
                    if (display_line < (vcount_ddr + 9'd1) && (vcount_ddr + 9'd1) < V_ACTIVE)
                        display_line <= vcount_ddr + 9'd1;
                    state <= ST_READ_LINE;
                end
            end

            // -- Audio path: poll wr_ptr, read ring, write rd_ptr ---
            ST_POLL_AUDIO_WR: begin
                if (!ddr_busy) begin
                    ddr_addr     <= AUDIO_WR_ADDR;
                    ddr_burstcnt <= 8'd1;
                    ddr_rd       <= 1'b1;
                    timeout_cnt  <= 20'd0;          // [#39] arm watchdog
                    state        <= ST_WAIT_AUDIO_WR;
                end
            end

            ST_WAIT_AUDIO_WR: begin
                if (ddr_dout_ready) begin
                    audio_wr_ptr <= ddr_dout[31:0];
                    timeout_cnt  <= 20'd0;
                    state        <= ST_PLAN_AUDIO;
                end
                // [#39] a lost f2h read-response must not wedge the shared scanout
                // FSM: recover to ST_IDLE (mirrors ST_WAIT_CTRL / ST_WAIT_LINE).
                else if (timeout_cnt == TIMEOUT_MAX)
                    state <= ST_IDLE;
                else
                    timeout_cnt <= timeout_cnt + 20'd1;
            end

            ST_PLAN_AUDIO: begin
                // Now audio_bytes_avail is valid (audio_wr_ptr just latched).
                if (audio_bytes_avail == 32'd0) begin
                    // Ring empty -- back off briefly to avoid DDR3 spam.
                    audio_backoff <= 20'h01000;  // ~42 us at 98.44 MHz clk_sys
                    state         <= ST_IDLE;
                end
                else if (!audio_fifo_low) begin
                    // FIFO filled up while we were polling; don't fetch.
                    state <= ST_IDLE;
                end
                else if (audio_plan_bytes == 32'd0) begin
                    state <= ST_IDLE;
                end
                else begin
                    // Plan a burst: min(bytes_avail, 256, ring_wrap_room),
                    // floored to a multiple of 8 bytes (one qword).
                    audio_burst_bytes <= audio_plan_bytes;
                    audio_burst_rem   <= audio_plan_qwords;
                    state             <= ST_READ_AUDIO_RING;
                end
            end

            ST_READ_AUDIO_RING: begin
                if (!ddr_busy) begin
                    ddr_addr     <= AUDIO_RING_ADDR + audio_rd_ptr[15:3];
                    ddr_burstcnt <= audio_burst_rem;
                    ddr_rd       <= 1'b1;
                    timeout_cnt  <= 20'd0;          // [#39] arm watchdog
                    state        <= ST_WAIT_AUDIO_RING;
                end
            end

            ST_WAIT_AUDIO_RING: begin
                if (ddr_dout_ready) begin
                    audio_fifo_wr_data <= ddr_dout;
                    audio_fifo_wr      <= 1'b1;
                    audio_burst_rem    <= audio_burst_rem - 8'd1;
                    timeout_cnt        <= 20'd0;       // progress: re-arm watchdog
                    if (audio_burst_rem == 8'd1) begin
                        audio_rd_ptr <= (audio_rd_ptr + audio_burst_bytes) & AUDIO_RING_MASK;
                        state        <= ST_WRITE_AUDIO_RD;
                    end
                end
                // [#39] short-burst recovery (mirror ST_WAIT_LINE): the shared f2h
                // bus occasionally returns fewer beats than ddr_burstcnt (the
                // arbiter self-corrects via QUIET_MAX; the reader did not), which
                // wedged the single shared scanout FSM forever -> vsync freeze ->
                // black screen. Abandon the partial burst and re-plan next wake;
                // do NOT advance audio_rd_ptr -- the burst didn't complete.
                else if (timeout_cnt == TIMEOUT_MAX)
                    state <= ST_IDLE;
                else
                    timeout_cnt <= timeout_cnt + 20'd1;
            end

            ST_WRITE_AUDIO_RD: begin
                if (!ddr_busy) begin
                    ddr_addr     <= AUDIO_RD_ADDR;
                    ddr_din      <= {32'd0, audio_rd_ptr};
                    ddr_burstcnt <= 8'd1;
                    ddr_we       <= 1'b1;
                    state        <= ST_IDLE;
                end
            end

            // Blitter paint-test: write a 64x32 solid rectangle into the active
            // framebuffer (16 qwords/line x 32 lines = 512 single-beat writes),
            // then proceed to normal scanout. paint_cnt[9:4]=line, [3:0]=col.
            ST_PAINT: begin
                if (paint_cnt == 10'd512) begin
                    state <= ST_READ_LINE;
                end
                else if (!ddr_busy) begin
                    ddr_addr     <= buf_base_addr
                                  + (RECT_Y + {3'b0, paint_cnt[9:4]}) * LINE_STRIDE
                                  + (RECT_X_QW + {3'b0, paint_cnt[3:0]});
                    ddr_din      <= {RECT_COLOR, RECT_COLOR, RECT_COLOR, RECT_COLOR};
                    ddr_burstcnt <= 8'd1;
                    ddr_we       <= 1'b1;
                    paint_cnt    <= paint_cnt + 10'd1;
                end
            end

            default: state <= ST_IDLE;
        endcase
    end
end

// -- Line-buffer read port + position-addressed pixel output ----------
//
// Read side is anchored to DISPLAY POSITION, not buffer occupancy:
//   * hcol counts output pixels 0..319, reset at new_line, advanced on ce_pix
//     within de. word group = hcol[8:2] (0..79), sub-pixel lane = hcol[1:0].
//   * the buffer for the current display line = vcount[0] (line L -> buf L%2),
//     which matches the fill (line L written to buf L%2). No swap toggle needed.
//   * BRAM read has 1 clk_vid latency; ce_pix is ~1-in-8, so lb_q is always
//     settled to word(hcol) before the next ce_pix.
// An underflow leaves the current buffer stale for ONE line; the next line
// re-anchors (vcount advances, reads the freshly-filled buffer). No drift.
// In normal operation the read buffer (vcount[0]) and the fill buffer
// (display_line[0]) are opposite parity, so reads and writes never collide. The
// one case they can coincide is a deep underflow where the fill has fallen onto
// the line being displayed -- a same-address dual-port read returns undefined
// data for that beat, i.e. exactly the tolerated single-line glitch (the fetch
// re-anchor then recovers the next line).
reg  [8:0]  hcol;
reg  [63:0] lb_q;

// vcount here is the native clk_vid timing counter (same domain as this read
// port) -- no CDC needed. The ddr_clk fill side uses the gray-synced vcount_ddr.
always @(posedge clk_vid)
    lb_q <= linebuf[{vcount[0], hcol[8:2]}];

wire [15:0] cur_pix = lb_q[{hcol[1:0], 4'b0000} +: 16];
wire  [7:0] dec_r = {cur_pix[15:11], cur_pix[15:13]};
wire  [7:0] dec_g = {cur_pix[10:5],  cur_pix[10:9]};
wire  [7:0] dec_b = {cur_pix[4:0],   cur_pix[4:2]};

always @(posedge clk_vid) begin
    if (reset_vid) begin
        hcol  <= 9'd0;
        r_out <= 8'd0;
        g_out <= 8'd0;
        b_out <= 8'd0;
    end
    else if (ce_pix) begin
        // Output the pixel for the current hcol (lb_q already settled).
        if (de && frame_ready_vid) begin
            r_out <= dec_r;
            g_out <= dec_g;
            b_out <= dec_b;
        end
        else begin
            r_out <= 8'd0;
            g_out <= 8'd0;
            b_out <= 8'd0;
        end

        // Advance the position anchor.
        if (new_line)
            hcol <= 9'd0;
        else if (de)
            hcol <= (hcol == 9'd319) ? hcol : (hcol + 9'd1);
    end
end

// -- Dedicated line-buffer write port (ddr_clk) -----------------------
always @(posedge ddr_clk)
    if (lb_we) linebuf[lb_waddr] <= lb_wdata;

// -- Audio dual-clock FIFO (ddr_clk write, clk_audio read) -----------
// 64-bit wide (= 2 stereo frames per entry), 1024 deep. Read side
// alternates halves, popping every other sample.
wire [63:0] audio_fifo_rd_data;
reg         audio_fifo_rd;

dcfifo #(
    .intended_device_family ("Cyclone V"),
    .lpm_numwords           (1024),
    .lpm_showahead          ("ON"),
    .lpm_type               ("dcfifo"),
    .lpm_width              (64),
    .lpm_widthu             (10),
    .overflow_checking      ("ON"),
    .rdsync_delaypipe       (4),
    .underflow_checking     ("ON"),
    .use_eab                ("ON"),
    .wrsync_delaypipe       (4)
) audio_fifo_inst (
    .aclr     (reset),
    .data     (audio_fifo_wr_data),
    .rdclk    (clk_audio),
    .rdreq    (audio_fifo_rd),
    .wrclk    (ddr_clk),
    .wrreq    (audio_fifo_wr),
    .q        (audio_fifo_rd_data),
    .rdempty  (audio_fifo_empty),
    .wrfull   (),
    .wrusedw  (audio_fifo_wrusedw),
    .eccstatus(),
    .rdfull   (),
    .rdusedw  (),
    .wrempty  ()
);

// -- 48 kHz sample clock (clk_audio / 512 = 48 kHz exactly) ----------
reg [8:0] aud_div;
reg       aud_tick;
reg [1:0] reset_aud_sync;
always @(posedge clk_audio or posedge reset)
    if (reset) reset_aud_sync <= 2'b11;
    else       reset_aud_sync <= {reset_aud_sync[0], 1'b0};
wire reset_aud = reset_aud_sync[1];

always @(posedge clk_audio) begin
    if (reset_aud) begin
        aud_div  <= 9'd0;
        aud_tick <= 1'b0;
    end
    else begin
        aud_div  <= aud_div + 9'd1;
        aud_tick <= (aud_div == 9'd0);
    end
end

// -- Audio sample output (clk_audio domain) --------------------------
// Each FIFO entry carries two stereo frames:
//   [15:0]   L0
//   [31:16]  R0
//   [47:32]  L1
//   [63:48]  R1
// Alternate halves, pop every other tick.
reg half_sel;
always @(posedge clk_audio) begin
    if (reset_aud) begin
        audio_l       <= 16'd0;
        audio_r       <= 16'd0;
        audio_fifo_rd <= 1'b0;
        half_sel      <= 1'b0;
    end
    else begin
        audio_fifo_rd <= 1'b0;
        if (aud_tick) begin
            if (!audio_fifo_empty) begin
                if (half_sel == 1'b0) begin
                    audio_l  <= audio_fifo_rd_data[15:0];
                    audio_r  <= audio_fifo_rd_data[31:16];
                    half_sel <= 1'b1;
                end
                else begin
                    audio_l       <= audio_fifo_rd_data[47:32];
                    audio_r       <= audio_fifo_rd_data[63:48];
                    audio_fifo_rd <= 1'b1;       // advance to next qword
                    half_sel      <= 1'b0;
                end
            end
            // else: underflow, hold previous sample
        end
    end
end

endmodule
