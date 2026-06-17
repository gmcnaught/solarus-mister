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
// blt_dout mux: when sd_dready=1 and is_fb=1 (blt_addr still pointing at an FB
// region — the blitter holds blt_addr stable while stalled), return sd_dout64;
// otherwise return ddr_dout. This avoids a registered "which bus" latch which
// has Icarus scheduling issues (initial block clears blt_rd before the always
// @posedge FSM can sample it, so the latch never sets).
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
  input  wire        sd_busy
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

  reg [2:0] st;
  reg [1:0] lane;          // which lane S_WLANES should emit next
  reg       rd_on_sdram;   // (unused in mux; kept for debug visibility in sim)

  // active lane's enable (uses registered 'lane')
  wire cur_lane_en = lane_active[lane];

  // busy: hold while non-IDLE, or while SDRAM busy during an FB access
  assign blt_busy = (st != S_IDLE) | (is_fb & (blt_rd | blt_wr) & sd_busy);

  // ---------------------------------------------------------------------------
  // blt_dout / blt_dout_ready — COMBINATORIAL mux
  // Route return data based on is_fb (the current blt_addr decode). The blitter
  // issues a single outstanding access and holds blt_addr stable, so is_fb is
  // stable when dready arrives. This avoids needing a registered rd_on_sdram
  // latch, which has simulation scheduling issues with the testbench's
  // blt_rd=1;@(posedge);blt_rd=0 pattern (Icarus deasserts rd before the FSM
  // posedge event fires, so the latch never gets set).
  // ---------------------------------------------------------------------------
  assign blt_dout       = (sd_dready & is_fb) ? sd_dout64 : ddr_dout;
  assign blt_dout_ready = sd_dready | ddr_dout_ready;

  // ---------------------------------------------------------------------------
  // Priority-encode first enabled lane >= start_lane.
  // Returns {found[0], lane[1:0]} packed into 3 bits.
  // ---------------------------------------------------------------------------
  function automatic [2:0] first_enabled_lane;
    input [1:0] start;
    input [3:0] enables;
    integer i;
    reg found;
    reg [1:0] fl;
    begin
      found = 1'b0;
      fl    = 2'd0;
      // Scan from 3 down to 0; lowest-priority assignment wins (lowest index).
      for (i = 3; i >= 0; i = i - 1) begin
        if ((i[1:0] >= start) && enables[i]) begin
          fl    = i[1:0];
          found = 1'b1;
        end
      end
      first_enabled_lane = {found, fl};
    end
  endfunction

  // First active lane from 0 (S_IDLE immediate write)
  wire [2:0] idle_first     = first_enabled_lane(2'd0, lane_active);
  wire       idle_found     = idle_first[2];
  wire [1:0] idle_lane      = idle_first[1:0];

  // Next active lane after idle_lane (used in S_IDLE transition)
  wire [2:0] idle_next_w    = first_enabled_lane(idle_lane + 2'd1, lane_active);
  wire       idle_next_found= idle_next_w[2];
  wire [1:0] idle_next_lane = idle_next_w[1:0];

  // Next active lane after 'lane' (used in S_WLANES transition)
  wire [2:0] wl_next_w      = first_enabled_lane(lane + 2'd1, lane_active);
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
          if (blt_rd) begin
            sd_rd  = 1'b1;
          end else if (blt_wr) begin
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

      // S_RDLAT, S_WWAIT: no new SDRAM strobes
      default: ;
    endcase
  end

  // ---------------------------------------------------------------------------
  // FSM (registered)
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (reset) begin
      st          <= S_IDLE;
      lane        <= 2'd0;
      rd_on_sdram <= 1'b0;
    end else begin
      case (st)
        S_IDLE: begin
          if (is_fb & ~sd_busy) begin
            if (blt_rd) begin
              // Read: assert sd_rd (comb), wait for sd_dready.
              rd_on_sdram <= 1'b1;
              st          <= S_RDLAT;
            end else if (blt_wr & ~all_lanes & idle_found) begin
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
            // Full-qword burst: emitted combinatorially; stay in S_IDLE.
          end else if (~is_fb & blt_rd) begin
            rd_on_sdram <= 1'b0;
          end
        end

        S_RDLAT: begin
          if (sd_dready) begin
            // blt_dout exposed combinatorially via rd_on_sdram mux.
            rd_on_sdram <= 1'b0;
            st          <= S_IDLE;
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

        default: st <= S_IDLE;
      endcase
    end
  end

endmodule
`default_nettype wire
