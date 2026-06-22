`timescale 1ns/1ps
`default_nettype none
`include "../rtl/vram_defs.vh"
// tb_vram_demux.sv — updated for P_DST cache ok/wdsn protocol (Task 3).
//
// SDRAM model: on sd_rd|sd_wr rising, wait SDRAM_LAT cycles, assert sd_ok for
// one cycle. Reads return local sdmem. Writes honor sd_wdsn (active-low byte
// select) into sdmem, stored as 8-byte (64-bit) qwords indexed by byte_addr>>3.
//
// blt_be -> sd_wdsn mapping (active-low): sd_wdsn = ~blt_be (full write = 8'h00).
// A 16-bit pixel lane spans 2 byte lanes: lane i -> bytes [2i+1:2i].
module tb_vram_demux;
  reg clk=0; always #5 clk=~clk;
  reg reset=1;

  // blitter side
  reg  [31:0] blt_addr=0; reg blt_rd=0, blt_wr=0; reg [63:0] blt_din=0; reg [7:0] blt_be=0;
  reg  [7:0]  blt_burstcnt=8'd1;   // SDRAM read beats (1 = legacy single-beat)
  wire [63:0] blt_dout; wire blt_dready; wire blt_busy;
  // DDR side (behavioral)
  wire [28:0] ddr_addr; wire ddr_rd, ddr_wr; wire [63:0] ddr_din; wire [7:0] ddr_be;
  reg  [63:0] ddr_dout=64'hD00D_D00D_D00D_D00D; reg ddr_dready=0; reg ddr_busy=0;
  // SDRAM side — P_DST cache ok interface
  wire [26:0] sd_addr;
  wire        sd_rd;
  wire        sd_wr;
  wire [63:0] sd_din;     // 64-bit write data
  wire [ 7:0] sd_wdsn;   // active-low byte-select (0=enable, 1=mask); full=8'h00
  reg  [63:0] sd_dout=64'hBEEF_BEEF_BEEF_BEEF;
  reg         sd_ok=0;    // single-cycle accept/return pulse

  // sdmem: byte-addressed, stores 64-bit qwords indexed by addr>>3.
  // Cover the full SDRAM FB address space (both FB0 and FB1).
  // 0x0440000 (FB1_BASE) + 19200*8 = ~0x4DC800; 8M qword entries (2^23) is safe.
  reg [63:0] sdmem_q [0:1<<20];   // qword array indexed by byte_addr>>3

  // Helper: read a single byte from the qword array.
  // sdmem_q[addr>>3] holds the qword; byte index within qword = addr[2:0].
  function automatic [7:0] sdmem_byte;
    input [26:0] addr;
    reg [63:0] qw;
    begin
      qw = sdmem_q[addr >> 3];
      sdmem_byte = qw[addr[2:0]*8 +: 8];
    end
  endfunction

  // Helper: read a 16-bit word (little-endian).
  function automatic [15:0] sdmem_word;
    input [26:0] byte_addr;
    begin
      sdmem_word = {sdmem_byte(byte_addr+1), sdmem_byte(byte_addr)};
    end
  endfunction

  vram_demux dut(.clk(clk),.reset(reset),
    .blt_addr(blt_addr),.blt_rd(blt_rd),.blt_wr(blt_wr),.blt_din(blt_din),.blt_be(blt_be),
    .blt_burstcnt(blt_burstcnt),
    .blt_dout(blt_dout),.blt_dout_ready(blt_dready),.blt_busy(blt_busy),
    .ddr_addr(ddr_addr),.ddr_rd(ddr_rd),.ddr_wr(ddr_wr),.ddr_din(ddr_din),.ddr_be(ddr_be),
    .ddr_dout(ddr_dout),.ddr_dout_ready(ddr_dready),.ddr_busy(ddr_busy),
    .sd_addr(sd_addr),.sd_rd(sd_rd),.sd_wr(sd_wr),
    .sd_din(sd_din),.sd_wdsn(sd_wdsn),
    .sd_dout(sd_dout),.sd_ok(sd_ok));

  integer errs=0;

  // -------------------------------------------------------------------------
  // Behavioral SDRAM model: P_DST cache ok protocol.
  //   On sd_rd|sd_wr rising edge, respond after SDRAM_LAT cycles with sd_ok=1
  //   for exactly one cycle. Reads return sdmem_q. Writes honor sd_wdsn.
  //   Exactly one cycle of sd_ok per request.
  // -------------------------------------------------------------------------
  localparam integer SDRAM_LAT = 3;  // fixed latency cycles

  // Detect rising edge of sd_rd or sd_wr (request start).
  reg sd_rd_d=0, sd_wr_d=0;
  always @(posedge clk) begin sd_rd_d <= sd_rd; sd_wr_d <= sd_wr; end
  wire sd_req_rise = (sd_rd & ~sd_rd_d) | (sd_wr & ~sd_wr_d);

  // Latency counter: count down from SDRAM_LAT when a request arrives.
  reg [3:0]  lat_cnt=0;
  reg        lat_run=0;
  reg [26:0] lat_addr=0;
  reg        lat_is_wr=0;
  reg [63:0] lat_din_r=0;
  reg [ 7:0] lat_wdsn_r=8'hFF;

  always @(posedge clk) begin
    sd_ok <= 1'b0;
    if (reset) begin
      lat_run <= 1'b0; lat_cnt <= 0;
    end else if (sd_req_rise && !lat_run) begin
      // Latch the request on the rising edge.
      lat_run    <= 1'b1;
      lat_cnt    <= SDRAM_LAT - 1;
      lat_addr   <= sd_addr;
      lat_is_wr  <= sd_wr;
      lat_din_r  <= sd_din;
      lat_wdsn_r <= sd_wdsn;
    end else if (lat_run) begin
      if (lat_cnt == 0) begin
        // Accept cycle: assert ok, commit write or present read data.
        sd_ok    <= 1'b1;
        lat_run  <= 1'b0;
        if (lat_is_wr) begin
          // Write: honor wdsn (active-low) byte-selects into qword array.
          // We do a read-modify-write: enabled bytes (wdsn=0) get written.
          begin : do_write
            integer i;
            reg [63:0] cur;
            cur = sdmem_q[lat_addr >> 3];
            for (i = 0; i < 8; i = i + 1) begin
              if (!lat_wdsn_r[i])
                cur[i*8 +: 8] = lat_din_r[i*8 +: 8];
            end
            sdmem_q[lat_addr >> 3] = cur;
          end
        end else begin
          // Read: drive sd_dout from the qword array.
          sd_dout <= sdmem_q[lat_addr >> 3];
        end
      end else begin
        lat_cnt <= lat_cnt - 1;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Beat / issue monitors (unchanged semantics, new signals).
  // -------------------------------------------------------------------------
  // dready_total: every blt_dout_ready beat the demux returns.
  integer dready_total=0;
  always @(posedge clk) if (blt_dready) dready_total = dready_total + 1;

  // rd_issued[]: SDRAM byte address on each sd_rd rising edge.
  integer rd_issue_n=0; reg [26:0] rd_issued [0:31];
  always @(posedge clk) if (sd_rd & ~sd_rd_d) begin
    if (rd_issue_n < 32) rd_issued[rd_issue_n] = sd_addr;
    rd_issue_n = rd_issue_n + 1;
  end

  // wr_issued_n: count of sd_wr rising edges (one per request).
  integer wr_issued_n=0;
  always @(posedge clk) if (sd_wr & ~sd_wr_d) wr_issued_n = wr_issued_n + 1;

  // Registered dout capture: latches blt_dout whenever blt_dout_ready pulses.
  reg [63:0] cap_dout=64'hX;
  reg        cap_ready=0;
  always @(posedge clk) begin
    cap_ready <= blt_dready;
    if (blt_dready) cap_dout <= blt_dout;
  end

  // Helper task: wait until blt_busy deasserts (with timeout).
  task wait_idle;
    integer i;
    begin
      for (i = 0; i < 50 && blt_busy; i = i + 1) @(posedge clk);
      if (blt_busy) begin $display("FAIL: blt_busy stuck"); errs = errs + 1; end
    end
  endtask

  // Helper task: wait for sd_ok (up to N cycles).
  task wait_ok;
    input integer maxwait;
    integer i;
    begin
      for (i = 0; i < maxwait && !sd_ok; i = i + 1) @(posedge clk);
      if (!sd_ok) begin $display("FAIL: sd_ok never asserted"); errs = errs + 1; end
    end
  endtask

  initial begin
    repeat(4) @(posedge clk); reset=0; @(posedge clk);

    // -----------------------------------------------------------------------
    // 1) NON-FB write routes to DDR (RING region), NOT SDRAM
    // -----------------------------------------------------------------------
    blt_addr=32'h07600008; blt_wr=1; blt_din=64'h1; blt_be=8'hFF; @(posedge clk);
    if (!ddr_wr || sd_wr || sd_rd) begin $display("FAIL T1: ring write not on DDR"); errs=errs+1; end
    blt_wr=0; @(posedge clk);

    // -----------------------------------------------------------------------
    // 2) FB0 full-qword write: sd_wr=1, sd_addr=SDRAM_FB0_BASE, sd_wdsn=8'h00.
    //    ONE request issued; wait sd_ok; blt_busy clears.
    // -----------------------------------------------------------------------
    begin : t2
      integer wi0;
      wi0 = wr_issued_n;
      @(negedge clk);
      blt_addr={3'd0,`FB_DDR0_QW};               // first qword of FB0
      blt_wr=1; blt_din=64'hAAAA_BBBB_CCCC_DDDD; blt_be=8'hFF;
      @(posedge clk);  // FSM sees request, issues sd_wr
      // Check request: sd_wr asserted, address remapped, wdsn=8'h00 (full write)
      if (!sd_wr || ddr_wr)
        begin $display("FAIL T2: FB full-qword not an sd_wr request"); errs=errs+1; end
      if (sd_addr !== `SDRAM_FB0_BASE)
        begin $display("FAIL T2: FB0 base addr remap %h", sd_addr); errs=errs+1; end
      if (sd_wdsn !== 8'h00)
        begin $display("FAIL T2: wdsn for full write should be 8'h00, got %h", sd_wdsn); errs=errs+1; end
      // Wait for ok and return to idle.
      wait_ok(20);
      @(posedge clk); // let FSM process ok
      blt_wr=0;
      wait_idle;
      // Verify qword was written to sdmem.
      if (sdmem_q[`SDRAM_FB0_BASE >> 3] !== 64'hAAAA_BBBB_CCCC_DDDD)
        begin $display("FAIL T2: qword not written to sdmem (got %h)", sdmem_q[`SDRAM_FB0_BASE>>3]); errs=errs+1; end
      if ((wr_issued_n - wi0) !== 1)
        begin $display("FAIL T2: expected 1 sd_wr request, got %0d", wr_issued_n - wi0); errs=errs+1; end
    end

    // -----------------------------------------------------------------------
    // 3) FB1 partial write: lane1 only (blt_be=8'h0C, bytes 2-3).
    //    ONE masked sd_wr with wdsn=~8'h0C=8'hF3 (bytes 2,3 enabled; rest masked).
    //    Verifies the byte-lane mapping: lane1 -> bytes [3:2] -> sdmem bytes 2,3.
    // -----------------------------------------------------------------------
    begin : t3
      integer wi0;
      reg [63:0] prior;
      wi0 = wr_issued_n;
      // Pre-fill qword 5 of FB1 so we can verify partial write.
      sdmem_q[(`SDRAM_FB1_BASE + 5*8) >> 3] = 64'hFF_FF_FF_FF_FF_FF_FF_FF;
      @(negedge clk);
      blt_addr={3'd0,`FB_DDR1_QW + 29'd5};       // qword 5 of FB1
      blt_wr=1; blt_din=64'h0000_0000_1234_0000; blt_be=8'h0C; // lane1 (bytes 2-3)
      @(posedge clk);  // FSM issues sd_wr
      if (!sd_wr)
        begin $display("FAIL T3: no sd_wr for partial write"); errs=errs+1; end
      if (sd_wdsn !== ~8'h0C)
        begin $display("FAIL T3: wdsn wrong (got %h, want %h)", sd_wdsn, ~8'h0C); errs=errs+1; end
      wait_ok(20);
      @(posedge clk);
      blt_wr=0;
      wait_idle;
      // Verify bytes 2-3 written with 16'h1234 (little-endian: byte2=0x34, byte3=0x12).
      if (sdmem_word(`SDRAM_FB1_BASE + 5*8 + 2) !== 16'h1234)
        begin $display("FAIL T3: lane1 word wrong (got %h, want 1234)", sdmem_word(`SDRAM_FB1_BASE + 5*8 + 2)); errs=errs+1; end
      // Bytes 0,1,4,5,6,7 must be unchanged (0xFF).
      if (sdmem_byte(`SDRAM_FB1_BASE + 5*8 + 0) !== 8'hFF)
        begin $display("FAIL T3: byte0 wrongly written"); errs=errs+1; end
      if (sdmem_byte(`SDRAM_FB1_BASE + 5*8 + 1) !== 8'hFF)
        begin $display("FAIL T3: byte1 wrongly written"); errs=errs+1; end
      if ((wr_issued_n - wi0) !== 1)
        begin $display("FAIL T3: expected 1 sd_wr (masked), got %0d", wr_issued_n - wi0); errs=errs+1; end
    end

    // -----------------------------------------------------------------------
    // 4) FB read routes to SDRAM via sd_rd; dout captured from sd_dout.
    //    rd_on_sdram latch gates blt_dout_ready to sd_ok.
    // -----------------------------------------------------------------------
    begin : t4
      sdmem_q[(`SDRAM_FB0_BASE + 10*8) >> 3] = 64'hCAFE_CAFE_CAFE_CAFE;
      blt_addr={3'd0,`FB_DDR0_QW + 29'd10};
      @(negedge clk); blt_rd=1;    // set at negedge: FSM sees blt_rd=1 at next posedge
      @(posedge clk);               // posedge 1: FSM S_IDLE→S_RDLAT; ros=1
      @(posedge clk); blt_rd=0;    // posedge 2: FSM in S_RDLAT; blt_rd cleared (ros latched)
      // Verify no spurious blt_dout_ready before sd_ok.
      @(posedge clk);
      if (blt_dready) begin $display("FAIL T4: FB read blt_dout_ready spurious"); errs=errs+1; end
      // Wait for the cache model to return sd_ok (blt_dout_ready=sd_ok pulses
      // that cycle; cap_ready is its registered copy one cycle later).
      wait_ok(30);
      @(posedge clk); // cap_ready registered the cycle after the sd_ok pulse
      if (!cap_ready)
        begin $display("FAIL T4: FB read cap_ready not asserted"); errs=errs+1; end
      if (cap_dout !== 64'hCAFE_CAFE_CAFE_CAFE)
        begin $display("FAIL T4: FB read dout not from SDRAM (got %h)", cap_dout); errs=errs+1; end
      wait_idle;
    end

    // -----------------------------------------------------------------------
    // 5) NON-FB read routes to DDR; dout returns from ddr_dout.
    //    rd_on_sdram=0 so blt_dout = ddr_dout, not sd_dout. SDRAM data must not leak.
    // -----------------------------------------------------------------------
    blt_addr=32'h07600008;
    @(negedge clk); ddr_dready=1;
    @(posedge clk);                  // posedge 1: blt_dready=1; cap latches ddr_dout
    @(posedge clk); ddr_dready=0;   // posedge 2: cap_ready=1
    if (!cap_ready)
      begin $display("FAIL T5: DDR read cap_ready not asserted"); errs=errs+1; end
    if (cap_dout !== 64'hD00D_D00D_D00D_D00D)
      begin $display("FAIL T5: ring read dout not from DDR (got %h)", cap_dout); errs=errs+1; end
    if (cap_dout === 64'hCAFE_CAFE_CAFE_CAFE)
      begin $display("FAIL T5: DDR read leaked SDRAM dout"); errs=errs+1; end
    @(posedge clk);

    // -----------------------------------------------------------------------
    // 6) Full-qword write: exactly ONE sd_wr request is issued (no re-fire).
    //    The FSM holds sd_wr until sd_ok, then drops it.
    // -----------------------------------------------------------------------
    begin : t6
      integer wi0;
      wi0 = wr_issued_n;
      @(negedge clk);
      blt_addr={3'd0,`FB_DDR0_QW + 29'd1};
      blt_wr=1; blt_din=64'hDEAD_BEEF_DEAD_BEEF; blt_be=8'hFF;
      @(posedge clk);      // FSM issues sd_wr
      if (!blt_busy)
        begin $display("FAIL T6: blt_busy not held while waiting sd_ok"); errs=errs+1; end
      // Let the model generate sd_ok.
      wait_ok(20);
      @(posedge clk);
      blt_wr=0;
      wait_idle;
      if ((wr_issued_n - wi0) !== 1)
        begin $display("FAIL T6: expected exactly 1 sd_wr, got %0d", wr_issued_n - wi0); errs=errs+1; end
    end

    // -----------------------------------------------------------------------
    // 7) Partial 2-lane write: lanes 0+2 (blt_be=8'h33).
    //    ONE masked sd_wr request (wdsn=~8'h33=8'hCC).
    //    Disabled lanes 1,3 must NOT be written.
    //
    //    qword 30 of FB0: SDRAM_FB0_BASE + 30*8 = 0x4000F0
    //    blt_din = 64'hDEAD_CD56_BEEF_AB12
    //    blt_be  = 8'h33 -> lane0(bytes 0-1)+lane2(bytes 4-5) active
    //    wdsn    = ~8'h33 = 8'hCC (bytes 0,1,4,5 enabled; 2,3,6,7 masked)
    // -----------------------------------------------------------------------
    begin : t7
      integer wi0;
      wi0 = wr_issued_n;
      // Pre-fill qword 30 of FB0 with all 0xFF to detect spurious writes.
      sdmem_q[(`SDRAM_FB0_BASE + 30*8) >> 3] = 64'hFF_FF_FF_FF_FF_FF_FF_FF;
      @(negedge clk);
      blt_addr = {3'd0, `FB_DDR0_QW + 29'd30};
      blt_wr   = 1;
      blt_din  = 64'hDEAD_CD56_BEEF_AB12;
      blt_be   = 8'h33;   // lane_active: lanes 0,2
      @(posedge clk);    // FSM issues one masked sd_wr
      if (!sd_wr)
        begin $display("FAIL T7: no sd_wr for partial write"); errs=errs+1; end
      if (sd_wdsn !== ~8'h33)
        begin $display("FAIL T7: wdsn wrong (got %h, want %h)", sd_wdsn, ~8'h33); errs=errs+1; end
      wait_ok(20);
      @(posedge clk);
      blt_wr = 0;
      wait_idle;
      if ((wr_issued_n - wi0) !== 1)
        begin $display("FAIL T7: expected 1 masked sd_wr, got %0d", wr_issued_n - wi0); errs=errs+1; end
      // Check lane0 (bytes 0-1 = AB12, LE: byte0=0x12, byte1=0xAB).
      if (sdmem_word(`SDRAM_FB0_BASE + 30*8 + 0) !== 16'hAB12)
        begin $display("FAIL T7: lane0 word wrong (got %h, want AB12)", sdmem_word(`SDRAM_FB0_BASE + 30*8)); errs=errs+1; end
      // Check lane2 (bytes 4-5 = CD56, LE: byte4=0x56, byte5=0xCD).
      if (sdmem_word(`SDRAM_FB0_BASE + 30*8 + 4) !== 16'hCD56)
        begin $display("FAIL T7: lane2 word wrong (got %h, want CD56)", sdmem_word(`SDRAM_FB0_BASE + 30*8 + 4)); errs=errs+1; end
      // Check disabled lanes 1,3 (bytes 2-3, 6-7) must remain 0xFF.
      if (sdmem_byte(`SDRAM_FB0_BASE + 30*8 + 2) !== 8'hFF)
        begin $display("FAIL T7: disabled lane1 byte2 wrongly written"); errs=errs+1; end
      if (sdmem_byte(`SDRAM_FB0_BASE + 30*8 + 3) !== 8'hFF)
        begin $display("FAIL T7: disabled lane1 byte3 wrongly written"); errs=errs+1; end
      if (sdmem_byte(`SDRAM_FB0_BASE + 30*8 + 6) !== 8'hFF)
        begin $display("FAIL T7: disabled lane3 byte6 wrongly written"); errs=errs+1; end
    end

    // -----------------------------------------------------------------------
    // 8) Partial 3-lane write: lanes 0+1+3 (blt_be=8'hCF).
    //    ONE masked sd_wr (wdsn=~8'hCF=8'h30). Lane2 must NOT be written.
    //
    //    qword 40 of FB0: SDRAM_FB0_BASE + 40*8 = 0x400140
    // -----------------------------------------------------------------------
    begin : t8
      integer wi0;
      wi0 = wr_issued_n;
      sdmem_q[(`SDRAM_FB0_BASE + 40*8) >> 3] = 64'hFF_FF_FF_FF_FF_FF_FF_FF;
      @(negedge clk);
      blt_addr = {3'd0, `FB_DDR0_QW + 29'd40};
      blt_wr   = 1;
      blt_din  = 64'h4444_CAFE_2222_1111; // lane0=1111, lane1=2222, lane2=CAFE, lane3=4444
      blt_be   = 8'hCF; // lanes 0,1,3 active
      @(posedge clk);
      if (!sd_wr)
        begin $display("FAIL T8: no sd_wr for 3-lane partial write"); errs=errs+1; end
      if (sd_wdsn !== ~8'hCF)
        begin $display("FAIL T8: wdsn wrong (got %h, want %h)", sd_wdsn, ~8'hCF); errs=errs+1; end
      wait_ok(20);
      @(posedge clk);
      blt_wr = 0;
      wait_idle;
      if ((wr_issued_n - wi0) !== 1)
        begin $display("FAIL T8: expected 1 masked sd_wr, got %0d", wr_issued_n - wi0); errs=errs+1; end
      // Lane0 (bytes 0-1).
      if (sdmem_word(`SDRAM_FB0_BASE + 40*8 + 0) !== 16'h1111)
        begin $display("FAIL T8: lane0 wrong"); errs=errs+1; end
      // Lane1 (bytes 2-3).
      if (sdmem_word(`SDRAM_FB0_BASE + 40*8 + 2) !== 16'h2222)
        begin $display("FAIL T8: lane1 wrong"); errs=errs+1; end
      // Lane3 (bytes 6-7).
      if (sdmem_word(`SDRAM_FB0_BASE + 40*8 + 6) !== 16'h4444)
        begin $display("FAIL T8: lane3 wrong"); errs=errs+1; end
      // Lane2 (bytes 4-5) must remain 0xFF.
      if (sdmem_byte(`SDRAM_FB0_BASE + 40*8 + 4) !== 8'hFF)
        begin $display("FAIL T8: disabled lane2 byte4 wrongly written"); errs=errs+1; end
    end

    // -----------------------------------------------------------------------
    // 9) N-beat FB burst READ: burstcnt=4, one sd_rd per beat, addresses walk +8.
    //    The demux issues sd_rd, waits sd_ok, captures dout, advances address.
    //    Exactly 4 blt_dout_ready beats returned in order.
    // -----------------------------------------------------------------------
    begin : burst_read_test
      integer b; integer wc; integer e0; integer d0; integer ri0;
      reg [26:0] base_byte;
      e0           = errs;
      d0           = dready_total;
      ri0          = rd_issue_n;
      base_byte    = `SDRAM_FB0_BASE;
      // Pre-fill 4 qwords with known data.
      for (b = 0; b < 4; b = b + 1)
        sdmem_q[(base_byte + b*8) >> 3] = 64'hA0A0_0000_0000_0000 + b;
      blt_burstcnt = 8'd4;
      @(negedge clk);
      blt_addr = {3'd0, `FB_DDR0_QW};        // start qword of FB0
      blt_rd   = 1'b1;
      @(posedge clk);                         // S_IDLE sets up the burst -> S_RDLAT
      @(negedge clk); blt_rd = 1'b0;          // comp_burst drops mem_rd after accept
      // The cache model auto-generates sd_ok after SDRAM_LAT cycles for each beat.
      // Wait for all 4 beats (timeout generous: 4 * (SDRAM_LAT + 5) cycles).
      wait_idle;                               // FSM must be back in S_IDLE
      // Exactly 4 beats returned.
      if ((dready_total - d0) !== 4) begin
        $display("FAIL T9: returned %0d/4 beats", dready_total - d0); errs = errs + 1;
      end
      // 4 reads issued, addresses walking +8 bytes from the FB0 base.
      if ((rd_issue_n - ri0) !== 4) begin
        $display("FAIL T9: issued %0d/4 sd_rd reads", rd_issue_n - ri0); errs = errs + 1;
      end else for (b = 0; b < 4; b = b + 1)
        if (rd_issued[ri0 + b] !== (base_byte + b*8)) begin
          $display("FAIL T9: beat %0d addr=%h exp=%h", b, rd_issued[ri0+b], base_byte + b*8);
          errs = errs + 1;
        end
      // Last beat's data must have propagated through the registered capture.
      if (cap_dout !== (64'hA0A0_0000_0000_0000 + 3)) begin
        $display("FAIL T9: last beat data cap_dout=%h", cap_dout); errs = errs + 1;
      end
      if (errs == e0) $display("Test 9 burst-read N=4: PASS");
      blt_burstcnt = 8'd1;
    end

    // -----------------------------------------------------------------------
    // 10) DDR cross-bus isolation during SDRAM read: a spurious ddr_dready
    //     must NOT assert blt_dout_ready when rd_on_sdram=1.
    // -----------------------------------------------------------------------
    begin : t10
      sdmem_q[(`SDRAM_FB0_BASE + 20*8) >> 3] = 64'h5555_AAAA_5555_AAAA;
      ddr_dout=64'hD00D_D00D_D00D_D00D;
      @(posedge clk);
      if (cap_ready) begin $display("FAIL T10: cap_ready not 0 at test start"); errs=errs+1; end
      blt_addr={3'd0,`FB_DDR0_QW + 29'd20};
      @(negedge clk); blt_rd=1;
      @(posedge clk);               // FSM: S_IDLE→S_RDLAT; ros=1
      @(posedge clk); blt_rd=0;    // blt_rd cleared; ros latched
      // Spuriously pulse ddr_dready during SDRAM latency.
      @(negedge clk); ddr_dready=1;
      @(posedge clk);               // blt_dready must be 0 (ros gates DDR dready)
      @(posedge clk); ddr_dready=0;
      if (cap_ready)
        begin $display("FAIL T10: DDR dready leaked during in-flight SDRAM read"); errs=errs+1; end
      // Wait for the SDRAM model to return sd_ok.
      wait_ok(30);
      @(posedge clk); // cap_ready registered the cycle after the sd_ok pulse
      if (!cap_ready)
        begin $display("FAIL T10: FB read cap_ready not asserted after sd_ok"); errs=errs+1; end
      if (cap_dout !== 64'h5555_AAAA_5555_AAAA)
        begin $display("FAIL T10: FB read dout wrong (got %h)", cap_dout); errs=errs+1; end
      wait_idle;
    end

    // -----------------------------------------------------------------------
    // 11) Back-to-back full-qword writes: write B presented while write A
    //     is in-flight (FSM waiting sd_ok). B must not be dropped.
    //     This tests the new_wr_pending hold (same logic, new ok protocol).
    // -----------------------------------------------------------------------
    begin : bb_full_qword
      integer e0;
      e0 = errs;
      @(negedge clk);
      blt_addr = {3'd0, `FB_DDR0_QW + 29'd60}; blt_din = 64'hA1A1A1A1A1A1A1A1;
      blt_be = 8'hFF; blt_wr = 1'b1;
      @(posedge clk);                // FSM issues sd_wr for A -> S_WOKWAIT
      // Present B while A is in-flight (different qword, blt_wr still held).
      blt_addr = {3'd0, `FB_DDR0_QW + 29'd61}; blt_din = 64'hB2B2B2B2B2B2B2B2;
      // Wait for A to complete (sd_ok arrives from model).
      wait_ok(20);
      @(posedge clk);
      // Now B should be accepted; wait for it to complete.
      while (blt_busy) @(posedge clk);
      @(negedge clk); blt_wr = 1'b0;
      wait_idle;
      if (sdmem_q[(`SDRAM_FB0_BASE + 60*8) >> 3] !== 64'hA1A1A1A1A1A1A1A1) begin
        $display("FAIL T11: write A lost"); errs = errs + 1; end
      if (sdmem_q[(`SDRAM_FB0_BASE + 61*8) >> 3] !== 64'hB2B2B2B2B2B2B2B2) begin
        $display("FAIL T11: write B DROPPED (back-to-back bug)"); errs = errs + 1; end
      else if (errs == e0) $display("Test 11 back-to-back full-qword cadence: PASS");
    end

    // -----------------------------------------------------------------------
    // 12) Partial write round-trip: blt_be=8'hF0 -> lanes 2,3 active.
    //     ONE masked sd_wr (wdsn=~8'hF0=8'h0F).
    //     Verifies qword is written to sdmem correctly.
    // -----------------------------------------------------------------------
    begin : partial_hold
      integer wi0;
      wi0 = wr_issued_n;
      sdmem_q[(`SDRAM_FB0_BASE + 70*8) >> 3] = 64'hFF_FF_FF_FF_FF_FF_FF_FF;
      @(negedge clk);
      blt_addr = {3'd0, `FB_DDR0_QW + 29'd70}; blt_din = 64'h7777_8888_9999_AAAA;
      blt_be = 8'hF0; blt_wr = 1'b1;
      @(posedge clk);
      if (sd_wdsn !== ~8'hF0)
        begin $display("FAIL T12: wdsn wrong (got %h, want %h)", sd_wdsn, ~8'hF0); errs=errs+1; end
      wait_ok(20);
      @(posedge clk);
      blt_wr = 1'b0;
      wait_idle;
      // Lane2 (bytes 4-5) = 8888 (LE).
      if (sdmem_word(`SDRAM_FB0_BASE + 70*8 + 4) !== 16'h8888)
        begin $display("FAIL T12: lane2 wrong/lost"); errs=errs+1; end
      // Lane3 (bytes 6-7) = 7777 (LE).
      if (sdmem_word(`SDRAM_FB0_BASE + 70*8 + 6) !== 16'h7777)
        begin $display("FAIL T12: lane3 wrong"); errs=errs+1; end
      // Lanes 0,1 (bytes 0-3) must remain 0xFF.
      if (sdmem_byte(`SDRAM_FB0_BASE + 70*8 + 0) !== 8'hFF)
        begin $display("FAIL T12: lane0 byte wrongly written"); errs=errs+1; end
      if ((wr_issued_n - wi0) !== 1)
        begin $display("FAIL T12: expected 1 sd_wr, got %0d", wr_issued_n - wi0); errs=errs+1; end
      else $display("Test 12 partial-write hold: PASS");
      blt_be = 8'h00;
    end

    if (errs==0) $display("RESULT: PASS"); else $display("RESULT: FAIL (%0d)", errs);
    $finish;
  end
endmodule
`default_nettype wire
