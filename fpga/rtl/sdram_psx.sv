//
// sdram.v
//
// Static RAM controller implementation using SDRAM MT48LC16M16A2
//
// Copyright (c) 2015,2016 Sorgelig
//
// Some parts of SDRAM code used from project:
// http://hamsterworks.co.nz/mediawiki/index.php/Simple_SDRAM_Controller
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
// ------------------------------------------
//
// v2.1 - Add universal 8/16 bit mode.
// v3.0 - Solarus blitter: BURST-4 reads + column-low address mapping.
//        A 64-bit "beat" (4 consecutive 16-bit words) is fetched with ONE
//        ACTIVE+READ(auto-precharge) instead of 4 separate single-access reads.
//        REQUIRES the conventional address map (columns = low byte-address bits)
//        so the 4 words of a beat share a row and 4 consecutive columns:
//            column[8:0] = addr[9:1]   (beat words = col, col+1, col+2, col+3)
//            bank[1:0]   = addr[11:10]
//            row[12:0]   = addr[24:12]
//        (The old v2.1 map put row = addr[13:1], i.e. low bits, scattering a
//         beat's 4 words across 4 different rows — which FORCED 4 single reads
//         and blocked bursting; see fpga/docs/sdram-second-bus.md.)
//        Reads return `dout64` (the assembled beat) with a single `ready` pulse.
//        Writes stay SINGLE-access (NO_WRITE_BURST=1) and use the same map, so
//        read/write data stay coherent. `dout` (16-bit) carries word0 for any
//        legacy single-word consumer.
//

module sdram_psx
#(
   parameter BURST_BEATS = 2      // number of 64-bit beats assembled per line read
                                  // (2 = 128-bit line). 1 = legacy single-beat read.
)
(
   input             init,        // reset to initialize RAM
   input             clk,         // clock ~100MHz
                                  //
                                  // SDRAM_* - signals to the MT48LC16M16 chip
   inout      [15:0] SDRAM_DQ,    // 16 bit bidirectional data bus
   output reg [12:0] SDRAM_A,     // 13 bit multiplexed address bus
   output            SDRAM_DQML,  // two byte masks
   output            SDRAM_DQMH,  //
   output reg  [1:0] SDRAM_BA,    // two banks
   output            SDRAM_nCS,   // a single chip select
   output            SDRAM_nWE,   // write enable
   output            SDRAM_nRAS,  // row address select
   output            SDRAM_nCAS,  // columns address select
   output            SDRAM_CLK,
   output            SDRAM_CKE,   // clock enable
                                  //
   input       [1:0] wtbt,        // 16bit mode:  bit1 - write high byte, bit0 - write low byte,
                                  // 8bit mode:  2'b00 - use addr[0] to decide which byte to write
                                  // Ignored while reading.
                                  //
   input      [26:0] addr,        // 27 bit address for 8bit mode. addr[0] = 0 for 16bit mode for correct operations.
   output     [15:0] dout,        // word0 of the last read (legacy single-word view)
   output reg [63:0] dout64,      // assembled 64-bit beat of the last (burst) read
   output reg        dout_ready,  // pulses once per assembled 64-bit beat
   input      [15:0] din,         // data input from cpu
   input             we,          // cpu requests write (single 16-bit word)
   input             rd,          // cpu requests read (one 64-bit beat = 4 words)
   output reg        ready        // dout/dout64 valid. Ready to accept new read/write.
);

// BURST-4 reads (one READ -> 4 sequential words); writes stay single-access.
localparam BURST_LENGTH        = 3'b010;   // 000=1, 001=2, 010=4, 011=8  -> 4-word read burst
localparam ACCESS_TYPE         = 1'b0;     // 0=sequential, 1=interleaved
localparam CAS_LATENCY         = 3'd2;     // 2 for < 100MHz, 3 for >100MHz
localparam OP_MODE             = 2'b00;    // only 00 (standard operation) allowed
localparam NO_WRITE_BURST      = 1'b1;     // 0= write burst enabled, 1=only single access write
localparam MODE                = {3'b000, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

localparam sdram_startup_cycles= 14'd12100;// 100us, plus a little more, @ 100MHz
localparam cycles_per_refresh  = 14'd780;  // (64000*100)/8192-1 Calc'd as (64ms @ 100MHz)/8192 rose
localparam startup_refresh_max = 14'b11111111111111;

// SDRAM commands
localparam CMD_NOP             = 3'b111;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

reg [13:0] refresh_count = startup_refresh_max - sdram_startup_cycles;
reg  [2:0] command = CMD_NOP;
reg [26:0] save_addr;
reg        chip = 0;

reg [15:0] data;

// burst-read capture: 4 consecutive words land starting CAS_LATENCY cycles after
// CMD_READ. data_ready_delay[0] marks word0; burst_cap streams words 1..3.
reg        burst_cap;
reg  [1:0] cap_idx;

// line assembly: a line is BURST_BEATS 64-bit beats fetched as back-to-back
// BL=4 reads after ONE ACTIVE (page-open reuse, no re-ACTIVE between beats).
reg  [3:0] beat_idx;       // 64-bit beats assembled so far
reg  [3:0] reads_issued;   // CMD_READ commands issued for the current line

// registered tristate DQ output (driven only during the WRITE data cycle)
reg [15:0] dq_r;
reg        dq_oe;

assign SDRAM_nCS  = chip;
assign SDRAM_nRAS = command[2];
assign SDRAM_nCAS = command[1];
assign SDRAM_nWE  = command[0];
assign SDRAM_CKE  = 1;
assign {SDRAM_DQMH,SDRAM_DQML} = SDRAM_A[12:11];

// Tristate DQ driver (portable idiom; synthesizes to the same IO buffer as the
// old `inout reg` + procedural Z assignment, but is also iverilog-simulatable).
assign SDRAM_DQ = dq_oe ? dq_r : 16'bZ;

assign dout       = save_addr[0] ? {data[7:0],     data[15:8]}     : {data[15:8],     data[7:0]};

typedef enum
{
	STATE_STARTUP,
	STATE_OPEN_1, STATE_OPEN_2,
	STATE_WRITE,
	STATE_READ, STATE_READ_WAIT,
	STATE_RFSH,
	STATE_IDLE,	  STATE_IDLE_1, STATE_IDLE_2, STATE_IDLE_3,
	STATE_IDLE_4, STATE_IDLE_5, STATE_IDLE_6, STATE_IDLE_7
} state_t;

always @(posedge clk) begin
	reg old_we, old_rd;
	reg [CAS_LATENCY:0] data_ready_delay;

	reg [15:0] new_data;
	reg  [1:0] new_wtbt;
	reg        new_we;
	reg        new_rd;
	reg        save_we = 1;
	reg        beat_done;

	state_t state = STATE_STARTUP;

	dq_oe <= 1'b0;            // release DQ unless a WRITE drives it this cycle
	command <= CMD_NOP;
	refresh_count  <= refresh_count+1'b1;
	dout_ready <= 1'b0;      // single-cycle per-beat strobe

	data_ready_delay <= {1'b0, data_ready_delay[CAS_LATENCY:1]};

	beat_done = 1'b0;        // pulses (combinationally, this cycle) when a beat completes

	// ---- burst-read data capture (independent of the command FSM) -------------
	// word0 arrives when data_ready_delay[0] pulses (the proven CL timing); the
	// next 3 words stream on the following consecutive clocks (BL=4 sequential).
	// Each beat is captured one-at-a-time (beats are fetched as SEQUENTIAL BL=4
	// reads within one open row, so no two captures overlap).
	if (burst_cap) begin
		dout64[cap_idx*16 +: 16] <= SDRAM_DQ;
		data                     <= SDRAM_DQ;     // keep `dout` tracking the latest word
		if (cap_idx == 2'd3) begin
			burst_cap  <= 1'b0;
			dout_ready <= 1'b1;                    // this 64-bit beat is valid
			beat_idx   <= beat_idx + 4'd1;
			beat_done   = 1'b1;
			// line complete only after the LAST beat
			if (beat_idx + 4'd1 == BURST_BEATS) ready <= 1'b1;
		end else cap_idx <= cap_idx + 2'd1;
	end else if (data_ready_delay[0]) begin
		dout64[15:0] <= SDRAM_DQ;                  // word0
		data         <= SDRAM_DQ;
		cap_idx      <= 2'd1;
		burst_cap    <= 1'b1;
	end

	case(state)
		STATE_STARTUP: begin
			//------------------------------------------------------------------------
			//-- This is the initial startup state, where we wait for at least 100us
			//-- before starting the start sequence
			//--
			//-- The initialisation is sequence is
			//--  * de-assert SDRAM_CKE
			//--  * 100us wait,
			//--  * assert SDRAM_CKE
			//--  * wait at least one cycle,
			//--  * PRECHARGE
			//--  * wait 2 cycles
			//--  * REFRESH,
			//--  * tREF wait
			//--  * REFRESH,
			//--  * tREF wait
			//--  * LOAD_MODE_REG
			//--  * 2 cycles wait
			//------------------------------------------------------------------------
			SDRAM_A    <= 0;
			SDRAM_BA   <= 0;

			if (refresh_count == (startup_refresh_max-64)) chip <= 1;
			if (refresh_count == (startup_refresh_max-32)) chip <= 0;

			// All the commands during the startup are NOPS, except these
			if (refresh_count == startup_refresh_max-63 || refresh_count == startup_refresh_max-31) begin
				// ensure all rows are closed
				command     <= CMD_PRECHARGE;
				SDRAM_A[10] <= 1;  // all banks
			end
			if (refresh_count == startup_refresh_max-55 || refresh_count == startup_refresh_max-23) begin
				// these refreshes need to be at least tREF (66ns) apart
				command     <= CMD_AUTO_REFRESH;
			end
			if (refresh_count == startup_refresh_max-47 || refresh_count == startup_refresh_max-15) begin
				command     <= CMD_AUTO_REFRESH;
			end
			if (refresh_count == startup_refresh_max-39 || refresh_count == startup_refresh_max-7) begin
				// Now load the mode register
				command     <= CMD_LOAD_MODE;
				SDRAM_A     <= MODE;
			end

			ready <= 0;

			//------------------------------------------------------
			//-- if startup is complete then go into idle mode,
			//-- get prepared to accept a new command, and schedule
			//-- the first refresh cycle
			//------------------------------------------------------
			if(!refresh_count) begin
				state   <= STATE_IDLE;
				ready   <= 1;
				refresh_count <= 0;
			end
		end

		STATE_IDLE_7: state <= STATE_IDLE_6;
		STATE_IDLE_6: state <= STATE_IDLE_5;
		STATE_IDLE_5: state <= STATE_IDLE_4;
		STATE_IDLE_4: state <= STATE_IDLE_3;
		STATE_IDLE_3: state <= STATE_IDLE_2;
		STATE_IDLE_2: state <= STATE_IDLE_1;
		STATE_IDLE_1: begin
			state      <= STATE_IDLE;
			// mask possible refresh to reduce colliding.
			if(refresh_count > cycles_per_refresh) begin
            //------------------------------------------------------------------------
            //-- Start the refresh cycle.
            //-- This tasks tRFC (66ns), so 6 idle cycles are needed @ 100MHz
            //------------------------------------------------------------------------
				chip     <= 1;
				state    <= STATE_RFSH;
				command  <= CMD_AUTO_REFRESH;
				refresh_count <= refresh_count - cycles_per_refresh + 1'd1;
			end
		end

		STATE_RFSH: begin
			chip     <= 0;
			state    <= STATE_IDLE_7;
			command  <= CMD_AUTO_REFRESH;
			refresh_count <= refresh_count - cycles_per_refresh + 1'd1;
		end

		STATE_IDLE: begin
			// Priority is to issue a refresh if one is outstanding
			if(refresh_count > (cycles_per_refresh<<1)) state <= STATE_IDLE_1;
			else if(new_rd | new_we) begin
				new_rd      <= 0;
				new_we      <= 0;
				save_we     <= new_we;
				save_addr   <= addr;
				beat_idx     <= 4'd0;
				reads_issued <= 4'd0;
				state       <= STATE_OPEN_1;
				command     <= CMD_ACTIVE;
				// column-low map: row = addr[24:12], bank = addr[11:10]
				SDRAM_A     <= addr[24:12];
				SDRAM_BA    <= addr[11:10];
				chip        <= addr[26];
			end
		end

		// ACTIVE-to-READ or WRITE delay >20ns (-75)
		STATE_OPEN_1: begin
			SDRAM_A     <= '1;
			state       <= STATE_OPEN_2;
		end
		STATE_OPEN_2: begin
			// A[12:11]=DQM (00 on read, byte-mask on write), A[9]=0 (unused, 9-col
			// chip), A[8:0]=column=save_addr[9:1].
			// A[10]=auto-precharge: on a WRITE always 1 (single-access). On a READ
			// only when this first beat is also the LAST (BURST_BEATS==1) — otherwise
			// keep the row OPEN to fetch the remaining beats (page-open reuse).
			SDRAM_A     <= {save_we & (new_wtbt ? ~new_wtbt[1] : ~save_addr[0]),
			                save_we & (new_wtbt ? ~new_wtbt[0] :  save_addr[0]),
			                save_we | (BURST_BEATS == 1), 1'b0, save_addr[9:1]};
			if (save_we) state <= STATE_WRITE;
			else         state <= STATE_READ;
		end

		STATE_READ: begin
			// one READ -> BL=4 words stream back CAS_LATENCY cycles later (captured
			// by the burst-capture block above). The column for this beat was set
			// in STATE_OPEN_2 (beat 0) or STATE_READ_WAIT (beats 1..N-1).
			command      <= CMD_READ;
			data_ready_delay[CAS_LATENCY] <= 1;
			reads_issued <= reads_issued + 4'd1;
			state        <= STATE_READ_WAIT;
		end

		// Wait for the in-flight beat to be fully captured (beat_done), then either
		// issue the next BL=4 read at the next 4-word column within the SAME open
		// row (page-open reuse, no re-ACTIVE), or finish the line. IDLE_7 gives
		// burst(4) + tRP slack before the next ACTIVE.
		STATE_READ_WAIT: begin
			if (beat_done) begin
				if (reads_issued < BURST_BEATS) begin
					// advance column by 4 words (one BL=4 group) for the next beat.
					// reads_issued already counts the issued reads, so the next beat's
					// column = base_col + reads_issued*4. A[10] (auto-precharge) is set
					// ONLY on the LAST read of the line (reads_issued == BURST_BEATS-1)
					// to close the row; earlier reads keep it open (page-open reuse).
					SDRAM_A <= {2'b00, (reads_issued == BURST_BEATS-1), 1'b0,
					            save_addr[9:1] + {reads_issued, 2'b00}};
					state   <= STATE_READ;
				end else begin
					state   <= STATE_IDLE_7;
				end
			end
		end

		STATE_WRITE: begin
			state       <= STATE_IDLE_5;
			command     <= CMD_WRITE;
			dq_r        <= new_wtbt ? new_data : {new_data[7:0], new_data[7:0]};
			dq_oe       <= 1'b1;
			ready       <= 1;
		end
	endcase

	if(init) begin
		state <= STATE_STARTUP;
		refresh_count <= startup_refresh_max - sdram_startup_cycles;
		burst_cap <= 1'b0;
		dout_ready <= 1'b0;
		beat_idx <= 4'd0;
		reads_issued <= 4'd0;
	end

	old_we <= we;
	if(we & ~old_we) {ready, new_we, new_data, new_wtbt} <= {1'b0, 1'b1, din, wtbt};

	old_rd <= rd;
	if(rd & ~old_rd) {ready, new_rd} <= {1'b0, 1'b1};
end

altddio_out
#(
	.extend_oe_disable("OFF"),
	.intended_device_family("Cyclone V"),
	.invert_output("OFF"),
	.lpm_hint("UNUSED"),
	.lpm_type("altddio_out"),
	.oe_reg("UNREGISTERED"),
	.power_up_high("OFF"),
	.width(1)
)
sdramclk_ddr
(
	.datain_h(1'b0),
	.datain_l(1'b1),
	.outclock(clk),
	.dataout(SDRAM_CLK),
	.aclr(1'b0),
	.aset(1'b0),
	.oe(1'b1),
	.outclocken(1'b1),
	.sclr(1'b0),
	.sset(1'b0)
);

endmodule
