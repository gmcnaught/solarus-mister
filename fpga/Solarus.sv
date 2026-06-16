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
// OpenBOR renders at 320x240. 4:3 aspect ratio.
assign VIDEO_ARX = 13'd4;
assign VIDEO_ARY = 13'd3;
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
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_20m),
	.outclk_2(clk_pix),
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
// REPLACED here by the blitter source path (sdram_src_arb -> sdram_psx), which
// owns the SDRAM_* pins. `cfg` is now a benign constant (0 = no menu masking;
// the cfg[15]-gated dummy DDR walker below stays inert, as it always was once
// the gate was satisfied — it touched only the legacy `addr/we` path used when
// NATIVE_VID is off).
//
// DEFAULT-SAFE: the blitter latches C_SRCSEL=0 by default, so it NEVER issues
// SDRAM source reads in the shipping config — sdram_psx only self-refreshes and
// no source pixel ever comes from SDRAM. The analog-clean DDR3 source path is
// bit-identical to before. Setting C_SRCSEL=1 (host control word) routes source
// reads through SDRAM; equivalence proven in sim (tb_blitter_system PHASE2).

wire [15:0] cfg = 16'd0;   // OSD menu-mask: 0 = show all (was SDRAM-presence probe)

// blitter source ports <-> arbiter (declared at the blitter instance below).
wire [26:0] bs_src_addr;
wire        bs_src_rd;
wire [63:0] bs_src_dout64;
wire        bs_src_dready;
wire        bs_src_busy;

// arbiter -> sdram_psx. c_busy = ~ready (the controller accepts a new line read
// only at a `ready` idle/line-complete point); c_ready = sdram_psx.ready.
wire [26:0] sps_c_addr;
wire        sps_c_rd;
wire        sps_c_we;
wire [15:0] sps_c_din;
wire        sps_ready;
wire        sps_dready;
wire [63:0] sps_dout64;
wire        sps_c_busy = ~sps_ready;

// blitter staging WRITE outputs (BLT_OP_STAGE DDR3->SDRAM copy, issue #19).
wire        bs_src_we;
wire [15:0] bs_src_din;
wire [26:0] bs_src_waddr;
// burst staging write (BL=4, fast bg-cache copy, issue #19).
wire        bs_src_we_burst;
wire [63:0] bs_src_din64;
wire        sps_c_we_burst;
wire [63:0] sps_c_din64;

sdram_src_arb src_arb
(
	.clk     (clk_sys),
	.reset   (RESET),
	.p0_addr (bs_src_addr),
	.p0_rd   (bs_src_rd),
	.p0_grant(),
	.p0_busy (bs_src_busy),
	.p0_we   (bs_src_we),
	.p0_din  (bs_src_din),
	.p0_waddr(bs_src_waddr),
	.p0_we_burst(bs_src_we_burst),
	.p0_din64   (bs_src_din64),
	.c_addr  (sps_c_addr),
	.c_rd    (sps_c_rd),
	.c_we    (sps_c_we),
	.c_din   (sps_c_din),
	.c_we_burst(sps_c_we_burst),
	.c_din64   (sps_c_din64),
	.c_ready (sps_ready),
	.c_busy  (sps_c_busy)
);
assign bs_src_dout64 = sps_dout64;
assign bs_src_dready  = sps_dready;

// BURST_BEATS=1: each blitter source read fetches ONE 64-bit beat (= one source
// qword = 4 RGB565 pixels), matching the DDR3 source qword the blitter caches.
sdram_psx #(.BURST_BEATS(1)) sps
(
	.*,                       // SDRAM_* pins
	.init    (~locked),
	.clk     (clk_sys),
	.wtbt    (2'b11),
	.addr    (sps_c_addr),
	.dout    (),
	.dout64  (sps_dout64),
	.dout_ready(sps_dready),
	.din     (sps_c_din),     // BLT_OP_STAGE staging write data (issue #19)
	.we      (sps_c_we),      // staging write request (idle/we=0 unless STAGE runs)
	.din64   (sps_c_din64),   // BL=4 burst staging write payload (issue #19)
	.we_burst(sps_c_we_burst),// burst staging write request
	.rd      (sps_c_rd),
	.ready   (sps_ready)
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

blitter_top blitter
(
	.clk            (clk_sys),
	.rst            (RESET),
	.mem_addr       (blt_mem_addr),
	.mem_rd         (blt_mem_rd),
	.mem_wr         (blt_mem_wr),
	.mem_din        (blt_mem_din),
	.mem_be         (blt_mem_be),
	.mem_dout       (DDRAM_DOUT),
	.mem_dout_ready (DDRAM_DOUT_READY & blt_grant_w),
	.mem_busy       (blt_busy_w),
	// issue #19 SDRAM source path (used only when C_SRCSEL=1; inert by default)
	.src_sdram_addr       (bs_src_addr),
	.src_sdram_rd         (bs_src_rd),
	.src_sdram_dout64     (bs_src_dout64),
	.src_sdram_dout_ready (bs_src_dready),
	.src_sdram_busy       (bs_src_busy),
	.src_sdram_we         (bs_src_we),
	.src_sdram_din        (bs_src_din),
	.src_sdram_waddr      (bs_src_waddr),
	.src_sdram_we_burst   (bs_src_we_burst),
	.src_sdram_din64      (bs_src_din64),
	.idle           ()
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
	.blt_addr     (blt_mem_addr[28:0]),
	.blt_rd       (blt_mem_rd),
	.blt_din      (blt_mem_din),
	.blt_be       (blt_mem_be),
	.blt_we       (blt_mem_wr),
	.blt_busy     (blt_busy_w),
	.blt_grant    (blt_grant_w),
	.ddram_busy       (DDRAM_BUSY),
	.ddram_dout_ready (DDRAM_DOUT_READY),
	.ddram_burstcnt   (arb_ddr_burstcnt),
	.ddram_addr       (arb_ddr_addr),
	.ddram_rd         (arb_ddr_rd),
	.ddram_din        (arb_ddr_din),
	.ddram_be         (arb_ddr_be),
	.ddram_we         (arb_ddr_we)
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
	.audio_r        (nv_audio_r)
);

// H/V position now handled inside timing module via FP/BP adjustment
assign VGA_DE  = NATIVE_VID_ACTIVE ? nv_de    : ~(HBlank | VBlank);
assign VGA_HS  = NATIVE_VID_ACTIVE ? nv_hs    : HSync;
assign VGA_VS  = NATIVE_VID_ACTIVE ? nv_vs    : VSync;
assign VGA_R   = nv_active ? nv_r     : (NATIVE_VID_ACTIVE ? 8'd0 : comp_v);
assign VGA_G   = nv_active ? nv_g     : (NATIVE_VID_ACTIVE ? 8'd0 : comp_v);
assign VGA_B   = nv_active ? nv_b     : (NATIVE_VID_ACTIVE ? 8'd0 : comp_v);

endmodule
