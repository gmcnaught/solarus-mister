// altddio_out_stub.sv — sim-only behavioral stub of Altera's altddio_out
// (DDR output register), enough to elaborate rtl/sdram.sv in iverilog. The
// SDRAM controller uses it only to forward a DDR clock to SDRAM_CLK; our
// chip model is clocked off `clk` directly, so a simple DDR-mux is sufficient.
`default_nettype none
module altddio_out #(
    parameter extend_oe_disable = "OFF",
    parameter intended_device_family = "Cyclone V",
    parameter invert_output = "OFF",
    parameter lpm_hint = "UNUSED",
    parameter lpm_type = "altddio_out",
    parameter oe_reg = "UNREGISTERED",
    parameter power_up_high = "OFF",
    parameter width = 1
) (
    input  wire [width-1:0] datain_h,
    input  wire [width-1:0] datain_l,
    input  wire             outclock,
    output reg  [width-1:0] dataout,
    input  wire             aclr,
    input  wire             aset,
    input  wire             oe,
    input  wire             outclocken,
    input  wire             sclr,
    input  wire             sset
);
    // DDR: drive datain_h on the high phase, datain_l on the low phase.
    always @(posedge outclock) dataout <= datain_h;
    always @(negedge outclock) dataout <= datain_l;
endmodule
`default_nettype wire
