// fbram_probe.sv — minimal synth wrapper around comp_fbram so Quartus can report
// its real M10K block count (fit.summary) without building the whole core.
//
// An address counter fills every qword then reads it back; the 64-bit read is
// XOR-reduced into the single observable output `obs` so nothing is optimized away.
// All ports are virtual pins (qsf) except the design is RAM-dominated by construction.
`default_nettype none
module fbram_probe(
    input  wire clk,
    input  wire rst,
    output reg  obs
);
    localparam integer FBQW = 19200;
    reg  [14:0] addr;
    reg         phase;          // 0 = fill, 1 = read-back
    reg  [15:0] lfsr;
    wire [63:0] rdq;

    comp_fbram u_fb (
        .clk(clk),
        .wr_en(~phase), .wr_qw(addr), .wr_lane(addr[1:0]), .wr_pix(lfsr),
        .rd_en(phase),  .rd_qw(addr), .rd_qword(rdq)
    );

    always @(posedge clk) begin
        if (rst) begin
            addr <= 15'd0; phase <= 1'b0; obs <= 1'b0; lfsr <= 16'hACE1;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            if (addr == 15'(FBQW-1)) begin addr <= 15'd0; phase <= ~phase; end
            else                          addr <= addr + 15'd1;
            obs <= (^rdq) ^ obs;     // reduce 64-bit read to 1 observable bit
        end
    end
endmodule
`default_nettype wire
