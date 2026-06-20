`default_nettype none
`include "vram_defs.vh"
// Address-decode demux: routes the vendored blitter's mem_* between the DDR
// arbiter (blt_* port) and the SDRAM arbiter (P_DST). FB0/FB1 region -> SDRAM
// (byte-address remapped); everything else -> DDR. Full-qword writes (all 4
// lanes) -> SDRAM burst write; partial writes -> serialized 16-bit word writes.
//
// All SDRAM output strobes (sd_we, sd_we_burst, sd_rd, sd_addr, sd_din,
// sd_din64) are COMBINATORIAL so the testbench sdmem model (@posedge clk)
// captures writes at the same edge the FSM gates them.
//
// blt_dout mux: uses the registered rd_on_sdram latch (set when an FB read is
// issued in S_IDLE, cleared when sd_dready arrives in S_RDLAT). This ensures
// the correct source is selected even if blt_addr changes between issue and
// data return, and prevents DDR dready from leaking during an SDRAM read.
//
// Full-qword write flow (S_IDLE -> S_BWAIT -> S_IDLE):
//   S_IDLE:  sd_we_burst asserted combinatorially (one cycle), then FSM
//            transitions to S_BWAIT. sd_busy back-pressure: if sd_busy on
//            arrival, blt_busy is asserted and sd_we_burst is NOT fired until
//            sd_busy clears (honoring the existing blt_busy stall in S_IDLE).
//   S_BWAIT: hold blt_busy=1 until blt_wr deasserts; exactly one burst per
//            full-qword write request.
//
// Partial-write flow (S_IDLE -> [S_WLANES*] -> S_WWAIT -> S_IDLE):
//   S_IDLE:   priority-encode first enabled lane, drive sd_we immediately,
//             transition to S_WLANES (more lanes remain) or S_WWAIT (done).
//   S_WLANES: drive sd_we for 'lane', find next via priority encoder, or
//             S_WWAIT when done.
//   S_WWAIT:  hold blt_busy until blt_wr deasserts; prevents S_IDLE from
//             re-firing sd_we on every cycle blt_wr stays asserted.
module vram_demux (
  input  wire        clk, reset,
  // blitter mem_* (qword-addressed, [31:0] carrying a 29-bit range)
  input  wire [31:0] blt_addr,
  input  wire        blt_rd, blt_wr,
  input  wire [63:0] blt_din,
  input  wire [7:0]  blt_be,
  // SDRAM (FB) read-burst beat count. comp_burst issues ONE read with this many
  // beats and a single start address; the demux walks +8 bytes/beat internally.
  // Used ONLY for FB reads; non-FB (DDR) bursts route around the demux. 1 = legacy.
  input  wire [7:0]  blt_burstcnt,
  output wire [63:0] blt_dout,
  output wire        blt_dout_ready,
  output wire        blt_busy,
  // DDR side (ddr_blitter_arb blt_* port)
  output wire [28:0] ddr_addr,
  output wire        ddr_rd, ddr_wr,
  output wire [63:0] ddr_din,
  output wire [7:0]  ddr_be,
  input  wire [63:0] ddr_dout,
  input  wire        ddr_dout_ready,
  input  wire        ddr_busy,
  // SDRAM side (arbiter P_DST) — combinatorial strobes
  output reg  [26:0] sd_addr,
  output reg         sd_rd,
  output reg  [15:0] sd_din,
  output reg         sd_we,
  output reg  [63:0] sd_din64,
  output reg         sd_we_burst,
  input  wire [63:0] sd_dout64,
  input  wire        sd_dready,
  input  wire        sd_busy,
  // DEBUG (#34): {rd_on_sdram, st[2:0]} — is the in-flight blitter read routed to
  // SDRAM (P_DST) vs DDR, and the demux FSM state. Published in the HW wedge probe.
  output wire  [3:0] dbg
);
  // ---------------------------------------------------------------------------
  // Address decode (combinatorial)
  // ---------------------------------------------------------------------------
  wire [28:0] qw      = blt_addr[28:0];
  wire in_fb0 = (qw >= `FB_DDR0_QW) && (qw < (`FB_DDR0_QW + `FB_QWORDS));
  wire in_fb1 = (qw >= `FB_DDR1_QW) && (qw < (`FB_DDR1_QW + `FB_QWORDS));
  wire is_fb  = in_fb0 | in_fb1;

  wire [28:0] off_qw  = in_fb1 ? (qw - `FB_DDR1_QW) : (qw - `FB_DDR0_QW);
  wire [26:0] fb_base = in_fb1 ? `SDRAM_FB1_BASE : `SDRAM_FB0_BASE;
  // byte address of this qword in SDRAM (qword offset * 8)
  wire [26:0] qw_byte = fb_base + {off_qw[23:0], 3'b000};

  // full-qword detect (all four 16-bit lanes enabled)
  wire all_lanes = (blt_be == 8'hFF);

  // Lane-enable per 16-bit word (combinatorial, uses live blt_be)
  // lane_active[0] = bytes [1:0], lane_active[1] = bytes [3:2], etc.
  wire [3:0] lane_active = { (blt_be[7]|blt_be[6]),
                              (blt_be[5]|blt_be[4]),
                              (blt_be[3]|blt_be[2]),
                              (blt_be[1]|blt_be[0]) };

  // ---------------------------------------------------------------------------
  // DDR passthrough (non-FB, combinatorial)
  // ---------------------------------------------------------------------------
  assign ddr_addr = qw;
  assign ddr_rd   = blt_rd & ~is_fb;
  assign ddr_wr   = blt_wr & ~is_fb;
  assign ddr_din  = blt_din;
  assign ddr_be   = blt_be;

  // ---------------------------------------------------------------------------
  // FSM registers
  // ---------------------------------------------------------------------------
  localparam S_IDLE   = 3'd0;
  localparam S_RDLAT  = 3'd1;
  localparam S_WLANES = 3'd2;
  localparam S_WWAIT  = 3'd3;  // post-partial-write: hold busy until blt_wr=0
  localparam S_BWAIT  = 3'd4;  // post-burst-write:   hold busy until blt_wr=0
  localparam S_RDISS  = 3'd5;  // issue the next beat of a multi-beat SDRAM read

  reg [2:0] st;
  reg [1:0] lane;          // which lane S_WLANES should emit next
  reg       rd_on_sdram;   // set when an FB read is issued; cleared on sd_dready
  reg [7:0] rd_beats_left; // SDRAM read beats still to RETURN after the current one
  reg [26:0] rd_cur_byte;  // byte address of the NEXT SDRAM read beat to issue
  reg [28:0] acc_qw;       // qword addr of the write currently completing (S_BWAIT/S_WWAIT)
  assign dbg = {rd_on_sdram, st};   // #34 HW wedge probe

  // active lane's enable (uses registered 'lane')
  wire cur_lane_en = lane_active[lane];

  // A NEW FB write (different qword than the one completing) is pending while the
  // demux is in a write-completion state. comp_burst pipelines the next write the
  // moment it sees the previous accepted (blt_busy low); if blt_busy drops during
  // S_BWAIT/S_WWAIT with a new write on the bus, comp_burst advances and that write
  // is silently dropped. Holding busy one extra cycle lets S_IDLE accept it. The
  // legacy blitter re-presents the SAME qword while completing -> not flagged.
  wire new_wr_pending = is_fb & blt_wr & (qw != acc_qw);

  // busy: per-state (FIX A — integration deadlock). In S_BWAIT, blt_busy follows
  // sd_busy: the burst write is HELD until the arbiter accepts (sd_busy drops),
  // then busy releases so the blitter de-asserts blt_wr. Without this the blitter
  // holds blt_wr until !mem_busy while the demux waits for !blt_wr — deadlock.
  //
  // S_BWAIT also holds busy while blt_rd is asserted: the blitter PIPELINES its
  // next request (e.g. a DDR command-ring read) the moment it sees the write
  // accepted, but the demux is still in S_BWAIT and only forwards a new transaction
  // from S_IDLE. Without the blt_rd hold, a transient sd_busy=0 in S_BWAIT drops
  // blt_busy and the blitter FALSELY latches rd_issued for a read the arbiter never
  // accepted -> the beat never returns -> hang. (Integration deadlock #3, found by
  // this regression: blitter pipelines a ring read behind an in-flight FB write.)
  // Not gated on the COMPLETING write's blt_wr (that would re-deadlock the write
  // completion) — but a NEW pending write (different qword) DOES hold busy so
  // comp_burst's pipelined next write is not dropped (see new_wr_pending above).
  // A partial (multi-lane) FB write serializes over S_IDLE->S_WLANES; comp_burst
  // must hold blt_din/blt_be stable across it, so hold busy from the S_IDLE cycle
  // that starts the partial write (else comp_burst advances after lane 0 and the
  // remaining lanes/beats are dropped).
  //
  // S_WWAIT (#34 read-issue desync): the blitter PIPELINES its next dst READ behind
  // a partial write; while the demux is still draining S_WWAIT, the blitter's
  // S_RD_WAIT sees mem_busy=0 and FALSELY latches rd_issued, then drops mem_rd
  // before the demux returns to S_IDLE -> read never issued -> hang (repro
  // tb_blitter_rd_desync.sv). The (S_WWAIT & blt_rd) busy term below blocks that
  // spurious latch; SAFE because blt_wr is already 0 in S_WWAIT so it still exits
  // on !blt_wr.
  wire idle_partial_wr = is_fb & blt_wr & ~all_lanes & (blt_be != 8'd0);
  assign blt_busy = (st == S_RDLAT)
                  | (st == S_RDISS)
                  | (st == S_WLANES)
                  | ((st == S_BWAIT) & (sd_busy | blt_rd | new_wr_pending))
                  | ((st == S_WWAIT) & (blt_rd | new_wr_pending))  // #34 blt_rd + our new_wr_pending
                  | ((st == S_IDLE) & is_fb  & (blt_rd | blt_wr) & sd_busy)
                  | ((st == S_IDLE) & idle_partial_wr & ~sd_busy)
                  | ((st == S_IDLE) & ~is_fb & (blt_rd | blt_wr) & ddr_busy);

  // ---------------------------------------------------------------------------
  // blt_dout / blt_dout_ready — registered-latch mux
  // rd_on_sdram is set in S_IDLE when an FB read is issued (FSM transitions to
  // S_RDLAT) and cleared in S_RDLAT when sd_dready arrives. This keeps the
  // correct source selected for the full latency window regardless of whether
  // blt_addr or blt_rd change between issue and return.
  //
  // Using rd_on_sdram (not is_fb) prevents a DDR dready from leaking into
  // blt_dout_ready during an in-flight SDRAM read, and prevents SDRAM data
  // from leaking into a DDR read whose blt_addr happens to be in the FB range.
  // ---------------------------------------------------------------------------
  assign blt_dout       = rd_on_sdram ? sd_dout64  : ddr_dout;
  assign blt_dout_ready = rd_on_sdram ? sd_dready  : ddr_dout_ready;

  // ---------------------------------------------------------------------------
  // Priority-encode first enabled lane >= start_lane.
  // Returns {found[0], lane[1:0]} packed into 3 bits.
  // ---------------------------------------------------------------------------
  // first_enabled_lane: scan lanes [start..3]; return {found, lane_index}.
  // start is 3-bit so callers can pass lane+1 without 2-bit wrap: when
  // start==4 (after lane 3 processed) no index i in [0..3] satisfies i>=4,
  // so found=0 correctly terminates the S_WLANES serialization loop.
  function automatic [2:0] first_enabled_lane;
    input [2:0] start;  // 3-bit: allows start=4 to signal "no more lanes"
    input [3:0] enables;
    integer i;
    reg found;
    reg [1:0] fl;
    begin
      found = 1'b0;
      fl    = 2'd0;
      // Scan from 3 down to 0; lowest-priority assignment wins (lowest index).
      for (i = 3; i >= 0; i = i - 1) begin
        if ((i[2:0] >= start) && enables[i]) begin
          fl    = i[1:0];
          found = 1'b1;
        end
      end
      first_enabled_lane = {found, fl};
    end
  endfunction

  // First active lane from 0 (S_IDLE immediate write)
  wire [2:0] idle_first     = first_enabled_lane(3'd0, lane_active);
  wire       idle_found     = idle_first[2];
  wire [1:0] idle_lane      = idle_first[1:0];

  // Next active lane after idle_lane (used in S_IDLE transition).
  // Use 3-bit add so idle_lane=3 yields start=4 (not 0) -> found=0 when done.
  wire [2:0] idle_next_w    = first_enabled_lane({1'b0, idle_lane} + 3'd1, lane_active);
  wire       idle_next_found= idle_next_w[2];
  wire [1:0] idle_next_lane = idle_next_w[1:0];

  // Next active lane after 'lane' (used in S_WLANES transition).
  // 3-bit add prevents 2-bit wrap: lane=3 -> start=4 -> found=0 -> S_WWAIT.
  wire [2:0] wl_next_w      = first_enabled_lane({1'b0, lane} + 3'd1, lane_active);
  wire       wl_next_found  = wl_next_w[2];
  wire [1:0] wl_next_lane   = wl_next_w[1:0];

  // ---------------------------------------------------------------------------
  // SDRAM combinatorial outputs
  // ---------------------------------------------------------------------------
  always @(*) begin
    sd_rd       = 1'b0;
    sd_we       = 1'b0;
    sd_we_burst = 1'b0;
    sd_addr     = qw_byte;
    sd_din      = 16'd0;
    sd_din64    = blt_din;

    case (st)
      S_IDLE: begin
        if (is_fb & ~sd_busy) begin
          // Reads are issued+held in S_RDLAT (steal-proof, per-beat); S_IDLE just
          // sets up the burst and forwards writes.
          if (blt_wr) begin
            if (all_lanes) begin
              // Full qword -> burst write (one cycle, stays in S_IDLE)
              sd_we_burst = 1'b1;
            end else if (idle_found) begin
              // Partial: emit the first enabled lane immediately this cycle.
              sd_addr = qw_byte + {25'd0, idle_lane, 1'b0};
              sd_din  = blt_din[idle_lane*16 +: 16];
              sd_we   = 1'b1;
            end
          end
        end
      end

      S_WLANES: begin
        // Emit current 'lane' (if enabled) and wait for sd_busy=0
        if (!sd_busy) begin
          sd_addr = qw_byte + {25'd0, lane, 1'b0};
          sd_din  = blt_din[lane*16 +: 16];
          sd_we   = cur_lane_en;
        end
      end

      S_BWAIT: begin
        // FIX A: keep REQUESTING the burst write until the arbiter accepts it
        // (sd_busy drops). On a single-fire model this would over-write, but the
        // arbiter latches exactly one accept (sd_we_burst & ~sd_busy), so exactly
        // one burst lands in SDRAM. Honors the "one write per full-qword" invariant.
        sd_we_burst = sd_busy;
        sd_addr     = qw_byte;
        sd_din64    = blt_din;
      end

      // S_RDLAT: ISSUE + HOLD the current beat until it lands (#34 steal-proof read,
      // extended per-beat). Holding sd_rd past the accept is safe: sdram_src_arb
      // raises held_txn (dst_busy=sd_busy) for the in-flight beat, so it's granted
      // exactly once; sd_addr walks per beat via rd_cur_byte; drop on sd_dready.
      S_RDLAT: begin
        sd_rd   = ~sd_dready;
        sd_addr = rd_cur_byte;
      end

      // S_WWAIT: no new SDRAM strobes.
      default: ;
    endcase
  end

  // ---------------------------------------------------------------------------
  // FSM (registered)
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset) begin
      st            <= S_IDLE;
      lane          <= 2'd0;
      rd_on_sdram   <= 1'b0;
      rd_beats_left <= 8'd0;
      rd_cur_byte   <= 27'd0;
      acc_qw        <= 29'h1FFFFFFF;   // sentinel: matches no real FB qword
    end else begin
      case (st)
        S_IDLE: begin
          if (is_fb & ~sd_busy) begin
            if (blt_rd) begin
              // Read: latch rd_on_sdram + the multi-beat walk, then ISSUE in S_RDLAT
              // (held until each beat's dready — #34 steal-proof model, extended to N
              // beats). comp_burst sends ONE start address + burstcnt; beats walk +8.
              // rd_cur_byte is the CURRENT in-flight beat address (held in S_RDLAT).
              rd_on_sdram   <= 1'b1;
              rd_beats_left <= blt_burstcnt - 8'd1;   // beats still to return after beat 0
              rd_cur_byte   <= qw_byte;               // address of beat 0 (in-flight)
              st            <= S_RDLAT;
            end else if (blt_wr) begin
              acc_qw <= qw;   // remember this write's qword (new_wr_pending compare)
              if (all_lanes) begin
                // Full-qword burst: sd_we_burst fired combinatorially this cycle.
                // Transition to S_BWAIT to hold blt_busy and prevent re-fire.
                st <= S_BWAIT;
              end else if (idle_found) begin
                // Partial write: first lane emitted combinatorially.
                // Check for more lanes after idle_lane.
                if (idle_next_found) begin
                  // More lanes to write; advance lane and serialize.
                  lane <= idle_next_lane;
                  st   <= S_WLANES;
                end else begin
                  // Single active lane, done. Wait for blt_wr to deassert.
                  st <= S_WWAIT;
                end
              end
            end
          end
        end

        S_RDLAT: begin
          // S_RDLAT issues AND holds the current beat (sd_rd=~sd_dready, sd_addr=
          // rd_cur_byte in the strobe block) until it lands — #34's steal-proof read,
          // now per-beat. On dready, advance to the next beat (stay in S_RDLAT) or
          // finish. rd_on_sdram stays 1 through the LAST beat so its sd_dout64 still
          // forwards via the blt_dout mux the cycle we clear the latch.
          if (sd_dready) begin
            if (rd_beats_left == 8'd0) begin
              rd_on_sdram <= 1'b0;     // last beat: route subsequent DDR reads to ddr_dout
              st          <= S_IDLE;
            end else begin
              rd_beats_left <= rd_beats_left - 8'd1;
              rd_cur_byte   <= rd_cur_byte + 27'd8;   // next beat's address; hold in S_RDLAT
            end
          end
        end

        S_WLANES: begin
          if (!sd_busy) begin
            // 'lane' was driven combinatorially. Find next.
            if (wl_next_found) begin
              lane <= wl_next_lane;
            end else begin
              lane <= 2'd0;
              st   <= S_WWAIT;
            end
          end
        end

        S_WWAIT: begin
          // All lanes done; hold until blt_wr deasserts.
          if (!blt_wr) st <= S_IDLE;
        end

        S_BWAIT: begin
          // FIX A: exit once the arbiter ACCEPTS the burst (sd_busy drops), not on
          // !blt_wr. The blitter holds blt_wr until !mem_busy(=blt_busy), and
          // blt_busy here follows sd_busy — so the accept both lands the write and
          // releases the blitter. Waiting on !blt_wr instead deadlocked.
          if (!sd_busy) st <= S_IDLE;
        end

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
`default_nettype wire
