// sdram_src_arb.sv — registered-grant arbiter in front of sdram_psx.
// One source port now; add p1_* the same way for a second consumer later.
`default_nettype none
module sdram_src_arb (
   input  wire        clk,
   input  wire        reset,
   // port 0 (blitter source reads)
   input  wire [26:0] p0_addr,
   input  wire        p0_rd,
   output reg         p0_grant,
   output wire        p0_busy,
   // controller-facing
   output reg  [26:0] c_addr,
   output reg         c_rd,
   input  wire        c_ready,
   input  wire        c_busy
);
   assign p0_busy = c_busy;
   always @(posedge clk) begin
      if (reset) begin c_rd<=0; p0_grant<=0; c_addr<=0; end
      else begin
         c_rd     <= 0;
         p0_grant <= 0;
         // single port: grant whenever the controller can accept and p0 asks.
         if (p0_rd && !c_busy) begin
            c_addr   <= p0_addr;
            c_rd     <= 1;
            p0_grant <= 1;
         end
      end
   end
endmodule
