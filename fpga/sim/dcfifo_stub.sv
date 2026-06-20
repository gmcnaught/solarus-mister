// dcfifo_stub.sv — sim-only behavioral dual-clock show-ahead FIFO.
// Enough to elaborate openbor_video_reader.sv (its audio FIFO) under iverilog;
// Icarus has no Altera megafunctions. NOT cycle-accurate to dcfifo's sync
// pipeline — the scanout tb does not check audio, so functional FIFO is enough.
//
// NOTE: this is a single-domain behavioral model. In the scanout tb the video
// line FIFO's rdclk (clk_vid) and wrclk (ddr_clk) are DIFFERENT clocks, so a
// truly single-clock model would be wrong for that instance. We therefore make
// the read side (rdreq/rdempty/q) follow rdclk and the write side
// (wrreq/wrfull) follow wrclk over a flat memory, using split free-running
// per-clock absolute counters (wr_total on wrclk, rd_total on rdclk); occupancy
// is their difference. This is not glitch-free CDC, but it is functionally
// correct enough for the scanout path under test (pixels are read on rdclk;
// beats are written on wrclk).
`default_nettype none
module dcfifo #(
    parameter intended_device_family = "Cyclone V",
    parameter lpm_numwords = 256,
    parameter lpm_showahead = "ON",
    parameter lpm_type = "dcfifo",
    parameter lpm_width = 64,
    parameter lpm_widthu = 8,
    parameter overflow_checking = "ON",
    parameter rdsync_delaypipe = 4,
    parameter underflow_checking = "ON",
    parameter use_eab = "ON",
    parameter wrsync_delaypipe = 4
) (
    input  wire                  aclr,
    input  wire [lpm_width-1:0]  data,
    input  wire                  rdclk,
    input  wire                  rdreq,
    input  wire                  wrclk,
    input  wire                  wrreq,
    output wire [lpm_width-1:0]  q,
    output wire                  rdempty,
    output wire                  wrfull,
    output wire [1:0]            eccstatus,
    output wire                  rdfull,
    output wire [lpm_widthu-1:0] rdusedw,
    output wire                  wrempty,
    output wire [lpm_widthu-1:0] wrusedw
);
    localparam DEPTH = (1 << lpm_widthu);
    reg [lpm_width-1:0] mem [0:DEPTH-1];

    // Free-running absolute counters (never wrapped to DEPTH): occupancy =
    // wr_total - rd_total. Independent single-driver clocked regs (one per
    // clock) avoid the multi-edge race that corrupts a shared `count`. Each
    // side decides accept based on the OTHER side's current absolute counter,
    // which is exactly the show-ahead dcfifo behavior and is robust for sim
    // CDC (rdclk != wrclk).
    integer wr_total = 0;
    integer rd_total = 0;
    wire [31:0] occ = wr_total - rd_total;   // current occupancy

    // Write side (wrclk): push when wrreq and not full.
    always @(posedge wrclk or posedge aclr) begin
        if (aclr) begin
            wr_total <= 0;
        end else if (wrreq && (wr_total - rd_total) < DEPTH) begin
            mem[wr_total % DEPTH] <= data;
            wr_total <= wr_total + 1;
        end
    end

    // Read side (rdclk): pop when rdreq and not empty. Show-ahead: q always
    // reflects the current head (rd_total % DEPTH).
    always @(posedge rdclk or posedge aclr) begin
        if (aclr) begin
            rd_total <= 0;
        end else if (rdreq && (wr_total - rd_total) > 0) begin
            rd_total <= rd_total + 1;
        end
    end

    assign q         = mem[rd_total % DEPTH];
    assign rdempty   = (occ == 0);
    assign wrfull    = (occ >= DEPTH);
    assign rdfull    = (occ >= DEPTH);
    assign wrempty   = (occ == 0);
    assign rdusedw   = occ[lpm_widthu-1:0];
    assign wrusedw   = occ[lpm_widthu-1:0];
    assign eccstatus = 2'b00;
endmodule
`default_nettype wire
