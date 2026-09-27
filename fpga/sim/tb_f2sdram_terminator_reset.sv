// tb_f2sdram_terminator_reset.sv — core-change DDR3 port wedge (2026-09-26).
//
// Models what happens on the f2sdram port when Main asserts the core reset while
// the core is in the middle of a DDR3 write burst (the "runaway at teardown"
// freeze in docs/superpowers/findings/2026-09-26-solarus-core-reload-freeze.md).
//
// Topology, as built by sys_top/sysmem:
//   master (core) --RESET, async--> drops write the cycle reset arrives
//   f2sdram_safe_terminator sees rst_req_sync = RESET double-registered (2 cycles late)
//   port model = an Avalon-MM burst slave with random waitrequest
//
// The port model tracks write-burst beats exactly as Avalon defines them
// (write & ~waitrequest). PASS = after the reset has been held long enough, no
// write burst is left partially delivered — a partial burst is what leaves the
// HPS port waiting forever for data (the wedge that survives core reloads).
//
// Sweep: reset-assert cycle x master gap rate x port waitrequest rate.
`timescale 1ns/1ps
`default_nettype none
module tb_f2sdram_terminator_reset;
    localparam DW = 64, BW = 8, AW = 32 - $clog2(DW/8);
    localparam [7:0] BURST = 8'd80;

    reg clk = 0;
    always #5 clk = ~clk;

    reg  core_rst = 1'b1;
    reg  rst_s0 = 1'b1, rst_s1 = 1'b1;           // sysmem.sv ram1_reset_0/1
    always @(posedge clk) begin rst_s0 <= core_rst; rst_s1 <= rst_s0; end

    // ---- master (core-side) -------------------------------------------------
    reg  [BW-1:0] m_bc;
    reg  [AW-1:0] m_addr;
    reg           m_wr, m_rd;
    reg  [DW-1:0] m_wdata;
    reg  [7:0]    m_be;
    wire          m_wait;
    wire [DW-1:0] m_rdata;
    wire          m_rvalid;

    // ---- port (HPS-side) ----------------------------------------------------
    wire [BW-1:0] p_bc;
    wire [AW-1:0] p_addr;
    wire          p_wr, p_rd;
    wire [DW-1:0] p_wdata;
    wire [7:0]    p_be;
    reg           p_wait;
    reg  [DW-1:0] p_rdata = 0;
    reg           p_rvalid = 0;

    f2sdram_safe_terminator #(DW, BW) dut (
        .clk(clk), .rst_req_sync(rst_s1),
        .waitrequest_master(p_wait), .burstcount_master(p_bc), .address_master(p_addr),
        .readdata_master(p_rdata), .readdatavalid_master(p_rvalid), .read_master(p_rd),
        .writedata_master(p_wdata), .byteenable_master(p_be), .write_master(p_wr),
        .waitrequest_slave(m_wait), .burstcount_slave(m_bc), .address_slave(m_addr),
        .readdata_slave(m_rdata), .readdatavalid_slave(m_rvalid), .read_slave(m_rd),
        .writedata_slave(m_wdata), .byteenable_slave(m_be), .write_slave(m_wr)
    );

    // xorshift for waitrequest / gaps
    reg [31:0] rng = 32'h1234_5678;
    always @(posedge clk) rng <= rng ^ (rng << 13) ^ (rng >> 17) ^ (rng << 5);
    integer wait_pct = 0, gap_pct = 0;
    wire [6:0] r_wait = rng[6:0] % 100;
    wire [6:0] r_gap  = rng[14:8] % 100;
    always @(negedge clk) p_wait <= (r_wait < wait_pct);

    // master: back-to-back BURST-beat write bursts; optional gaps between beats
    // (write deasserted, legal on Avalon-MM). Drops everything on core_rst — like
    // every DDR master in the Solarus core, which all sit on RESET.
    reg  [7:0] m_left;       // beats still to send in the current burst (0 = none)
    always @(posedge clk) begin
        if (core_rst) begin
            m_wr <= 0; m_rd <= 0; m_left <= 0; m_bc <= BURST; m_addr <= 0;
            m_wdata <= 0; m_be <= 8'hFF;
        end else begin
            if (m_wr && !m_wait) begin               // beat accepted
                m_wdata <= m_wdata + 1;
                if (m_left == 8'd1) begin m_wr <= 0; m_left <= 0; m_addr <= m_addr + BURST; end
                else begin
                    m_left <= m_left - 1;
                    m_wr   <= !(r_gap < gap_pct);    // maybe insert a gap
                end
            end else if (!m_wr && m_left != 0) begin
                m_wr <= !(r_gap < gap_pct);           // resume after a gap
            end else if (!m_wr && m_left == 0) begin
                m_wr <= 1; m_left <= BURST; m_bc <= BURST;   // next burst
            end
        end
    end

    // port model: Avalon burst accounting
    reg        in_burst;
    reg [7:0]  rem;
    reg        violation;
    always @(posedge clk) begin
        if (p_wr && !p_wait) begin
            if (!in_burst) begin
                if (p_bc > 8'd1) begin in_burst <= 1; rem <= p_bc - 8'd1; end
            end else begin
                if (rem == 8'd1) in_burst <= 0;
                rem <= rem - 8'd1;
            end
        end
        if (p_rd && !p_wait && in_burst) violation <= 1;   // read inside a write burst
    end

    integer t, fails, runs, total_fails, wi, gi;
    integer waits [0:2];
    integer gaps  [0:1];
    initial begin
        waits[0] = 0; waits[1] = 30; waits[2] = 60;
        gaps[0]  = 0; gaps[1]  = 25;
        total_fails = 0;
        for (wi = 0; wi < 3; wi = wi + 1) for (gi = 0; gi < 2; gi = gi + 1) begin
            wait_pct = waits[wi]; gap_pct = gaps[gi]; fails = 0; runs = 0;
            for (t = 20; t < 420; t = t + 1) begin
                // fresh state: hold reset, clear the port model
                core_rst = 1; in_burst = 0; rem = 0; violation = 0;
                repeat (40) @(posedge clk);
                core_rst = 0;                        // run: terminator must first see a deassert
                repeat (t) @(posedge clk);
                core_rst = 1;                        // Main: fpga_core_reset(1)
                repeat (400) @(posedge clk);         // reset held (ms in reality)
                runs = runs + 1;
                if (in_burst || violation) fails = fails + 1;
            end
            $display("wait=%0d%% gap=%0d%%: %0d/%0d resets left the port mid-burst",
                     wait_pct, gap_pct, fails, runs);
            total_fails = total_fails + fails;
        end
        if (total_fails == 0) $display("PASS");
        else                  $display("FAIL (%0d)", total_fails);
        $finish;
    end
endmodule
`default_nettype wire
