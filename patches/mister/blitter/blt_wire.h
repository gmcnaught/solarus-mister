/* VENDORED from github.com/gmcnaught/mister-fpga-blitter (host/blt_wire.h) — do not edit here; edit upstream + re-copy. */
/*
 *  blt_wire.h — canonical pack/unpack between blt_cmd_t and the 32-byte on-wire
 *  command word the fabric reads from the DDR ring. Single source of truth for
 *  the command layout, shared by the host emitter (blt_emitter.c), the sim
 *  vector generator (sim/gen_vectors.c), and any RTL cross-check.
 *
 *  Wire layout (32 bytes = 8x u32, little-endian; see docs/blitter-protocol.md
 *  and the unpack in rtl/blitter_top.sv — these MUST agree):
 *    u32[0] = opcode | blend<<8 | format<<16 | flags<<24
 *    u32[1] = src_off
 *    u32[2] = src_stride | src_x<<16
 *    u32[3] = w | h<<16
 *    u32[4] = src_y
 *    u32[5] = (u16)dst_x | (u16)dst_y<<16
 *    u32[6] = colorkey | alpha<<16 | cmod_b<<24
 *    u32[7] = color | cmod_r<<16 | cmod_g<<24
 *  [v2 escape-elim] the 3 free wire bytes (27,30,31) carry the RGB888 color-mod
 *  tint when flags & BLT_F_COLORMOD: byte27=cb, byte30=cr, byte31=cg. Sourced from
 *  blt_cmd_t._pad[0..2]={cr,cg,cb}. MUST AGREE with rtl/blitter_top.sv c_cmod_*.
 *  [PAL8 v1] when format==BLT_FMT_PAL8, color(u32[7] low16) = pal_id[11:8] | base_off[7:0].
 *
 *  [#52 resident / Tier B] BLT_OP_TILELIST_RES and BLT_OP_FRT_UPLOAD reuse this same
 *  32-byte command layout (no new pack/unpack):
 *    - TILELIST_RES: identical header to TILELIST (u32[3]=N, u32[5]=entry byte offset,
 *      src_off/stride/format/blend/flags/key shared). The N entries are 8-byte
 *      blt_tile_entry_res_t {u16 pattern_id; i16 dst_x,dst_y; u16 _rsvd} written LE,
 *      one per qword, into the TL_BUF region the fabric reads.
 *    - FRT_UPLOAD: u32[3] = w|h<<16 = qword count of the frame-rect table to copy from
 *      the FRT DDR region into the fabric frt BRAM. All other fields 0.
 *  FRT entries are 8-byte blt_frame_rect_t {u16 src_x,src_y,w,h} (one qword each); CFT
 *  entries are u16 little-endian. Host structs are LE so a raw store matches the wire.
 *
 *  GPL-3.0.
 */
#ifndef BLT_WIRE_H
#define BLT_WIRE_H

#include "blitter_ref.h"
#include <stdint.h>

#define BLT_CMD_BYTES 32

static inline void blt_wr32(uint8_t *p, uint32_t v) {
    p[0]=v; p[1]=v>>8; p[2]=v>>16; p[3]=v>>24;
}
static inline uint32_t blt_rd32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1]<<8) | ((uint32_t)p[2]<<16) | ((uint32_t)p[3]<<24);
}

/* Pack a command into 32 little-endian bytes. */
static inline void blt_pack_cmd(const blt_cmd_t *c, uint8_t out[BLT_CMD_BYTES]) {
    blt_wr32(out+0,  (uint32_t)c->opcode | ((uint32_t)c->blend_mode<<8) |
                     ((uint32_t)c->format<<16) | ((uint32_t)c->flags<<24));
    blt_wr32(out+4,  c->src_off);
    blt_wr32(out+8,  (uint32_t)c->src_stride | ((uint32_t)c->src_x<<16));
    blt_wr32(out+12, (uint32_t)c->w | ((uint32_t)c->h<<16));
    blt_wr32(out+16, (uint32_t)c->src_y);
    blt_wr32(out+20, (uint32_t)(uint16_t)c->dst_x | ((uint32_t)(uint16_t)c->dst_y<<16));
    /* [v2] _pad[2]=cb -> byte27; _pad[0]=cr -> byte30; _pad[1]=cg -> byte31.
     * Zero when BLT_F_COLORMOD is clear (memset) -> RTL ignores them. */
    blt_wr32(out+24, (uint32_t)c->colorkey | ((uint32_t)c->alpha<<16) |
                     ((uint32_t)c->_pad[2]<<24));
    blt_wr32(out+28, (uint32_t)c->color | ((uint32_t)c->_pad[0]<<16) |
                     ((uint32_t)c->_pad[1]<<24));
}

/* Unpack 32 little-endian bytes into a command (inverse of blt_pack_cmd). */
static inline void blt_unpack_cmd(const uint8_t in[BLT_CMD_BYTES], blt_cmd_t *c) {
    uint32_t u0=blt_rd32(in+0),  u2=blt_rd32(in+8),  u3=blt_rd32(in+12);
    uint32_t u5=blt_rd32(in+20), u6=blt_rd32(in+24);
    c->opcode     = u0 & 0xFF;
    c->blend_mode = (u0>>8)  & 0xFF;
    c->format     = (u0>>16) & 0xFF;
    c->flags      = (u0>>24) & 0xFF;
    c->src_off    = blt_rd32(in+4);
    c->src_stride = u2 & 0xFFFF;
    c->src_x      = u2 >> 16;
    c->w          = u3 & 0xFFFF;
    c->h          = u3 >> 16;
    c->src_y      = blt_rd32(in+16) & 0xFFFF;
    c->dst_x      = (int16_t)(u5 & 0xFFFF);
    c->dst_y      = (int16_t)(u5 >> 16);
    c->colorkey   = u6 & 0xFFFF;
    c->alpha      = (u6>>16) & 0xFF;
    uint32_t u7   = blt_rd32(in+28);
    c->color      = u7 & 0xFFFF;
    /* [v2] color-mod tint (meaningful only when flags & BLT_F_COLORMOD) */
    c->_pad[2]    = (u6>>24) & 0xFF;   /* cb */
    c->_pad[0]    = (u7>>16) & 0xFF;   /* cr */
    c->_pad[1]    = (u7>>24) & 0xFF;   /* cg */
}

/* [PAL8 v1] Palette-indexed source: pack pal_id (4b) and base_off (8b) into color word */
static inline uint16_t blt_pal_color(uint8_t pal_id, uint8_t base_off) {
    return (uint16_t)(((uint16_t)(pal_id & 0x0F) << 8) | base_off);
}
static inline uint8_t  blt_pal_id(uint16_t color)   { return (color >> 8) & 0x0F; }
static inline uint8_t  blt_base_off(uint16_t color) { return color & 0xFF; }

#endif /* BLT_WIRE_H */
