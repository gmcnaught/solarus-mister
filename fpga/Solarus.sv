//============================================================================
//
//  Menu for MiSTer.
//  Copyright (C) 2017-2020 Sorgelig
//
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS,

	// Native video active signal for sys_top.v vsync routing
	output        NATIVE_VID_ACTIVE
);

assign ADC_BUS  = 'Z;
assign {UART_RTS, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign DDRAM_CLK = clk_sys;

// CE_PIXEL: exact Genesis H40 timing from CLK_VIDEO (53.693 MHz).
// Active pixels: /8 (6.712 MHz). Blanking uses variable /8,/9,/10 widths
// so that total MCLK per line = 3420, matching Genesis exactly (H_TOTAL=420).
// Pattern per line: 320 active @/8 + blanking @mixed = 3420 MCLK total.
reg [3:0] ce_cnt;
reg ce_pix_gen;
reg [9:0] pix_in_line;

// Blanking pixel width schedule: Genesis uses 28@/10 + 4@/9 + 68@/8 = 100 blanking pixels
// 28*10 + 4*9 + 68*8 = 280+36+544 = 860 MCLK blanking. 320*8 + 860 = 3420 total.
wire in_active = (pix_in_line < 10'd320);
wire in_blank_10 = (pix_in_line >= 10'd320) && (pix_in_line < 10'd348);
wire in_blank_9  = (pix_in_line >= 10'd348) && (pix_in_line < 10'd352);
wire [3:0] pix_width = in_active   ? 4'd7 :   // /8: count 0-7
                        in_blank_10 ? 4'd9 :   // /10: count 0-9
                        in_blank_9  ? 4'd8 :   // /9: count 0-8
                                      4'd7;    // /8: remaining blanking

always @(posedge CLK_VIDEO) begin
	if (RESET) begin
		ce_cnt <= 4'd0;
		ce_pix_gen <= 1'b0;
		pix_in_line <= 10'd0;
	end
	else begin
		ce_pix_gen <= (ce_cnt == 4'd0);
		if (ce_cnt == pix_width) begin
			ce_cnt <= 4'd0;
			if (pix_in_line == 10'd419)
				pix_in_line <= 10'd0;
			else
				pix_in_line <= pix_in_line + 10'd1;
		end
		else begin
			ce_cnt <= ce_cnt + 4'd1;
		end
	end
end
assign CE_PIXEL = ce_pix_gen;

assign VGA_SL = 0;
assign VGA_F1 = 0;
// OpenBOR renders at 320x240, 4:3 aspect ratio. When Vertical Crop (status[18])
// is off, freak_arx/freak_ary (video_freak, instantiated below near h_pos/v_pos)
// equal these same fixed values, so this is a no-op until the option is enabled.
assign VIDEO_ARX = NATIVE_VID_ACTIVE ? freak_arx : 13'd4;
assign VIDEO_ARY = NATIVE_VID_ACTIVE ? freak_ary : 13'd3;
assign VGA_SCALER= 0;
assign VGA_DISABLE = 0;

assign AUDIO_MIX = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;

assign LED_DISK = 0;
assign LED_POWER[1]= 1;
assign BUTTONS = 0;

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1; 
assign LED_USER    = FB ? led[0] : act_cnt[26]  ? act_cnt[25:18]  > act_cnt[7:0]  : act_cnt[25:18]  <= act_cnt[7:0];

wire [26:0] act_cnt2 = {~act_cnt[26],act_cnt[25:0]};
assign LED_POWER[0]= FB ? led[2] : act_cnt2[26] ? act_cnt2[25:18] > act_cnt2[7:0] : act_cnt2[25:18] <= act_cnt2[7:0];


`include "build_id.v" 
localparam CONF_STR = {
	"Solarus;;",
	"SC0,SOL,Load Quest;",
	"-;",
	"OCE,H Position (CRT),0,+1,+2,+3,-3,-2,-1;",
	"OFH,V Position (CRT),0,+1,+2,+3,-3,-2,-1;",
	"OI,Vertical Crop (224p),Disabled,Enabled;",
	"-;",
	"OK,FPS Overlay,Off,On;",
	"TJ,Restart Quest;",
	"-;",
	"J1,Sword,Action,Item 1,Item 2,Pause;",
	"jn,A,B,X,Y,Start;",
	"-;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire [31:0] status;
wire [31:0] joystick_0;
wire [31:0] joystick_1;
wire [31:0] joystick_2;
wire [31:0] joystick_3;
wire [15:0] joystick_l_analog_0;

// ioctl signals (still needed for core framework, but S0 doesn't stream)
wire        ioctl_download;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire [15:0] ioctl_index;
wire        ioctl_wait;
assign ioctl_wait = nv_ioctl_wait;

// SC0 mounted image — config file created instantly, no ioctl streaming.
// We only need the filename (from .s0 config). No disk I/O needed.
wire        img_mounted;
wire [63:0] img_size;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.forced_scandoubler(forced_scandoubler),
	.status(status),
	.status_menumask(cfg),
	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_2(joystick_2),
	.joystick_3(joystick_3),
	.joystick_l_analog_0(joystick_l_analog_0),
	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),
	// SC0 mount signals
	.img_mounted(img_mounted),
	.img_size(img_size),
	// Tie off disk I/O — we never read/write sectors
	.sd_lba('{32'd0}),
	.sd_rd(1'b0),
	.sd_wr(1'b0),
	.sd_buff_din('{8'd0})
);

////////////////////   CLOCKS   ///////////////////
wire locked, clk_sys;
wire clk_20m;   // PLL outclk_1 (unused, kept for future use)
wire clk_pix;   // PLL outclk_2: 53.693 MHz (CLK_VIDEO, /8 active — exact Genesis MCLK)
wire clk_sdram; // PLL outclk_3: 98.4375 MHz, phase-shifted SDRAM capture clock (#34 fallback C)
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_20m),
	.outclk_2(clk_pix),
	.outclk_3(clk_sdram),
	.locked(locked)
);

assign CLK_VIDEO = clk_pix;

// --- Native video control ---
wire NATIVE_VID = 1'b1;  // Always on -- this core exists for native video
assign NATIVE_VID_ACTIVE = NATIVE_VID;


/////////////////////   SDRAM   ///////////////////
//
// issue #19 — runtime-selectable blitter SOURCE controller on the SDRAM chip.
//
// The SDRAM_* pins were previously driven by the MiSTer-template `sdram sdr`
// RAM self-test (it wrote/read a pattern only to set the OSD `cfg` menu-mask
// bits — vestigial scaffolding, no role in Solarus video). That self-test is
// REPLACED here by the framebuffer/blitter SDRAM path (JT-T6: sdram_burst_arb
// over jtframe_burst_sdram), which owns the SDRAM_* pins. `cfg` is now a benign
// constant (0 = no menu masking; the cfg[15]-gated dummy DDR walker below stays
// inert, as it always was once the gate was satisfied — it touched only the
// legacy `addr/we` path used when NATIVE_VID is off).
//
// [collapse-single-source] The per-blit source read is ALWAYS from SDRAM now:
// blitter_top hardwires src_in_sdram=1 and the DDR3 live-source datapath was
// removed, so there is a SINGLE source pipeline (atlases staged DDR3->SDRAM, then
// read via P_SRC). The C_SRCSEL bit0 (DDR3-vs-SDRAM mux) is dead; the control word
// is still read by blitter_top for its throttle field (bits[15:8]).

wire [15:0] cfg = 16'd0;   // OSD menu-mask: 0 = show all (was SDRAM-presence probe)

// --- JC-T6: cache-ok SDRAM datapath nets (sdram_fb_cache, 3 channels) ------
// P_SRC (ch5, read-only): blitter source reads.
wire [26:0] src_p0_addr;
wire        src_p0_rd;
wire [63:0] src_p0_dout;
wire        src_p0_ok;
// P_DST (ch0, read/write): vram_demux SDRAM side (cache-ok: rd/wr/din/wdsn/dout/ok).
// [Phase 3b bg-plane bake] The write side (wr/addr/din/wdsn) is now a priority
// mux between vram_demux's vd_sd_* outputs and blitter_top's bgw_dst_* outputs
// (see the mux assigns below, near the blitter_top instantiation) -- both are
// the SOLE candidate drivers of ch0's write side and can never both want the
// bus in the same cycle in practice (vram_demux's FB0/FB1 writes are dead since
// FB-in-BRAM; the bake is a rare one-time event), so this is not a real
// arbitration, just a way to avoid a multi-driver net. dst_rd/dst_dout are
// read-only and stay vram_demux's alone (blitter_top's bake is write-only).
wire [26:0] dst_addr;
wire        dst_rd, dst_wr;
wire [63:0] dst_din;
wire  [7:0] dst_wdsn;
wire [63:0] dst_dout;
wire        dst_ok;
wire [26:0] vd_sd_addr;
wire        vd_sd_wr;
wire [63:0] vd_sd_din;
wire  [7:0] vd_sd_wdsn;
wire        bgw_active;
wire [26:0] bgw_dst_addr;
wire        bgw_dst_wr;
wire [63:0] bgw_dst_din;
wire  [7:0] bgw_dst_wdsn;
wire        bgw_dst_ok = dst_ok;   // shared ch0 ok, fanned out to both consumers unconditionally

bgw_ch0_mux u_bgw_ch0_mux (
	.bgw_active    (bgw_active),
	.bgw_dst_wr    (bgw_dst_wr),
	.bgw_dst_addr  (bgw_dst_addr),
	.bgw_dst_din   (bgw_dst_din),
	.bgw_dst_wdsn  (bgw_dst_wdsn),
	.vd_sd_wr      (vd_sd_wr),
	.vd_sd_addr    (vd_sd_addr),
	.vd_sd_din     (vd_sd_din),
	.vd_sd_wdsn    (vd_sd_wdsn),
	.dst_wr        (dst_wr),
	.dst_addr      (dst_addr),
	.dst_din       (dst_din),
	.dst_wdsn      (dst_wdsn)
);
// P_SCAN (ch4, read-only): scanout reader line fetch.
wire [26:0] scn_addr;
wire        scn_rd;
wire [63:0] scn_dout;
wire        scn_ok;
// vram_demux DDR side -> ddr_blitter_arb blt_*
wire [28:0] bd_addr;
wire        bd_rd, bd_wr;
wire [63:0] bd_din;
wire  [7:0] bd_be;
// vram_demux read-data back to the blitter mem_dout path
wire [63:0] blt_demux_dout;
wire        blt_demux_dready;
// clk_sys-domain vsync for the cache coherency flush (sequencer edge-detects the
// rising edge -> flush ch0 then invalidate ch0/4/5). nv_vs is clk_vid-domain, so
// double-flop it into clk_sys.
reg  [1:0]  fb_vs_sync = 2'b0;
always @(posedge clk_sys) fb_vs_sync <= {fb_vs_sync[0], nv_vs};
wire        fb_vs = fb_vs_sync[1];

// [#44] SDRAM source-STAGING write path: the blitter's BLT_OP_STAGE FSM copies atlas
// surfaces DDR3->SDRAM via these burst-write outputs into sdram_fb_cache ch1 (a
// dedicated write channel; P_SRC ch5 stays read-only). Previously these were left
// open -> staging wrote nothing -> C_SRCSEL=1 read un-staged SDRAM (noise).
wire [26:0] stage_waddr;
wire        stage_we_burst;
wire [63:0] stage_din64;
wire        stage_ok;
// Intra-frame STAGE->P_SRC coherency barrier: blitter pulses stage_barrier after a
// STAGE batch; fbcache commits ch1 + invalidates ch5 and holds stage_busy until done.
wire        stage_barrier;
wire        stage_busy;

// JC-T6: sdram_fb_cache (jtframe_cache_mux over jtframe_burst_sdram) replaces
// sdram_burst_arb. Three cache-ok channels — ch0 P_DST (r/w, vram_demux), ch4
// P_SCAN (ro, scanout reader), ch5 P_SRC (ro, blitter source) — plus a coherency
// sequencer that flushes ch0 then invalidates ch0/4/5 on each vsync. The wrapper
// instantiates jtframe_burst_sdram, the refresh timer, and the SDRAM_CLK altddio
// forwarder internally and drives the SDRAM_* pins directly (so the old external
// sdramclk_ddr forwarder is gone). dst/scan/p0 are single-qword cache-ok requests;
// vram_demux/reader/blitter each hold their request until ok.
// [residency/XL] SDRAM_AW=25 -> jtframe XL 128MB. cache_mux XL activates at SDRAM_AW==25
// (FULL channels widen to EW=27 = 128MB byte reach); sdram_fb_cache feeds burst_sdram
// AW=SDRAM_AW-1=24 (its XL convention). 2nd 64MB half on the primary bus, top addr bit =
// chip select. Requires the 128MB SDRAM module. Was AW=23 (64MB); AW=24 was a WRONG
// intermediate (burst-XL-on but cache-non-XL -> upper-half aliased).
// [XL A/B RESULT] MISTER=1 (DQM/A[12:11] short) was HW-tested (commit f5a3b68) — NULL:
// title/menus render but the overworld 2nd-die garbage is UNCHANGED, and it does not
// regress. So MISTER mode is NOT the cause. Reverted to MISTER=0 (validated for 64MB).
sdram_fb_cache #(.SDRAM_AW(25)) fbcache
(
	.clk        (clk_sys),
	.clk_sdram  (clk_sdram),        // [#44] phase-shiftable SDRAM output clock (general[3])
	.rst        (RESET),
	.init       (),                 // jtframe SDRAM-init flag (unused here)
	// P_DST (ch0, r/w) <- vram_demux SDRAM side
	.dst_addr   (dst_addr),
	.dst_rd     (dst_rd),
	.dst_wr     (dst_wr),
	.dst_din    (dst_din),
	.dst_wdsn   (dst_wdsn),
	.dst_dout   (dst_dout),
	.dst_ok     (dst_ok),
	// P_SCAN (ch4) DEAD [FB-in-BRAM]: scanout now reads comp_fbram (see u_fbram_scan).
	.scan_addr  (27'd0),
	.scan_rd    (1'b0),
	.scan_dout  (),
	.scan_ok    (),
	// P_SRC (ch5, ro) <- blitter source reads
	.p0_addr    (src_p0_addr),
	.p0_rd      (src_p0_rd),
	.p0_dout    (src_p0_dout),
	.p0_ok      (src_p0_ok),
	// STAGE (ch1, write-only) <- blitter BLT_OP_STAGE atlas DDR3->SDRAM writes (#44)
	.stage_addr (stage_waddr),
	.stage_wr   (stage_we_burst),
	.stage_din  (stage_din64),
	.stage_wdsn (8'h00),            // full-qword burst write
	.stage_ok   (stage_ok),
	// Coherency: vsync flushes ch0 (P_DST) + invalidates ch0/4/5; the intra-frame
	// stage barrier flushes ch1 (STAGE atlas) + invalidates ch5 (P_SRC).
	.vs            (fb_vs),
	.coh_busy      (),
	.stage_barrier (stage_barrier),
	.stage_busy    (stage_busy),
	// [retired] dst_barrier carry-forward coherency: ch0 (P_DST) is no longer written
	// (FB-in-BRAM), so the per-frame ch0->ch5 commit/invalidate is dead — tied off.
	.dst_barrier   (1'b0),
	.dst_busy      (),
	// SDRAM physical pins (incl. SDRAM_CLK forwarded internally)
	.sdram_dq   (SDRAM_DQ),
	.sdram_a    (SDRAM_A),
	.sdram_dqml (SDRAM_DQML),
	.sdram_dqmh (SDRAM_DQMH),
	.sdram_ba   (SDRAM_BA),
	.sdram_nwe  (SDRAM_nWE),
	.sdram_ncas (SDRAM_nCAS),
	.sdram_nras (SDRAM_nRAS),
	.sdram_ncs  (SDRAM_nCS),
	.sdram_cke  (SDRAM_CKE),
	.sdram_clk  (SDRAM_CLK)
);

// --- [FB-in-BRAM] on-chip framebuffer (comp_fbram) -------------------------
// The compositor's destination + the scanout source now live on-chip in M10K,
// not the SDRAM FB. blitter_top (comp_pipeline) writes the composite port; the
// scanout reader reads the 2nd (scan) port via fbram_scan_adapter. The SDRAM
// cache's P_DST (ch0) + P_SCAN (ch4) channels above are now DEAD (kept wired but
// idle this iteration; their deletion + the dst_barrier coherency removal is a
// follow-up cleanup). ch1 STAGE + ch5 P_SRC (atlas source) stay live.
wire        fb_wr_en;  wire [14:0] fb_wr_qw; wire [1:0] fb_wr_lane; wire [15:0] fb_wr_pix;
wire        fb_rd_en;  wire [14:0] fb_rd_qw; wire [63:0] fb_rd_qword;
wire        fb_scan_rd_en; wire [14:0] fb_scan_rd_qw; wire [63:0] fb_scan_rd_qword;
// [FB-in-BRAM double-buffer] vblank work->scan snapshot (blitter_top u_snap -> comp_fbram)
wire        fb_snap_we; wire [14:0] fb_snap_qw; wire [63:0] fb_snap_qword;

comp_fbram u_fbram (
	.clk        (clk_sys),
	.wr_en      (fb_wr_en),  .wr_qw(fb_wr_qw),  .wr_lane(fb_wr_lane), .wr_pix(fb_wr_pix),
	.rd_en      (fb_rd_en),  .rd_qw(fb_rd_qw),  .rd_qword(fb_rd_qword),
	.scan_rd_en (fb_scan_rd_en), .scan_rd_qw(fb_scan_rd_qw), .scan_rd_qword(fb_scan_rd_qword),
	.snap_we    (fb_snap_we), .snap_qw(fb_snap_qw), .snap_qword(fb_snap_qword)
);

// Bridge the scanout reader's P_SCAN cache-ok protocol -> comp_fbram's scan port.
fbram_scan_adapter u_fbram_scan (
	.clk        (clk_sys),
	.scn_addr   (scn_addr),
	.scn_rd     (scn_rd),
	.scn_dout   (scn_dout),
	.scn_ok     (scn_ok),
	.scan_rd_en (fb_scan_rd_en),
	.scan_rd_qw (fb_scan_rd_qw),
	.scan_rd_qword (fb_scan_rd_qword)
);

// --- DDR3 port sharing: old ddram (SDRAM clear) + native video reader ---
wire  [7:0] old_ddr_burstcnt;
wire [28:0] old_ddr_addr;
wire        old_ddr_rd;
wire [63:0] old_ddr_din;
wire  [7:0] old_ddr_be;
wire        old_ddr_we;

ddram ddr
(
	.DDRAM_CLK(clk_sys),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(old_ddr_burstcnt),
	.DDRAM_ADDR(old_ddr_addr),
	.DDRAM_DOUT(DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY & ~use_nv),
	.DDRAM_RD(old_ddr_rd),
	.DDRAM_DIN(old_ddr_din),
	.DDRAM_BE(old_ddr_be),
	.DDRAM_WE(old_ddr_we),
	.reset(RESET),
	.addr(addr),
	.dout(),
	.din(0),
	.we(we),
	.rd(0),
	.ready()
);

// Native video DDR3 signals
wire  [7:0] nv_ddr_burstcnt;
wire [28:0] nv_ddr_addr;
wire        nv_ddr_rd;
wire [63:0] nv_ddr_din;
wire  [7:0] nv_ddr_be;
wire        nv_ddr_we;
wire        nv_ioctl_wait;

// Native video reader always owns DDR3 when enabled
wire use_nv = NATIVE_VID;

// --- Blitter arbiter + blitter_top (fpga-hw-blitter #003 iteration 5) ---
// The hardware blitter (blitter_top) shares the single f2h port with the
// UNMODIFIED video reader via a 2-master priority arbiter (reader = default
// owner; blitter borrows idle gaps). blitter_top walks a command ring at
// 0x3A0E0000 (in the proven 1 MiB region), composites into the existing
// double-buffer, and writes the video control word as a drop-in producer.
// Set ENABLE=0 for a normal core (blitter inert, reader owns the bus).
wire  [7:0] arb_ddr_burstcnt;
wire [28:0] arb_ddr_addr;
wire        arb_ddr_rd;
wire [63:0] arb_ddr_din;
wire  [7:0] arb_ddr_be;
wire        arb_ddr_we;
wire        rdr_busy_w, rdr_grant_w;

// blitter master port
wire [31:0] blt_mem_addr;
wire        blt_mem_rd, blt_mem_wr;
wire [63:0] blt_mem_din;
wire  [7:0] blt_mem_be;
wire        blt_busy_w, blt_grant_w;
// busy from the DDR blitter arbiter into the demux DDR side (was blt_busy_w
// before the demux was inserted; demux now owns blt_busy_w toward the blitter)
wire        blt_arb_busy;

// comp_pipeline burst length on the blitter mem_* master. For FB (SDRAM) accesses
// vram_demux walks this many single-qword cache beats internally. For NON-FB DDR
// accesses (the command-ring reads and the BLT_OP_STAGE DDR3 atlas reads — the
// per-blit source read no longer hits DDR3) it must reach ddr_blitter_arb so the
// DDR burst returns the full beat count — otherwise a multi-beat DDR read returns
// one beat and comp_burst hangs in S_RDBEATS (the #1 wiring-review wedge).
wire [7:0]  blt_mem_burstcnt;

blitter_top blitter
(
	.clk            (clk_sys),
	.rst            (RESET),
	.mem_addr       (blt_mem_addr),
	.mem_rd         (blt_mem_rd),
	.mem_wr         (blt_mem_wr),
	.mem_din        (blt_mem_din),
	.mem_be         (blt_mem_be),
	.mem_burstcnt   (blt_mem_burstcnt),
	// mem read-data + busy now come from vram_demux (DDR or SDRAM per address)
	.mem_dout       (blt_demux_dout),
	.mem_dout_ready (blt_demux_dready),
	.mem_busy       (blt_busy_w),
	// SDRAM source path — now the SOLE source path (src_in_sdram hardwired 1).
	// P_SRC cache-ok source reads (JC-T5): p0_* is the per-blit source fetch.
	.p0_addr              (src_p0_addr),
	.p0_rd                (src_p0_rd),
	.p0_dout              (src_p0_dout),
	.p0_ok                (src_p0_ok),
	// [#44] STAGE (BLT_OP_STAGE) atlas DDR3->SDRAM burst writes -> cache ch1.
	// The single-word src_sdram_we/din path is unused (the FSM stages via the burst
	// variant); the burst outputs carry the staged beat + 8-byte-aligned dest addr.
	.src_sdram_we         (),
	.src_sdram_din        (),
	.src_sdram_waddr      (stage_waddr),
	.src_sdram_we_burst   (stage_we_burst),
	.src_sdram_din64      (stage_din64),
	.src_sdram_ok         (stage_ok),       // cache-ok: hold the burst write until accepted
	// intra-frame STAGE->P_SRC coherency barrier (commit ch1 + invalidate ch5)
	.stage_barrier        (stage_barrier),
	.stage_barrier_busy   (stage_busy),
	// (dst_barrier carry-forward coherency retired with FB-in-BRAM)
	// [Phase 3b bg-plane bake] ch0 (P_DST) write port -> the bgw_active priority
	// mux (see the dst_* wire declarations above), not straight to dst_*.
	.dst_wr         (bgw_dst_wr),
	.dst_addr       (bgw_dst_addr),
	.dst_din        (bgw_dst_din),
	.dst_wdsn       (bgw_dst_wdsn),
	.dst_ok         (bgw_dst_ok),
	.bgw_active     (bgw_active),
	// [FB-in-BRAM] composite destination -> on-chip comp_fbram (replaces the SDRAM FB)
	.fb_wr_en       (fb_wr_en),
	.fb_wr_qw       (fb_wr_qw),
	.fb_wr_lane     (fb_wr_lane),
	.fb_wr_pix      (fb_wr_pix),
	.fb_rd_en       (fb_rd_en),
	.fb_rd_qw       (fb_rd_qw),
	.fb_rd_qword    (fb_rd_qword),
	// [FB-in-BRAM double-buffer] vblank work->scan snapshot + the vblank trigger
	.vs             (fb_vs),
	.osd_restart    (osd_restart),
	.osd_fps_on     (osd_fps_on),
	.fb_snap_we     (fb_snap_we),
	.fb_snap_qw     (fb_snap_qw),
	.fb_snap_qword  (fb_snap_qword),
	.idle           (),
	.dbg            ()              // #34 debug probe stripped for shipping core
);

ddr_blitter_arb #(.ENABLE(1'b1)) blitter_arb
(
	.clk          (clk_sys),
	.reset        (RESET),
	.rdr_burstcnt (nv_ddr_burstcnt),
	.rdr_addr     (nv_ddr_addr),
	.rdr_rd       (nv_ddr_rd),
	.rdr_din      (nv_ddr_din),
	.rdr_be       (nv_ddr_be),
	.rdr_we       (nv_ddr_we),
	.rdr_busy     (rdr_busy_w),
	.rdr_grant    (rdr_grant_w),
	// blitter DDR side now comes from vram_demux (bd_*), not the raw mem_* bus
	.blt_burstcnt (blt_mem_burstcnt),  // #1 fix: real burst len (was 8'd1 -> multi-beat DDR read wedge)
	.blt_addr     (bd_addr),
	.blt_rd       (bd_rd),
	.blt_din      (bd_din),
	.blt_be       (bd_be),
	.blt_we       (bd_wr),
	.blt_busy     (blt_arb_busy),
	.blt_grant    (blt_grant_w),
	.ddram_busy       (DDRAM_BUSY),
	.ddram_dout_ready (DDRAM_DOUT_READY),
	.ddram_burstcnt   (arb_ddr_burstcnt),
	.ddram_addr       (arb_ddr_addr),
	.ddram_rd         (arb_ddr_rd),
	.ddram_din        (arb_ddr_din),
	.ddram_be         (arb_ddr_be),
	.ddram_we         (arb_ddr_we),
	.dbg              ()             // #34 debug probe stripped for shipping core
);

// --- Task 4: VRAM demux — route blitter mem_* by address -----------------
// FB0/FB1 region -> SDRAM (arbiter P_DST); everything else -> DDR (blitter_arb
// blt_* port).  blt_mem_addr is 32-bit qword-addressed; the demux uses [28:0].
vram_demux vdemux
(
	.clk            (clk_sys),
	.reset          (RESET),
	// blitter mem_* side
	.blt_addr       (blt_mem_addr),
	.blt_rd         (blt_mem_rd),
	.blt_wr         (blt_mem_wr),
	.blt_din        (blt_mem_din),
	.blt_be         (blt_mem_be),
	.blt_burstcnt   (blt_mem_burstcnt),
	.blt_dout       (blt_demux_dout),
	.blt_dout_ready (blt_demux_dready),
	.blt_busy       (blt_busy_w),
	// DDR side -> ddr_blitter_arb blt_* (bd_*)
	.ddr_addr       (bd_addr),
	.ddr_rd         (bd_rd),
	.ddr_wr         (bd_wr),
	.ddr_din        (bd_din),
	.ddr_be         (bd_be),
	.ddr_dout       (DDRAM_DOUT),
	.ddr_dout_ready (DDRAM_DOUT_READY & blt_grant_w),
	.ddr_busy       (blt_arb_busy),
	// SDRAM side -> arbiter P_DST (dst_*). Write-side (addr/wr/din/wdsn) goes
	// through the bgw_active priority mux above, not straight to dst_* -- see
	// the [Phase 3b bg-plane bake] note near the dst_* wire declarations.
	.sd_addr        (vd_sd_addr),
	.sd_rd          (dst_rd),
	.sd_wr          (vd_sd_wr),
	.sd_din         (vd_sd_din),
	.sd_wdsn        (vd_sd_wdsn),
	.sd_dout        (dst_dout),
	.sd_ok          (dst_ok),
	.dbg            ()             // #34 debug probe stripped for shipping core
);

// 2-way DDR3 mux: native video (via arbiter) > legacy
assign DDRAM_BURSTCNT = use_nv ? arb_ddr_burstcnt : old_ddr_burstcnt;
assign DDRAM_ADDR     = use_nv ? arb_ddr_addr     : old_ddr_addr;
assign DDRAM_RD       = use_nv ? arb_ddr_rd       : old_ddr_rd;
assign DDRAM_DIN      = use_nv ? arb_ddr_din      : old_ddr_din;
assign DDRAM_BE       = use_nv ? arb_ddr_be       : old_ddr_be;
assign DDRAM_WE       = use_nv ? arb_ddr_we       : old_ddr_we;

reg        we;
reg [28:0] addr = 0;

always @(posedge clk_sys) begin
	reg [4:0] cnt = 9;

	if(~RESET & cfg[15]) begin
		cnt <= cnt + 1'b1;
		we <= &cnt;
		if(cnt == 8) addr <= addr + 1'd1;
	end
end

////////////////////////////  MT32pi  ////////////////////////////////// 

//
// Pin | USB Name | Signal
// ----+----------+--------------
// 0   | D+       | I/O I2C_SDA / RX (midi in)
// 1   | D-       | O   TX (midi out)
// 2   | TX-      | I   I2S_WS (1 == right)
// 3   | GND_d    | I   I2C_SCL
// 4   | RX+      | I   I2S_BCLK
// 5   | RX-      | I   I2S_DAT
// 6   | TX+      | -   none
//

reg [15:0] mt32_i2s_r, mt32_i2s_l;
wire midi_rx;

// Native audio: DDR3 ring buffer populated by ARM via /dev/mem,
// drained by openbor_video_reader at 48 kHz. MT32pi I2S capture is
// preserved below for future MIDI support but no longer wired to
// AUDIO_L/R -- the FPGA now owns the audio path.
assign AUDIO_L = nv_audio_l;
assign AUDIO_R = nv_audio_r;
assign AUDIO_S = 1;

assign USER_OUT[0]   = 1;
assign USER_OUT[1]   = UART_RXD;
assign USER_OUT[6:2] = '1;
assign UART_TXD      = midi_rx;


//
// crossed/straight cable selection
//

generate
genvar i;
for(i = 0; i<2; i++) begin : clk_rate
	wire clk_in = i ? USER_IN[6] : USER_IN[4];
	reg [4:0] cnt;
	always @(posedge CLK_AUDIO) begin : clkr
		reg       clk_sr, clk, old_clk;
		reg [4:0] cnt_tmp;

		clk_sr <= clk_in;
		if (clk_sr == clk_in) clk <= clk_sr;

		if(~&cnt_tmp) cnt_tmp <= cnt_tmp + 1'd1;
		else cnt <= '1;

		old_clk <= clk;
		if(~old_clk & clk) begin
			cnt <= cnt_tmp;
			cnt_tmp <= 0;
		end
	end
end

reg crossed;
always @(posedge CLK_AUDIO) crossed <= (clk_rate[0].cnt <= clk_rate[1].cnt);
endgenerate

wire   i2s_ws   = crossed ? USER_IN[2] : USER_IN[5];
wire   i2s_data = crossed ? USER_IN[5] : USER_IN[2];
wire   i2s_bclk = crossed ? USER_IN[4] : USER_IN[6];
assign midi_rx  = crossed ? USER_IN[6] : USER_IN[4];

always @(posedge CLK_AUDIO) begin : i2s_proc
	reg [15:0] i2s_buf = 0;
	reg  [4:0] i2s_cnt = 0;
	reg        clk_sr;
	reg        i2s_clk = 0;
	reg        old_clk, old_ws;
	reg        i2s_next = 0;

	// Debounce clock
	clk_sr <= i2s_bclk;
	if (clk_sr == i2s_bclk) i2s_clk <= clk_sr;

	// Latch data and ws on rising edge
	old_clk <= i2s_clk;
	if (i2s_clk && ~old_clk) begin

		if (~i2s_cnt[4]) begin
			i2s_cnt <= i2s_cnt + 1'd1;
			i2s_buf[~i2s_cnt[3:0]] <= i2s_data;
		end

		// Word Select will change 1 clock before the new word starts
		old_ws <= i2s_ws;
		if (old_ws != i2s_ws) i2s_next <= 1;
	end

	if (i2s_next) begin
		i2s_next <= 0;
		i2s_cnt <= 0;
		i2s_buf <= 0;

		if (i2s_ws) mt32_i2s_l <= i2s_buf;
		else        mt32_i2s_r <= i2s_buf;
	end
	
	if (RESET) begin
		i2s_buf    <= 0;
		mt32_i2s_l <= 0;
		mt32_i2s_r <= 0;
	end
end

/////////////////////   VIDEO   ///////////////////

localparam lfsr_n = 63;

wire PAL = status[4];
wire FB  = status[5];
wire [2:0] led = status[8:6];
wire [2:0] h_pos = status[14:12];  // OSD H Position (CRT): 0..6 → 0,+1,+2,+3,-3,-2,-1
wire [2:0] v_pos = status[17:15];  // OSD V Position (CRT): 0..6 → 0,+1,+2,+3,-3,-2,-1
wire       crop_on     = status[18];  // OSD Vertical Crop (224p): 0=off, 1=on (Task 2: video_freak)
wire       osd_restart = status[19];  // OSD Restart Quest (momentary toggle); mirrored to ARM
                                       // via C_STATUS low32 bit0 (blitter_top S_WR_STATUS below)
wire       osd_fps_on  = status[20];  // OSD FPS Overlay: 0=off, 1=on; mirrored to ARM via
                                       // C_STATUS low32 bit1 (blitter_top S_WR_STATUS below)

// [320x224 crop] video_freak recomputes VGA_DE + VIDEO_ARX/ARY for a 224-line
// active window. CROP_SIZE=0 is video_freak's own "disabled" convention (the
// same pattern sonic-mania-mister uses: `status[32] ? 12'd216 : 12'd0`) — tying
// it to crop_on gates the whole feature with no separate enable port. CROP_OFF
// is tied to 0: video_freak's internal math centers the window symmetrically at
// offset 0 (8 lines blanked top and bottom of the 240-line frame -> 224 visible).
// SCALE is tied to 0 (Normal / no integer rescale) — non-goal per the design doc;
// the framework's ascal (fpga/sys/sys_top.v) does the final HDMI scale from
// whatever VIDEO_ARX/ARY this produces, same as it already does for h_pos/v_pos.
// HW-confirmed 2026-07-08: a drastic diagnostic crop (160 lines) was visibly
// obvious on real hardware, proving the video_freak/ascal auto-detect mechanism
// works end-to-end. 224 (a ~7% reduction) is subtle by comparison — a small
// zoom, not a letterbox — but is the correct, spec'd value.
wire [11:0] freak_crop_size = crop_on ? 12'd224 : 12'd0;
wire        vga_de_cropped;
wire [12:0] freak_arx, freak_ary;

video_freak video_freak
(
	.CLK_VIDEO    (CLK_VIDEO),
	.CE_PIXEL     (ce_pix_gen),
	.VGA_VS       (nv_vs),
	.HDMI_WIDTH   (HDMI_WIDTH),
	.HDMI_HEIGHT  (HDMI_HEIGHT),
	.VGA_DE       (vga_de_cropped),
	.VIDEO_ARX    (freak_arx),
	.VIDEO_ARY    (freak_ary),

	.VGA_DE_IN    (nv_de),
	.ARX          (12'd4),
	.ARY          (12'd3),
	.CROP_SIZE    (freak_crop_size),
	.CROP_OFF     (5'd0),
	.SCALE        (3'd0)
);

reg   [9:0] hc;
reg   [9:0] vc;
reg   [9:0] vvc;

reg  [lfsr_n:0] rnd_reg;
wire [lfsr_n:0] rnd;

wire  [5:0] rnd_c = {rnd_reg[0],rnd_reg[1],rnd_reg[2],rnd_reg[2],rnd_reg[2],rnd_reg[2]};

lfsr #(lfsr_n) random(rnd);

always @(posedge CLK_VIDEO) begin
	ce_pix <= ce_pix_gen;

	if(ce_pix) begin
		if(hc == 499) begin
			hc <= 0;
			if(vc == (PAL ? (forced_scandoubler ? 623 : 311) : (forced_scandoubler ? 523 : 261))) begin
				vc <= 0;
				vvc <= vvc + 9'd6;
			end else begin
				vc <= vc + 1'd1;
			end
		end else begin
			hc <= hc + 1'd1;
		end

		rnd_reg <= rnd;
	end
end

reg HBlank;
reg HSync;
reg VBlank;
reg VSync;

reg ce_pix;
always @(posedge CLK_VIDEO) begin
	if (hc == 384) HBlank <= 1;
		else if (hc == 0) HBlank <= 0;

	if (hc == 410) begin
		HSync <= 1;

		if(PAL) begin
			if(vc == (forced_scandoubler ? 609 : 280)) VSync <= 1;
				else if (vc == (forced_scandoubler ? 617 : 283)) VSync <= 0;

			if(vc == (forced_scandoubler ? 601 : 270)) VBlank <= 1;
				else if (vc == 0) VBlank <= 0;
		end
		else begin
			if(vc == (forced_scandoubler ? 490 : 224)) VSync <= 1;
				else if (vc == (forced_scandoubler ? 496 : 227)) VSync <= 0;

			if(vc == (forced_scandoubler ? 480 : 224)) VBlank <= 1;
				else if (vc == 0) VBlank <= 0;
		end
	end

	if (hc == 448) HSync <= 0;
end

reg  [7:0] cos_out;
wire [5:0] cos_g = cos_out[7:3]+6'd32;
cos cos(vvc + {vc>>forced_scandoubler, 2'b00}, cos_out);

wire [7:0] comp_v = (cos_g >= rnd_c) ? {cos_g - rnd_c, 2'b00} : 8'd0;

// --- Native video module ---
wire [7:0] nv_r, nv_g, nv_b;
wire       nv_hs, nv_vs, nv_de;
wire       nv_active;
wire [15:0] nv_audio_l, nv_audio_r;

openbor_video_top native_video
(
	.clk_sys        (clk_sys),
	.clk_vid        (CLK_VIDEO),
	.ce_pix         (ce_pix_gen),
	.reset          (RESET),

	// DDR3 interface (directly to mux)
	.ddr_busy       (use_nv ? rdr_busy_w : DDRAM_BUSY),
	.ddr_burstcnt   (nv_ddr_burstcnt),
	.ddr_addr       (nv_ddr_addr),
	.ddr_dout       (DDRAM_DOUT),
	.ddr_dout_ready (DDRAM_DOUT_READY & use_nv & rdr_grant_w),
	.ddr_rd         (nv_ddr_rd),
	.ddr_din        (nv_ddr_din),
	.ddr_be         (nv_ddr_be),
	.ddr_we         (nv_ddr_we),

	// SDRAM framebuffer read master (P_SCAN -> arbiter scan_*)
	.scan_addr      (scn_addr),
	.scan_rd        (scn_rd),
	.scan_dout      (scn_dout),
	.scan_ok        (scn_ok),

	// Video output
	.vga_r          (nv_r),
	.vga_g          (nv_g),
	.vga_b          (nv_b),
	.vga_hs         (nv_hs),
	.vga_vs         (nv_vs),
	.vga_de         (nv_de),

	// Control
	.enable         (use_nv),
	.active         (nv_active),
	.vsync_out      (),

	// CRT position adjustment
	.h_offset       (h_pos),
	.v_offset       (v_pos),

	// Joystick (from hps_io, written to DDR3 for ARM)
	.joystick_0     (joystick_0),
	.joystick_1     (joystick_1),
	.joystick_2     (joystick_2),
	.joystick_3     (joystick_3),
	.joystick_l_analog_0 (joystick_l_analog_0),

	// Cart loading
	.ioctl_download (ioctl_download),
	.ioctl_wr       (ioctl_wr),
	.ioctl_addr     (ioctl_addr),
	.ioctl_dout     (ioctl_dout),
	.ioctl_wait     (nv_ioctl_wait),

	// Native audio (DDR3 ring buffer -> AUDIO_L/R)
	.clk_audio      (CLK_AUDIO),
	.audio_l        (nv_audio_l),
	.audio_r        (nv_audio_r),
	.dbg_blt        (32'd0),        // #34 debug probe stripped for shipping core
	.dbg_addr       (32'd0),
	.dbg_diag       (32'd0)
);

// H/V position now handled inside timing module via FP/BP adjustment
assign VGA_DE  = NATIVE_VID_ACTIVE ? vga_de_cropped : ~(HBlank | VBlank);
assign VGA_HS  = NATIVE_VID_ACTIVE ? nv_hs    : HSync;
assign VGA_VS  = NATIVE_VID_ACTIVE ? nv_vs    : VSync;
assign VGA_R   = nv_active ? nv_r     : (NATIVE_VID_ACTIVE ? 8'd0 : comp_v);
assign VGA_G   = nv_active ? nv_g     : (NATIVE_VID_ACTIVE ? 8'd0 : comp_v);
assign VGA_B   = nv_active ? nv_b     : (NATIVE_VID_ACTIVE ? 8'd0 : comp_v);

endmodule
