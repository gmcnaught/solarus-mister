// VENDORED from github.com/gmcnaught/mister-fpga-blitter (rtl/blitter_top.sv)
// HW addresses come from blitter_defs.vh (this dir). Do not edit here; edit upstream + re-copy.
//============================================================================
//  blitter_top.sv — MiSTer fabric 2D blitter: functional spike (#003)
//
//  Walks a DDR command ring (until END / cmd_count), composites into a
//  framebuffer in DDR per the host<->fabric contract (docs/blitter-protocol.md),
//  then writes the video control word as a DROP-IN PRODUCER for the existing
//  scanout reader. Verified bit-exact in simulation against the C reference
//  model (refmodel/blitter_ref.c) over the full v1 command set.
//
//  SCOPE NOTE: this spike uses a single Avalon-MM master with simple per-pixel
//  reads/writes (byte-enable lane writes) — deliberately FUNCTIONAL, not yet
//  bandwidth-optimal. The on-chip line/tile buffer + burst-DMA refinement (the
//  CV1000 pattern, see docs/) is the #004/#005 perf work and does not change
//  these command/handshake/pixel semantics.
//
//  Command word on-wire layout (32 bytes = 4 qwords, little-endian):
//    u32[0] = opcode[7:0] | blend[15:8] | format[23:16] | flags[31:24]
//    u32[1] = src_off[31:0]
//    u32[2] = src_stride[15:0] | src_x[31:16]
//    u32[3] = w[15:0] | h[31:16]
//    u32[4] = src_y[15:0] | resv
//    u32[5] = dst_x[15:0] | dst_y[31:16]   (signed16)
//    u32[6] = colorkey[15:0] | alpha[23:16] | priority[31:24]
//    u32[7] = color[15:0] | resv
//    qw_k = {u32[2k+1], u32[2k]}
//
//  Copyright (C) 2026 — GPL-3.0
//============================================================================
`default_nettype none
`include "blitter_defs.vh"

module blitter_top #(
    parameter AW = 32
) (
    input  wire          clk,
    input  wire          rst,
    // Avalon-MM-ish master to shared DDR (qword addressed)
    output reg  [AW-1:0] mem_addr,
    output reg           mem_rd,
    output reg           mem_wr,
    output reg  [63:0]   mem_din,
    output reg  [7:0]    mem_be,
    input  wire [63:0]   mem_dout,
    input  wire          mem_dout_ready,
    input  wire          mem_busy,    // reserved (sim model never busy)
    output reg           idle
);
    localparam [5:0]
        S_POLL_SUBMIT=6'd0, S_POLL_DONE=6'd1, S_CHK_NEW=6'd2,
        S_GOT_CMDCNT=6'd3,  S_GOT_TARGET=6'd4, S_GOT_FLAGS=6'd5, S_GOT_CLEAR=6'd6,
        S_CLR_WR=6'd7,      S_FETCH=6'd8,  S_COLLECT=6'd9, S_DECODE=6'd10,
        S_SETUP=6'd11,      S_FILL_WR=6'd12,
        S_BLIT_RDSRC=6'd13, S_BLIT_GOTSRC=6'd14, S_BLIT_RDDST=6'd15,
        S_BLIT_GOTDST=6'd16, S_BLIT_WR=6'd17, S_PIX_ADV=6'd18, S_NEXT_CMD=6'd19,
        S_FRAME_VCTRL=6'd20, S_WR_DONE=6'd21, S_WR_STATUS=6'd22,
        S_RD_WAIT=6'd23,    S_WR_WAIT=6'd24,
        S_DBG_INIT=6'd25,   S_DBG_HB=6'd26,   // DIAGNOSTIC (temporary)
        S_BSETUP=6'd27;     // isolated source-base multiply (timing)

    localparam [7:0] OP_NOP=8'd0, OP_END=8'd1, OP_FILL=8'd2, OP_BLIT=8'd3;
    localparam [7:0] BLEND_KEY=8'd1, BLEND_ALPHA=8'd2;
    localparam [7:0] F_HFLIP=8'h01, F_VFLIP=8'h02, F_COLORKEY=8'h04;

    reg  [5:0]  state, rd_ret, wr_ret;
    reg         rd_issued;   // read accepted by the bus, now awaiting dout_ready
    reg  [63:0] rd_data;
    reg  [15:0] dbg_hb;      // DIAGNOSTIC free-running heartbeat

    reg  [31:0] submit_reg, done_reg, cmd_count, cmd_idx, frame_counter;
    reg         target_buf;
    reg  [31:0] target_base, cfg_flags, clr_idx;
    reg  [15:0] clear_color;
    reg  [63:0] cmd_qw [0:3];
    reg  [1:0]  fetch_k;

    reg  [7:0]  c_opcode, c_blend, c_format, c_flags, c_alpha;
    reg  [31:0] c_src_off;
    reg  [15:0] c_src_stride, c_src_x, c_src_y, c_w, c_h, c_colorkey, c_color;
    reg  signed [15:0] c_dst_x, c_dst_y;

    reg  signed [31:0] x0r, y0r, x1r, y1r, dx, dy;
    reg         is_fill;
    reg  [15:0] src_pix, wr_pix;
    reg  [31:0] src_byte_cur, src_row_byte;   // incremental source addressing
    reg  [15:0] src_x0s, src_y0s;             // source start coords (latched at S_SETUP)

    wire keyed = (c_blend == BLEND_KEY) || ((c_flags & F_COLORKEY) != 0);

    // ---- const-alpha channel blend (bit-exact to refmodel /255 form) ----
    function [15:0] blend565(input [15:0] s, input [15:0] d, input [7:0] a);
        integer sr,sg,sb,dr,dg,db,tr,tg,tb,ia,na,orr,ogg,obb;
        begin
            sr=s[15:11]; sg=s[10:5]; sb=s[4:0];
            dr=d[15:11]; dg=d[10:5]; db=d[4:0];
            ia=a; na=255-a;
            tr=sr*ia+dr*na; orr=(tr+128+((tr+128)>>8))>>8;
            tg=sg*ia+dg*na; ogg=(tg+128+((tg+128)>>8))>>8;
            tb=sb*ia+db*na; obb=(tb+128+((tb+128)>>8))>>8;
            blend565={orr[4:0],ogg[5:0],obb[4:0]};
        end
    endfunction

    // ---- clip (combinational off decoded c_*) --------------------------
    wire signed [31:0] sdx = c_dst_x, sdy = c_dst_y;
    wire signed [31:0] xe = sdx + c_w, ye = sdy + c_h;
    wire signed [31:0] clip_x0 = (sdx<0)?0:sdx;
    wire signed [31:0] clip_y0 = (sdy<0)?0:sdy;
    wire signed [31:0] clip_x1 = (xe>`FB_W)?`FB_W:xe;
    wire signed [31:0] clip_y1 = (ye>`FB_H)?`FB_H:ye;
    wire empty = (clip_x0>=clip_x1) || (clip_y0>=clip_y1);

    // ---- source addressing: REGISTERED INCREMENTAL --------------------------
    // Was a per-pixel 16x16 multiply (c_src_y+sy)*c_src_stride sitting on the
    // dy -> wr_pix critical path (setup slack -7.348 ns). src_byte_cur is now
    // maintained by adds in S_PIX_ADV (+/-2 per pixel, +/-stride per row); the
    // single multiply is isolated once-per-blit in S_BSETUP.
    wire [31:0] src_qw    = `SRC_QW + (src_byte_cur >> 3);
    wire [5:0]  src_sh    = {src_byte_cur[2:1], 4'b0};
    wire [15:0] src_pix_w = mem_dout[src_sh +: 16];
    // signed source-local start coords at the clipped origin (off c_*, dst)
    wire signed [31:0] sx0 = clip_x0 - sdx;   // = lx at (clip_x0)
    wire signed [31:0] sy0 = clip_y0 - sdy;   // = ly at (clip_y0)

    wire [31:0] dst_pidx = dy*`FB_W + dx;
    wire [31:0] dst_qw   = target_base + (dst_pidx >> 2);
    wire [5:0]  dst_sh   = {dst_pidx[1:0], 4'b0};
    wire [7:0]  lane_be  = 8'h03 << {dst_pidx[1:0], 1'b0};
    wire [15:0] dst_pix_w = mem_dout[dst_sh +: 16];

    // video control word (drop-in producer): frame_counter[31:2] | buf[1:0]
    wire [31:0] vctrl_val = ((frame_counter + 32'd1) << 2) | {31'd0, target_buf};

    always @(posedge clk) begin
        if (rst) begin
            state<=S_DBG_INIT; mem_rd<=0; mem_wr<=0; mem_be<=0;
            mem_addr<=0; mem_din<=0; idle<=1; frame_counter<=0;
            cmd_idx<=0; fetch_k<=0; submit_reg<=0; done_reg<=0; rd_issued<=0;
            dbg_hb<=16'd0;
        end else begin
            mem_rd<=1'b0;
            dbg_hb<=dbg_hb+16'd1;   // DIAGNOSTIC heartbeat
            case (state)
            S_POLL_SUBMIT: begin
                idle<=1; mem_rd<=1; mem_addr<=`BLTCTRL_QW+`C_SUBMIT;
                rd_ret<=S_POLL_DONE; state<=S_RD_WAIT;
            end
            S_POLL_DONE: begin
                submit_reg<=rd_data[31:0];
                mem_rd<=1; mem_addr<=`BLTCTRL_QW+`C_DONE;
                rd_ret<=S_CHK_NEW; state<=S_RD_WAIT;
            end
            S_CHK_NEW: begin
                done_reg<=rd_data[31:0];
                if (rd_data[31:0]==submit_reg) state<=S_DBG_HB;   // DIAGNOSTIC (was S_POLL_SUBMIT)
                else begin
                    idle<=0; mem_rd<=1; mem_addr<=`BLTCTRL_QW+`C_CMDCOUNT;
                    rd_ret<=S_GOT_CMDCNT; state<=S_RD_WAIT;
                end
            end
            S_GOT_CMDCNT: begin
                cmd_count<=rd_data[31:0];
                mem_rd<=1; mem_addr<=`BLTCTRL_QW+`C_TARGET;
                rd_ret<=S_GOT_TARGET; state<=S_RD_WAIT;
            end
            S_GOT_TARGET: begin
                target_buf<=rd_data[0];
                target_base<=rd_data[0]?`FB1_QW:`FB0_QW;
                mem_rd<=1; mem_addr<=`BLTCTRL_QW+`C_FLAGS;
                rd_ret<=S_GOT_FLAGS; state<=S_RD_WAIT;
            end
            S_GOT_FLAGS: begin
                cfg_flags<=rd_data[31:0];
                mem_rd<=1; mem_addr<=`BLTCTRL_QW+`C_CLEAR;
                rd_ret<=S_GOT_CLEAR; state<=S_RD_WAIT;
            end
            S_GOT_CLEAR: begin
                clear_color<=rd_data[15:0];
                if (cfg_flags[0]) begin clr_idx<=0; state<=S_CLR_WR; end
                else begin cmd_idx<=0; fetch_k<=0; state<=S_FETCH; end
            end
            S_CLR_WR: begin
                if (clr_idx==`FB_QWORDS) begin
                    cmd_idx<=0; fetch_k<=0; state<=S_FETCH;
                end else begin
                    mem_wr<=1; mem_be<=8'hFF; mem_addr<=target_base+clr_idx;
                    mem_din<={4{clear_color}}; clr_idx<=clr_idx+1;
                    wr_ret<=S_CLR_WR; state<=S_WR_WAIT;
                end
            end

            S_FETCH: begin
                if (cmd_idx>=cmd_count) state<=S_FRAME_VCTRL;
                else begin
                    fetch_k<=0; mem_rd<=1; mem_addr<=`RING_QW+cmd_idx*4;
                    rd_ret<=S_COLLECT; state<=S_RD_WAIT;
                end
            end
            S_COLLECT: begin
                cmd_qw[fetch_k]<=rd_data;
                if (fetch_k==2'd3) state<=S_DECODE;
                else begin
                    mem_rd<=1; mem_addr<=`RING_QW+cmd_idx*4+(fetch_k+2'd1);
                    fetch_k<=fetch_k+2'd1; rd_ret<=S_COLLECT; state<=S_RD_WAIT;
                end
            end
            S_DECODE: begin
                c_opcode    <= cmd_qw[0][7:0];
                c_blend     <= cmd_qw[0][15:8];
                c_format    <= cmd_qw[0][23:16];
                c_flags     <= cmd_qw[0][31:24];
                c_src_off   <= cmd_qw[0][63:32];
                c_src_stride<= cmd_qw[1][15:0];
                c_src_x     <= cmd_qw[1][31:16];
                c_w         <= cmd_qw[1][47:32];
                c_h         <= cmd_qw[1][63:48];
                c_src_y     <= cmd_qw[2][15:0];
                c_dst_x     <= cmd_qw[2][47:32];
                c_dst_y     <= cmd_qw[2][63:48];
                c_colorkey  <= cmd_qw[3][15:0];
                c_alpha     <= cmd_qw[3][23:16];
                c_color     <= cmd_qw[3][47:32];
                state<=S_SETUP;
            end
            S_SETUP: begin
                if (c_opcode==OP_END)       state<=S_FRAME_VCTRL;
                else if (c_opcode==OP_NOP)  state<=S_NEXT_CMD;
                else if (empty)             state<=S_NEXT_CMD;
                else begin
                    x0r<=clip_x0; y0r<=clip_y0; x1r<=clip_x1; y1r<=clip_y1;
                    dx<=clip_x0;  dy<=clip_y0; is_fill<=(c_opcode==OP_FILL);
                    // latch source-local start coords (flip-aware); the base
                    // multiply happens once in S_BSETUP (off the per-pixel path)
                    src_x0s <= c_src_x + ((c_flags&F_HFLIP) ? (c_w-1 - sx0[15:0]) : sx0[15:0]);
                    src_y0s <= c_src_y + ((c_flags&F_VFLIP) ? (c_h-1 - sy0[15:0]) : sy0[15:0]);
                    state<=(c_opcode==OP_FILL)?S_FILL_WR:S_BSETUP;
                end
            end
            S_BSETUP: begin
                // single isolated source-base multiply (src_y*stride); per-pixel
                // addressing is pure adds from here on
                src_row_byte <= c_src_off + src_y0s*c_src_stride + {15'd0, src_x0s, 1'b0};
                src_byte_cur <= c_src_off + src_y0s*c_src_stride + {15'd0, src_x0s, 1'b0};
                state<=S_BLIT_RDSRC;
            end

            S_FILL_WR: begin
                mem_wr<=1; mem_be<=lane_be; mem_addr<=dst_qw;
                mem_din<=({48'd0,c_color}<<dst_sh);
                wr_ret<=S_PIX_ADV; state<=S_WR_WAIT;
            end
            S_BLIT_RDSRC: begin
                mem_rd<=1; mem_addr<=src_qw; rd_ret<=S_BLIT_GOTSRC; state<=S_RD_WAIT;
            end
            S_BLIT_GOTSRC: begin
                src_pix<=src_pix_w;
                if (keyed && (src_pix_w==c_colorkey)) state<=S_PIX_ADV; // skip-write
                else if (c_blend==BLEND_ALPHA) begin
                    mem_rd<=1; mem_addr<=dst_qw; rd_ret<=S_BLIT_GOTDST; state<=S_RD_WAIT;
                end else begin wr_pix<=src_pix_w; state<=S_BLIT_WR; end
            end
            S_BLIT_GOTDST: begin
                wr_pix<=blend565(src_pix, dst_pix_w, c_alpha);
                state<=S_BLIT_WR;
            end
            S_BLIT_WR: begin
                mem_wr<=1; mem_be<=lane_be; mem_addr<=dst_qw;
                mem_din<=({48'd0,wr_pix}<<dst_sh);
                wr_ret<=S_PIX_ADV; state<=S_WR_WAIT;
            end
            S_PIX_ADV: begin
                if ((dx+1)>=x1r) begin
                    dx<=x0r;
                    if ((dy+1)>=y1r) state<=S_NEXT_CMD;
                    else begin
                        dy<=dy+1;
                        // next row: source y steps by +/-1 -> +/- stride bytes;
                        // reset the column cursor to the new row's start
                        src_row_byte <= (c_flags&F_VFLIP) ? src_row_byte - {16'd0,c_src_stride}
                                                          : src_row_byte + {16'd0,c_src_stride};
                        src_byte_cur <= (c_flags&F_VFLIP) ? src_row_byte - {16'd0,c_src_stride}
                                                          : src_row_byte + {16'd0,c_src_stride};
                        state<=is_fill?S_FILL_WR:S_BLIT_RDSRC;
                    end
                end else begin
                    dx<=dx+1;
                    // next pixel in row: source x steps by +/-1 -> +/-2 bytes
                    src_byte_cur <= (c_flags&F_HFLIP) ? src_byte_cur - 32'd2
                                                      : src_byte_cur + 32'd2;
                    state<=is_fill?S_FILL_WR:S_BLIT_RDSRC;
                end
            end
            S_NEXT_CMD: begin cmd_idx<=cmd_idx+1; state<=S_FETCH; end

            S_FRAME_VCTRL: begin
                mem_wr<=1; mem_be<=8'h0F; mem_addr<=`VCTRL_QW;
                mem_din<={32'd0, vctrl_val};
                frame_counter<=frame_counter+1;
                wr_ret<=S_WR_DONE; state<=S_WR_WAIT;
            end
            S_WR_DONE: begin
                mem_wr<=1; mem_be<=8'h0F; mem_addr<=`BLTCTRL_QW+`C_DONE;
                mem_din<={32'd0, submit_reg};
                wr_ret<=S_WR_STATUS; state<=S_WR_WAIT;
            end
            S_WR_STATUS: begin
                mem_wr<=1; mem_be<=8'h0F; mem_addr<=`BLTCTRL_QW+`C_STATUS;
                mem_din<=64'd0; wr_ret<=S_POLL_SUBMIT; state<=S_WR_WAIT;
            end

            // Backpressure-safe generic read: hold mem_rd until the bus accepts
            // it (~mem_busy), then await dout_ready. (mem_busy = ddram busy OR not
            // granted by the arbiter; on the never-busy sim model this is a no-op.)
            S_RD_WAIT: begin
                if (!rd_issued) begin
                    mem_rd <= 1'b1;                       // hold request
                    if (!mem_busy) rd_issued <= 1'b1;     // accepted this cycle
                end else if (mem_dout_ready) begin
                    rd_data <= mem_dout; rd_issued <= 1'b0; state <= rd_ret;
                end
            end
            // Backpressure-safe generic write: mem_wr/addr/din/be held from the
            // issue state; clear + advance only once the bus accepts (~mem_busy).
            S_WR_WAIT: if (!mem_busy) begin
                mem_wr <= 1'b0; mem_be <= 8'h00; state <= wr_ret;
            end
            // DIAGNOSTIC: prologue write before any polling. If 0x3A0E0030 reads
            // 0xCAFExxxx, the blitter got the bus + its FSM runs (so a freeze is in
            // the READ path). If it stays stale, the blitter never wrote at all.
            S_DBG_INIT: begin
                mem_wr<=1; mem_be<=8'h0F; mem_addr<=`BLTCTRL_QW+`C_STATUS;
                mem_din<={32'd0, 16'hCAFE, dbg_hb};
                wr_ret<=S_POLL_SUBMIT; state<=S_WR_WAIT;
            end
            // DIAGNOSTIC: on idle, write {heartbeat, submit[7:0], done[7:0]} so we
            // see it polling + what submit/done it actually read.
            S_DBG_HB: begin
                mem_wr<=1; mem_be<=8'h0F; mem_addr<=`BLTCTRL_QW+`C_STATUS;
                mem_din<={32'd0, dbg_hb, submit_reg[7:0], done_reg[7:0]};
                wr_ret<=S_POLL_SUBMIT; state<=S_WR_WAIT;
            end
            default: state<=S_POLL_SUBMIT;
            endcase
        end
    end
endmodule
`default_nettype wire
