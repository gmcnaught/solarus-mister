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
//            column[9:0] = addr[10:1]   (beat words = col, col+1, col+2, col+3)
//            bank[1:0]   = addr[12:11]
//            row[12:0]   = addr[25:13]   (AS4C32M16, 512Mbit/64MB, 10-bit column)
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
   output reg [63:0] dout64,      // the CURRENT 64-bit beat; valid on dout_ready.
                                  // Holds only ONE beat at a time (overwritten each
                                  // beat) — capture every beat on the dout_ready strobe.
   output reg        dout_ready,  // pulses once per assembled 64-bit beat
   input      [15:0] din,         // data input from cpu (single 16-bit word write)
   input      [63:0] din64,       // data input for a BL=4 BURST write (4 words; word0=[15:0])
   input             we,          // cpu requests write (single 16-bit word)
   input             we_burst,    // cpu requests a 4-word BURST write (din64), issue #19
   input             rd,          // cpu requests read (a BURST_BEATS-beat line)
   output reg        ready        // LINE complete (all BURST_BEATS beats delivered) /
                                  // ready for next request. NOTE: dout64 holds only the
                                  // LAST beat here — each beat must be taken on dout_ready.
);

// BURST-4 reads (one READ -> 4 sequential words); writes stay single-access.
localparam BURST_LENGTH        = 3'b010;   // 000=1, 001=2, 010=4, 011=8  -> 4-word read burst
localparam ACCESS_TYPE         = 1'b0;     // 0=sequential, 1=interleaved
localparam CAS_LATENCY         = 3'd2;     // 2 for < 100MHz, 3 for >100MHz
localparam OP_MODE             = 2'b00;    // only 00 (standard operation) allowed
// issue #19: enable BL=4 WRITE bursts (fast DDR3->SDRAM staging copy). With
// NO_WRITE_BURST=0 a WRITE drives data on consecutive clocks (BL words). The
// SINGLE-access write path still works because the controller masks the 3
// trailing burst words with DQM=11 (STATE_WRITE_M1..M3), so only word0 lands.
localparam NO_WRITE_BURST      = 1'b0;     // 0= write burst enabled, 1=only single access write
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

// ---- STARTUP decode pipeline (timing) -----------------------------------
// The startup sequence is driven by a cloud of 14-bit equality comparators on
// refresh_count (refresh_count == startup_refresh_max-N). Quartus flagged the
// path refresh_count -> (comparators) -> SDRAM_A mux as the worst-case setup
// path. To shorten it we pipeline the decode by ONE cycle: each comparator
// result is captured into a registered one-shot flag (cycle k), and the
// command/chip/SDRAM_A outputs are driven from those flags the NEXT cycle
// (k+1). This splits refresh_count->comparator->SDRAM_A into
// refresh_count->comparator->reg  and  reg->SDRAM_A (two short paths).
//
// EQUIVALENCE: every flag compares against (original_constant - 1). Because
// refresh_count counts UP by 1 every cycle, (constant-1) matches one cycle
// EARLIER than the original constant did; the flag's one cycle of register
// latency then re-delays the driven output by exactly one cycle, so each
// output register lands the SAME value on the SAME clock edge as before
// (net shift = -1 + 1 = 0). The whole startup command
// sequence (PRECHARGE/AUTO_REFRESH/LOAD_MODE), its tREF/tRP spacing, the
// SDRAM_A=MODE / SDRAM_A[10] values, and the chip-select toggles are bit- and
// cycle-identical to the original. The startup events are >=8 cycles apart and
// there is >7 cycles of slack before the first event (count starts ~12k cycles
// before) and after the last event (the !refresh_count completion), so a 1-cycle
// pipeline never collides with the STARTUP entry/exit.
reg        su_chip1 = 0;   // chip <= 1   (was at refresh_count == max-64)
reg        su_chip0 = 0;   // chip <= 0   (was at refresh_count == max-32)
reg        su_pre   = 0;   // PRECHARGE + SDRAM_A[10]=1 (was max-63 / max-31)
reg        su_ref   = 0;   // AUTO_REFRESH            (was max-55/-47 / max-23/-15)
reg        su_mode  = 0;   // LOAD_MODE + SDRAM_A=MODE (was max-39 / max-7)

reg [15:0] data;

// #34: registered SDRAM_DQ INPUT stage. The burst capture used to read SDRAM_DQ
// straight into dout64[cap_idx*16+:16] — a 1->4 demux that CANNOT pack into the
// I/O input register, so the captured flop sat deep in fabric with ~5.2 ns of
// pin->flop routing (the binding setup path once SDRAM I/O was finally
// constrained; STA had been blind to it). dq_in is a plain 1:1 capture of the DQ
// bus (FAST_INPUT_REGISTER-packable, ~0 routing). Everything downstream reads
// dq_in instead of SDRAM_DQ and the capture trigger is delayed one cycle (dr0_q)
// so the SAME word lands — identical data, +1 cycle latency, but the pin->flop
// hop now meets timing in the I/O cell.
reg [15:0] dq_in;
reg        dr0_q;     // data_ready_delay[0] delayed 1 cyc to match dq_in's delay

// burst-read capture: 4 consecutive words land starting CAS_LATENCY cycles after
// CMD_READ. data_ready_delay[0] marks word0; burst_cap streams words 1..3.
reg        burst_cap;
reg  [1:0] cap_idx;

// line assembly: a line is BURST_BEATS 64-bit beats fetched as back-to-back
// BL=4 reads after ONE ACTIVE (page-open reuse, no re-ACTIVE between beats).
reg  [3:0] beat_idx;       // 64-bit beats assembled so far (BURST_BEATS must be <= 15)
reg  [3:0] reads_issued;   // CMD_READ commands issued for the current line

// ---- page-wrap (row-cross) support --------------------------------------
// A line normally fits in ONE open row (col groups col0, col0+4, ...). If the
// line runs off the end of a row (9-bit column would overflow 511), it must
// PRECHARGE the current row and ACTIVE the NEXT row (row+1, same bank),
// continuing the SAME line from column 0 of the new row.
//   cur_row / cur_bank : the row/bank currently OPEN (re-ACTIVEd on a cross).
//   col_base           : the column origin of the current row's first beat
//                        (= save_addr[9:1] for the first row, 0 after a cross).
//   reads_in_row       : BL=4 reads issued SINCE the current row was opened
//                        (column of the next beat = col_base + reads_in_row*4).
reg [12:0] cur_row;
reg  [1:0] cur_bank;
reg  [9:0] col_base;          // column origin of current row's first beat (10-bit, AS4C32M16)
reg  [3:0] reads_in_row;

// registered tristate DQ output (driven only during the WRITE data cycle)
reg [15:0] dq_r;
reg        dq_oe;

// ---- BL=4 burst-write payload (issue #19) -------------------------------
// A burst-write request latches the whole 64-bit beat here; the 4 words are
// clocked out word0..word3 on consecutive cycles (word0 with the WRITE command
// in STATE_WRITE, words 1..3 in STATE_WB_W1..3). save_burst marks the active
// request as a burst write (vs a single-word write) so STATE_WRITE branches.
reg [63:0] wb_data;
reg        save_burst = 0;

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
	STATE_WRITE_M1, STATE_WRITE_M2, STATE_WRITE_M3,   // single-write: mask trailing BL words
	STATE_WB_W1, STATE_WB_W2, STATE_WB_W3,            // BL=4 burst-write trailing data cycles
	STATE_READ, STATE_READ_WAIT,
	STATE_XROW_PRE, STATE_XROW_PRE_W, STATE_XROW_ACT, STATE_XROW_ACT_W,
	STATE_RFSH,
	STATE_IDLE,	  STATE_IDLE_1, STATE_IDLE_2, STATE_IDLE_3,
	STATE_IDLE_4, STATE_IDLE_5, STATE_IDLE_6, STATE_IDLE_7
} state_t;

always @(posedge clk) begin : fsm
	reg old_we, old_we_b, old_rd;
	reg [CAS_LATENCY:0] data_ready_delay;

	reg [15:0] new_data;
	reg  [1:0] new_wtbt;
	reg        new_we;
	reg        new_burst;     // pending request is a BL=4 burst write (din64)
	reg        new_rd;
	reg        save_we = 1;
	reg        beat_done;
	reg [10:0] next_col_full;   // 11-bit next-beat column; bit[10] = page wrap (1024 cols)

	state_t state = STATE_STARTUP;

	dq_oe <= 1'b0;            // release DQ unless a WRITE drives it this cycle
	command <= CMD_NOP;
	refresh_count  <= refresh_count+1'b1;
	dout_ready <= 1'b0;      // single-cycle per-beat strobe

	data_ready_delay <= {1'b0, data_ready_delay[CAS_LATENCY:1]};

	// #34: registered DQ input + matched 1-cycle delay of the capture trigger.
	dq_in <= SDRAM_DQ;
	dr0_q <= data_ready_delay[0];

	// ---- STARTUP decode pipeline stage 1: registered one-shot flags ----------
	// Compare against (original_constant - 1) so each flag asserts one cycle
	// early; the flag's own register latency then re-aligns the driven output to
	// the SAME edge as the original direct decode (see declaration comment).
	// These run every cycle but are harmless outside STARTUP: post-init
	// refresh_count stays small (< ~2*cycles_per_refresh), never reaching these
	// near-max constants, so the flags are always 0 once startup has completed.
	su_chip1 <= (refresh_count == (startup_refresh_max-14'd65));
	su_chip0 <= (refresh_count == (startup_refresh_max-14'd33));
	su_pre   <= (refresh_count == (startup_refresh_max-14'd64)) || (refresh_count == (startup_refresh_max-14'd32));
	su_ref   <= (refresh_count == (startup_refresh_max-14'd56)) || (refresh_count == (startup_refresh_max-14'd24))
	         || (refresh_count == (startup_refresh_max-14'd48)) || (refresh_count == (startup_refresh_max-14'd16));
	su_mode  <= (refresh_count == (startup_refresh_max-14'd40)) || (refresh_count == (startup_refresh_max-14'd8));

	beat_done = 1'b0;        // pulses (combinationally, this cycle) when a beat completes

	// ---- burst-read data capture (independent of the command FSM) -------------
	// word0 arrives when data_ready_delay[0] pulses (the proven CL timing); the
	// next 3 words stream on the following consecutive clocks (BL=4 sequential).
	// Each beat is captured one-at-a-time (beats are fetched as SEQUENTIAL BL=4
	// reads within one open row, so no two captures overlap).
	if (burst_cap) begin
		dout64[cap_idx*16 +: 16] <= dq_in;
		data                     <= dq_in;        // keep `dout` tracking the latest word
		if (cap_idx == 2'd3) begin
			burst_cap  <= 1'b0;
			dout_ready <= 1'b1;                    // this 64-bit beat is valid
			beat_idx   <= beat_idx + 4'd1;
			beat_done   = 1'b1;
			// line complete only after the LAST beat
			if (beat_idx + 4'd1 == BURST_BEATS) ready <= 1'b1;
		end else cap_idx <= cap_idx + 2'd1;
	end else if (dr0_q) begin
		dout64[15:0] <= dq_in;                     // word0
		data         <= dq_in;
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

			// ---- STARTUP decode pipeline stage 2: drive outputs from flags -----
			// Each flag was set one cycle ago by the (constant+1) comparator, so
			// these assignments land on the exact same edge / with the exact same
			// values as the original direct comparator decode (see above).
			if (su_chip1) chip <= 1;
			if (su_chip0) chip <= 0;

			// All the commands during the startup are NOPS, except these
			if (su_pre) begin
				// ensure all rows are closed
				command     <= CMD_PRECHARGE;
				SDRAM_A[10] <= 1;  // all banks
			end
			if (su_ref) begin
				// these refreshes need to be at least tREF (66ns) apart
				command     <= CMD_AUTO_REFRESH;
			end
			if (su_mode) begin
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
				new_burst   <= 0;
				save_we     <= new_we;
				save_burst  <= new_burst;   // routes STATE_WRITE to the BL=4 burst path
				save_addr   <= addr;
				beat_idx     <= 4'd0;
				reads_issued <= 4'd0;
				reads_in_row <= 4'd0;
				// track the currently-open row/bank and the column origin so a
				// mid-line row cross can re-ACTIVE row+1 from column 0.
				cur_row     <= addr[25:13];
				cur_bank    <= addr[12:11];
				col_base    <= addr[10:1];
				state       <= STATE_OPEN_1;
				command     <= CMD_ACTIVE;
				// column-low map (AS4C32M16, 64MB): row = addr[25:13], bank = addr[12:11]
				SDRAM_A     <= addr[25:13];
				SDRAM_BA    <= addr[12:11];
				chip        <= 1'b0;          // single AS4C32M16 chip (64MB <= addr[25:0])
			end
		end

		// ACTIVE-to-READ or WRITE delay >20ns (-75)
		STATE_OPEN_1: begin
			SDRAM_A     <= '1;
			state       <= STATE_OPEN_2;
		end
		STATE_OPEN_2: begin
			// A[12:11]=DQM (00 on read, byte-mask on write), A[9:0]=column (10-bit,
			// 1024, AS4C32M16).
			// A[10]=auto-precharge: on a WRITE always 1 (single-access). On a READ
			// only when this read is the LAST of the whole line
			// (reads_issued == BURST_BEATS-1) so the row is closed; earlier reads
			// keep the row OPEN (page-open reuse). This path serves BOTH the first
			// read of the line AND the first read after a mid-line row cross
			// (re-entered via STATE_XROW_ACT_W), so reads_issued may be > 0 here.
			// Column = col_base: equals save_addr[9:1] for the first row (and for
			// any single-access write), or 0 after a mid-line row cross.
			// Burst write (save_burst): all 4 words fully enabled -> DQM=00 on word0
		// (trailing words drive DQM=00 in STATE_WB_W1..3); A[10]=1 auto-precharge
		// (each beat is a self-contained 8-byte-aligned BL=4 write, never crossing
		// a row). Single write: DQM from wtbt; A[10]=1. Read: DQM=00, A[10] per the
		// last-read-of-line rule.
		if (save_burst)
			SDRAM_A <= {2'b00, 1'b1, col_base};                       // DQM=00, AP=1, col[9:0]
		else
			SDRAM_A <= {save_we & (new_wtbt ? ~new_wtbt[1] : ~save_addr[0]),
			            save_we & (new_wtbt ? ~new_wtbt[0] :  save_addr[0]),
			            save_we | (reads_issued == BURST_BEATS-1), col_base};
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
			reads_in_row <= reads_in_row + 4'd1;
			state        <= STATE_READ_WAIT;
		end

		// Wait for the in-flight beat to be fully captured (beat_done), then either
		// issue the next BL=4 read at the next 4-word column within the SAME open
		// row (page-open reuse, no re-ACTIVE), or finish the line. IDLE_7 gives
		// burst(4) + tRP slack before the next ACTIVE.
		STATE_READ_WAIT: begin
			if (beat_done) begin
				if (reads_issued < BURST_BEATS) begin
					// Next beat's column WITHIN the current open row =
					//   col_base + reads_in_row*4.
					// Compute it as an 11-bit value: bit[10] set => the group runs off
					// the end of the 1024-column row (PAGE WRAP). col_base+reads*4 is
					// always 4-aligned, so a group never straddles the 1024 boundary;
					// it either fits entirely (bit[10]==0) or starts in the next row.
					next_col_full = {1'b0, col_base} + {reads_in_row, 2'b00};
					if (next_col_full[10]) begin
						// PAGE WRAP: this line crosses into the NEXT row. Close the
						// current row (PRECHARGE), then ACTIVE row+1 (same bank) and
						// resume the SAME line from column 0 of the new row. beat_idx /
						// reads_issued (whole-line counters) are PRESERVED; only the
						// per-row origin (col_base) and reads_in_row reset.
						command     <= CMD_PRECHARGE;
						SDRAM_BA    <= cur_bank;
						SDRAM_A[10] <= 1'b0;           // precharge THIS bank only
						state       <= STATE_XROW_PRE_W;
					end else begin
						// Same-row next beat (page-open reuse, no re-ACTIVE). A[10]
						// (auto-precharge) is set ONLY on the LAST read of the whole
						// line (reads_issued == BURST_BEATS-1) to close the row.
						SDRAM_A <= {2'b00, (reads_issued == BURST_BEATS-1),
						            next_col_full[9:0]};
						state   <= STATE_READ;
					end
				end else begin
					state   <= STATE_IDLE_7;
				end
			end
		end

		// ---- mid-line page-wrap (row cross) sequence ----------------------------
		// PRECHARGE current row -> tRP -> ACTIVE next row -> tRCD -> resume reads
		// at column 0 (col_base=0) via the shared STATE_OPEN_2 read-setup path.
		STATE_XROW_PRE_W: begin
			// tRP slack: PRECHARGE (issued in STATE_READ_WAIT) -> ACTIVE here is
			// 2 cycles x 10ns = 20ns >= tRP_min 15ns (-75). Don't shorten.
			state <= STATE_XROW_PRE;
		end
		STATE_XROW_PRE: begin
			// ACTIVE the NEXT row (row+1, same bank). Bank carry on row overflow is
			// NOT handled (a single line spanning the very top row of a bank is an
			// extreme edge; lines are << a row in practice).
			cur_row     <= cur_row + 13'd1;
			col_base    <= 9'd0;          // new row's reads start at column 0
			reads_in_row <= 4'd0;
			command     <= CMD_ACTIVE;
			SDRAM_A     <= cur_row + 13'd1;
			SDRAM_BA    <= cur_bank;
			state       <= STATE_XROW_ACT;
		end
		STATE_XROW_ACT:   state <= STATE_XROW_ACT_W;  // tRCD: ACTIVE(XROW_PRE)->READ(after OPEN_2)
		STATE_XROW_ACT_W: state <= STATE_OPEN_2;      // = 3 cycles x 10ns = 30ns >= tRCD_min 15ns; sets col_base=0+A[10], then READ

		STATE_WRITE: begin
			command     <= CMD_WRITE;
			dq_oe       <= 1'b1;
			if (save_burst) begin
				// BL=4 burst write: word0 with the WRITE command; words 1..3 on the
				// next 3 cycles (STATE_WB_W1..3). DQM=00 (set in STATE_OPEN_2) keeps
				// all bytes enabled for the whole burst.
				//
				// TIMING (issue #19, -0.225ns state->dq_r path): instead of a
				// state-indexed mux that selects which 16-bit word of wb_data drives
				// dq_r per state (state -> decode -> word-mux -> dq_r), dq_r is ALWAYS
				// fed from the FIXED low word wb_data[15:0] and wb_data is SHIFTED down
				// one word each data cycle. This makes dq_r a pure register-to-register
				// path (wb_data[15:0] -> dq_r) with no state decode in front of the dq_r
				// mux, cutting the depth. Word order is unchanged: word0 (wb_data[15:0]
				// at latch time) goes out first in STATE_WRITE, then word1,2,3 as the
				// shift advances in STATE_WB_W1..3.
				dq_r    <= wb_data[15:0];
				wb_data <= {16'h0, wb_data[63:16]};   // shift: next word -> low slot
				state   <= STATE_WB_W1;
			end else begin
				// single-access write: word0 enabled per wtbt (DQM set in OPEN_2),
				// then 3 cycles of DQM=11 to MASK the trailing burst words (NO_WRITE
				// _BURST=0 means the chip would otherwise sample 3 more words). This
				// keeps single-word writes BIT-IDENTICAL to the old NO_WRITE_BURST=1
				// behavior (only word0 lands).
				dq_r  <= new_wtbt ? new_data : {new_data[7:0], new_data[7:0]};
				state <= STATE_WRITE_M1;
			end
		end
		// trailing burst-write data words (DQM=00 already on SDRAM_A[12:11] from
		// STATE_OPEN_2; keep it so by not touching SDRAM_A here). command=NOP.
		STATE_WB_W1: begin dq_r <= wb_data[15:0]; wb_data <= {16'h0, wb_data[63:16]}; dq_oe <= 1'b1; state <= STATE_WB_W2; end
		STATE_WB_W2: begin dq_r <= wb_data[15:0]; wb_data <= {16'h0, wb_data[63:16]}; dq_oe <= 1'b1; state <= STATE_WB_W3; end
		STATE_WB_W3: begin dq_r <= wb_data[15:0]; dq_oe <= 1'b1; ready <= 1; state <= STATE_IDLE_5; end
		// single-write trailing mask cycles: drive DQM=11 so the chip ignores the
		// (don't-care) DQ on these BL words. dq_oe=0 (default) -> DQ released.
		STATE_WRITE_M1: begin SDRAM_A[12:11] <= 2'b11; state <= STATE_WRITE_M2; end
		STATE_WRITE_M2: begin SDRAM_A[12:11] <= 2'b11; state <= STATE_WRITE_M3; end
		STATE_WRITE_M3: begin SDRAM_A[12:11] <= 2'b11; ready <= 1; state <= STATE_IDLE_5; end
	endcase

	if(init) begin
		state <= STATE_STARTUP;
		refresh_count <= startup_refresh_max - sdram_startup_cycles;
		burst_cap <= 1'b0;
		dr0_q <= 1'b0;
		dout_ready <= 1'b0;
		new_burst <= 1'b0;
		save_burst <= 1'b0;
		beat_idx <= 4'd0;
		reads_issued <= 4'd0;
		reads_in_row <= 4'd0;
		// clear pipelined startup flags so no stale one-shot fires on reset.
		// (refresh_count resets far below every event constant, so the flags
		//  would compute 0 next cycle anyway, but clear them for cleanliness.)
		su_chip1 <= 1'b0;
		su_chip0 <= 1'b0;
		su_pre   <= 1'b0;
		su_ref   <= 1'b0;
		su_mode  <= 1'b0;
	end

	old_we <= we;
	if(we & ~old_we) {ready, new_we, new_burst, new_data, new_wtbt} <= {1'b0, 1'b1, 1'b0, din, wtbt};

	// BL=4 burst-write request (issue #19): latch the full 64-bit beat and set
	// new_we|new_burst so the shared OPEN->WRITE path runs and branches to the
	// burst data cycles in STATE_WRITE. Edge-detected like we/rd.
	old_we_b <= we_burst;
	if(we_burst & ~old_we_b) {ready, new_we, new_burst, wb_data} <= {1'b0, 1'b1, 1'b1, din64};

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
