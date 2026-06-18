// sdram_src_arb.sv — fixed-priority registered-grant arbiter in front of sdram_psx.
//
// Three clients (strict priority order):
//   P_SCAN  (scanout line read)           — scan_* ports
//   P_SRC   (blitter source reads + staging writes) — p0_* ports (unchanged)
//   P_DST   (blitter dest read/write)     — dst_* ports
//
// A granted READ burst is held (owner locked) until the controller signals
// line-complete (c_ready), so beat data is never interleaved between clients.
// Writes are also held for one c_ready cycle (the controller pulses ready at
// the end of every write cycle the same way it does for reads).
//
// c_dready / c_dout64 are the per-beat strobe and data from sdram_psx
// (= dout_ready / dout64 on the controller).  They are routed to the current
// owner's output ports.
`default_nettype none
module sdram_src_arb (
   input  wire        clk,
   input  wire        reset,

   // ---- P_SCAN: scanout line read (highest priority) ----------------------
   input  wire [26:0] scan_addr,
   input  wire        scan_rd,
   input  wire [7:0]  scan_burst,      // number of 64-bit beats to fetch.
                                      // Reserved for beat-level use; currently unused
                                      // because sdram_psx fires c_ready / ready only
                                      // after ALL beats (BURST_BEATS=1 today — one
                                      // 64-bit transfer per transaction).  Wire here
                                      // so the scanout reader can declare beat count
                                      // without an interface change when needed.
   output wire        scan_busy,       // asserted while P_SCAN does NOT own the bus
   output wire [63:0] scan_dout64,
   output wire        scan_dready,

   // ---- P_SRC: blitter source reads + staging writes (original p0_*) -----
   input  wire [26:0] p0_addr,         // READ byte address
   input  wire        p0_rd,
   output reg         p0_grant,
   output wire        p0_busy,
   input  wire        p0_we,           // staging WRITE (single 16-bit word)
   input  wire [15:0] p0_din,
   input  wire [26:0] p0_waddr,
   input  wire        p0_we_burst,     // BL=4 burst-write
   input  wire [63:0] p0_din64,
   output wire        p0_dready,        // per-beat strobe, owner-gated (owner==P_SRC)
   output wire [63:0] p0_dout64,        // per-beat data, owner-gated

   // ---- P_DST: blitter destination read/write (lowest priority) ----------
   input  wire [26:0] dst_addr,
   input  wire        dst_rd,
   input  wire        dst_we,
   input  wire [15:0] dst_din,
   input  wire        dst_we_burst,
   input  wire [63:0] dst_din64,
   output wire        dst_busy,
   output wire [63:0] dst_dout64,
   output wire        dst_dready,

   // ---- controller-facing (to sdram_psx) ----------------------------------
   output reg  [26:0] c_addr,
   output reg         c_rd,
   output reg         c_we,
   output reg  [15:0] c_din,
   output reg         c_we_burst,
   output reg  [63:0] c_din64,
   input  wire        c_ready,         // line-complete from sdram_psx (= sps_ready)
   input  wire        c_busy,          // ~c_ready (controller not accepting)
   input  wire        c_dready,        // per-beat strobe (= sps_dready / dout_ready)
   input  wire [63:0] c_dout64         // per-beat data   (= sps_dout64 / dout64)
);

   // owner encoding: 0=none, 1=SCAN, 2=SRC, 3=DST
   reg [1:0] owner;
   // held_txn: 1 while any granted transaction (read or write) is in flight,
   // waiting for c_ready (controller's line-complete / write-done strobe).
   // Blocks re-arbitration so beat data is never interleaved between clients.
   reg       held_txn;

   wire scan_req = scan_rd;
   wire src_req  = p0_rd | p0_we | p0_we_burst;
   wire dst_req  = dst_rd | dst_we | dst_we_burst;

   always @(posedge clk) begin
      if (reset) begin
         owner     <= 2'd0;
         held_txn <= 1'b0;
         c_rd      <= 1'b0;
         c_we      <= 1'b0;
         c_we_burst<= 1'b0;
         c_addr    <= 27'd0;
         c_din     <= 16'd0;
         c_din64   <= 64'd0;
         p0_grant  <= 1'b0;
      end else begin
         // default: de-assert command strobes each cycle (controller latches on edge)
         c_rd       <= 1'b0;
         c_we       <= 1'b0;
         c_we_burst <= 1'b0;
         p0_grant   <= 1'b0;

         if (held_txn) begin
            // Waiting for the in-flight burst to complete.
            // c_ready fires when the whole line is done.
            if (c_ready) held_txn <= 1'b0;
         end else if (!c_busy) begin
            // Controller is idle — re-arbitrate: SCAN > SRC > DST
            if (scan_req) begin
               owner     <= 2'd1;
               c_addr    <= scan_addr;
               c_rd      <= 1'b1;
               held_txn <= 1'b1;
            end else if (src_req) begin
               owner    <= 2'd2;
               p0_grant <= 1'b1;
               if (p0_rd) begin
                  c_addr    <= p0_addr;
                  c_rd      <= 1'b1;
                  held_txn <= 1'b1;
               end else if (p0_we_burst) begin
                  c_addr     <= p0_waddr;
                  c_din64    <= p0_din64;
                  c_we_burst <= 1'b1;
                  held_txn  <= 1'b1;   // wait for write-complete ready too
               end else begin  // p0_we
                  c_addr    <= p0_waddr;
                  c_din     <= p0_din;
                  c_we      <= 1'b1;
                  held_txn <= 1'b1;
               end
            end else if (dst_req) begin
               owner <= 2'd3;
               if (dst_rd) begin
                  c_addr    <= dst_addr;
                  c_rd      <= 1'b1;
                  held_txn <= 1'b1;
               end else if (dst_we_burst) begin
                  c_addr     <= dst_addr;
                  c_din64    <= dst_din64;
                  c_we_burst <= 1'b1;
                  held_txn  <= 1'b1;
               end else begin  // dst_we
                  c_addr    <= dst_addr;
                  c_din     <= dst_din;
                  c_we      <= 1'b1;
                  held_txn <= 1'b1;
               end
            end else begin
               owner <= 2'd0;
            end
         end
      end
   end

   // Route controller read-beat data back to the current owner.
   // scan_dout64/p0_dout64/dst_dout64 simply share the bus (only one owner
   // at a time will have its dready asserted).
   assign scan_dready  = c_dready & (owner == 2'd1);
   assign scan_dout64  = c_dout64;
   assign p0_busy      = (owner != 2'd2) | c_busy;
   // p0_dready/p0_dout64 — owner-gated read-beat outputs for P_SRC, mirroring the
   // scan_* / dst_* gating.  Solarus.sv now drives bs_src_dready/bs_src_dout64
   // from these instead of the raw controller strobes, so beats from a SCAN/DST
   // transaction can never latch into the blitter source path.
   assign p0_dready    = c_dready & (owner == 2'd2);
   assign p0_dout64    = c_dout64;
   // FIX B (integration deadlock): the old `(owner != 2'd3) | c_busy` asserted
   // dst_busy before P_DST was ever granted (owner starts 0=none), but vram_demux
   // only issues its request when !sd_busy(=!dst_busy) -> P_DST was never granted.
   // Report busy only when the controller is busy, a txn is held, or a HIGHER
   // priority client (SCAN/SRC) owns the bus. Idle/none-owner leaves dst free to
   // request, so the arbiter can grant P_DST.
   assign dst_busy     = c_busy | held_txn | (owner == 2'd1) | (owner == 2'd2);
   assign dst_dready   = c_dready & (owner == 2'd3);
   assign dst_dout64   = c_dout64;

   // scan_busy: SCAN is the HIGHEST-priority client, so it must be free to issue
   // whenever the controller can accept a command — i.e. only busy while the
   // controller is busy or a transaction is in flight (held_txn). The old
   // `(owner != 2'd1) | c_busy` form had the same idle-deadlock bug FIX B cured
   // for dst_busy: at idle owner=none so scan_busy was stuck high, but owner only
   // becomes SCAN after scan_rd, which the reader only asserts when !scan_busy —
   // circular, so the scan path could never bootstrap its first line fetch.
   // (Bug surfaced by tb_vram_contention; tb_blitter_system tied scan off.)
   assign scan_busy    = c_busy | held_txn;

endmodule
