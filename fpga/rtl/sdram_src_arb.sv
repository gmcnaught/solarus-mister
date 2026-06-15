// sdram_src_arb.sv — registered-grant arbiter in front of sdram_psx.
// One source port now; add p1_* the same way for a second consumer later.
//
// Carries BOTH a READ (blitter source pixel reads, C_SRCSEL=1) and a WRITE
// (BLT_OP_STAGE DDR3->SDRAM copy, issue #19) on the SINGLE shared controller
// addr/rd/we/din interface. Reads and writes are temporally disjoint (a STAGE
// runs to completion before any C_SRCSEL=1 source read of that region), so the
// grant simply routes whichever of rd/we is asserted; rd takes priority if both
// were ever asserted in the same cycle (they are not, in practice).
`default_nettype none
module sdram_src_arb (
   input  wire        clk,
   input  wire        reset,
   // port 0 (blitter source reads + staging writes)
   input  wire [26:0] p0_addr,   // READ byte address
   input  wire        p0_rd,
   output reg         p0_grant,
   output wire        p0_busy,
   input  wire        p0_we,     // staging WRITE request (single 16-bit word)
   input  wire [15:0] p0_din,    // staging WRITE data
   input  wire [26:0] p0_waddr,  // staging WRITE byte address
   // staging BL=4 BURST WRITE (issue #19): one 64-bit beat -> one SDRAM burst.
   input  wire        p0_we_burst, // burst-write request
   input  wire [63:0] p0_din64,    // 64-bit beat payload (4 words; word0=[15:0])
   // controller-facing
   output reg  [26:0] c_addr,
   output reg         c_rd,
   output reg         c_we,
   output reg  [15:0] c_din,
   output reg         c_we_burst, // burst-write strobe to sdram_psx (we_burst)
   output reg  [63:0] c_din64,    // 64-bit beat to sdram_psx (din64)
   input  wire        c_ready,   // reserved: line-complete from the controller; unused by
                                 // the single-port grant today, wired at integration (Task 7)
                                 // and used by the future 2-port fairness policy.
   input  wire        c_busy
);
   assign p0_busy = c_busy;
   always @(posedge clk) begin
      if (reset) begin c_rd<=0; c_we<=0; c_din<=0; p0_grant<=0; c_addr<=0;
                       c_we_burst<=0; c_din64<=0; end
      else begin
         c_rd       <= 0;
         c_we       <= 0;
         c_we_burst <= 0;
         p0_grant   <= 0;
         // single port: grant whenever the controller can accept. Reads and writes
         // are temporally disjoint; route the asserted one (read priority is moot).
         if (p0_rd && !c_busy) begin
            c_addr   <= p0_addr;
            c_rd     <= 1;
            p0_grant <= 1;
         end else if (p0_we_burst && !c_busy) begin
            // BL=4 burst write: pass the address + the full 64-bit beat to the
            // controller, which clocks the 4 words out itself (one SDRAM burst).
            c_addr     <= p0_waddr;
            c_din64    <= p0_din64;
            c_we_burst <= 1;
            p0_grant   <= 1;
         end else if (p0_we && !c_busy) begin
            c_addr   <= p0_waddr;
            c_din    <= p0_din;
            c_we     <= 1;
            p0_grant <= 1;
         end
      end
   end
endmodule
