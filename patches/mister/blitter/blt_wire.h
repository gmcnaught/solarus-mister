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

/* [ddr-store-width] The command ring lives in the FPGA DDR window, which a
 * /dev/mem mmap maps Strongly-Ordered (ARM phys_mem_access_prot() returns
 * pgprot_noncached() for any pfn outside the kernel memblock, and a fabric
 * address always is). SO stores cannot merge, so blt_wr32's four byte stores
 * are FOUR separate bus transactions per word — 32 per command. Measured on
 * the DE10-Nano (docs/superpowers/data/ddr-write-bench-2026-08-07.md):
 *
 *     bytewise into the window      13.9 MB/s   -> 2.30 us per 32-byte command
 *     aligned 32-bit stores         55.7 MB/s   -> 0.57 us   (4.02x)
 *
 * So the same command word written as one store instead of four costs a
 * quarter as much, with no kernel module and on any kernel.
 *
 * Why this needs an alignment branch rather than just doing it: on ARM an
 * unaligned access to Device or Strongly-Ordered memory raises an alignment
 * fault UNCONDITIONALLY — SCTLR.A does not disable the check for these memory
 * types, unlike Normal memory where ARMv7 handles unaligned word access in
 * hardware. Every real wire target is aligned by construction (ring commands
 * are 32 B apart from a 32 B-aligned base; sprite entries are 24 B; tile
 * entries 8 or 12 B), but blt_pack_cmd is also called on stack buffers by the
 * sim vector generator and the host tests, where the compiler only guarantees
 * 1-byte alignment for a uint8_t[]. One predictable branch per command is far
 * cheaper than the 24 extra bus transactions it avoids.
 *
 * The byte path also remains the correct one on a big-endian host; the wire is
 * defined little-endian, so the single-store form is only valid on LE. */
#if defined(__BYTE_ORDER__) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#  define BLT_WIRE_LE_STORE 1
#else
#  define BLT_WIRE_LE_STORE 0
#endif

/* Write one wire word to a target already known to be 4-byte aligned. */
static inline void blt_wr32a(uint8_t *p, uint32_t v) {
#if BLT_WIRE_LE_STORE
    *(uint32_t *)(void *)p = v;
#else
    blt_wr32(p, v);
#endif
}

/* Pack a command into 32 little-endian bytes.
 * `out` may be any alignment; the aligned form is taken when it is legal. */
static inline void blt_pack_cmd(const blt_cmd_t *c, uint8_t out[BLT_CMD_BYTES]) {
    const uint32_t w0 = (uint32_t)c->opcode | ((uint32_t)c->blend_mode<<8) |
                        ((uint32_t)c->format<<16) | ((uint32_t)c->flags<<24);
    const uint32_t w1 = c->src_off;
    const uint32_t w2 = (uint32_t)c->src_stride | ((uint32_t)c->src_x<<16);
    const uint32_t w3 = (uint32_t)c->w | ((uint32_t)c->h<<16);
    const uint32_t w4 = (uint32_t)c->src_y;
    const uint32_t w5 = (uint32_t)(uint16_t)c->dst_x | ((uint32_t)(uint16_t)c->dst_y<<16);
    /* [v2] _pad[2]=cb -> byte27; _pad[0]=cr -> byte30; _pad[1]=cg -> byte31.
     * Zero when BLT_F_COLORMOD is clear (memset) -> RTL ignores them. */
    const uint32_t w6 = (uint32_t)c->colorkey | ((uint32_t)c->alpha<<16) |
                        ((uint32_t)c->_pad[2]<<24);
    const uint32_t w7 = (uint32_t)c->color | ((uint32_t)c->_pad[0]<<16) |
                        ((uint32_t)c->_pad[1]<<24);

    if (((uintptr_t)out & 3u) == 0u) {
        blt_wr32a(out+0,  w0); blt_wr32a(out+4,  w1);
        blt_wr32a(out+8,  w2); blt_wr32a(out+12, w3);
        blt_wr32a(out+16, w4); blt_wr32a(out+20, w5);
        blt_wr32a(out+24, w6); blt_wr32a(out+28, w7);
    } else {
        blt_wr32(out+0,  w0); blt_wr32(out+4,  w1);
        blt_wr32(out+8,  w2); blt_wr32(out+12, w3);
        blt_wr32(out+16, w4); blt_wr32(out+20, w5);
        blt_wr32(out+24, w6); blt_wr32(out+28, w7);
    }
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

/* [Stage 2 / Task 4b] Sprite-list entry: 24 bytes, QWORD-ALIGNED (THREE qwords) so
 * the fabric reads it with aligned fetches — no 3-qword unaligned window + barrel
 * shift like the 12-byte blt_tile_entry_t needs. Unlike tiles, sprites do NOT share
 * one texture, so src_off is PER ENTRY; stride/format/blend stay in the header.
 *
 * [Task 4b] `color` is likewise PER ENTRY. A tile layer is one tileset = one
 * palette, so OP_TILELIST can keep the palette in its header; sprites are Y-sorted
 * across many sheets, so the palette varies entry to entry for exactly the same
 * reason src_off does. For BLT_FMT_PAL8 it is blt_pal_color(pal_id, base_off);
 * 0 otherwise. Bytes 20-23 are explicit tail padding to the 3-qword size (the
 * alternative, a 20-byte entry, would break the aligned-fetch property). */
typedef struct {
    uint32_t src_off;              /* source surface base offset                  */
    uint16_t src_x, src_y, w, h;   /* source rect                                 */
    int16_t  dst_x, dst_y;         /* dst, header bias added by the fabric        */
    uint16_t color;                /* [Task 4b] PAL8 pal_id/base_off; 0 otherwise */
    uint16_t _rsvd;                /* reserved (bytes 18-19), written as 0        */
    uint32_t _rsvd2;               /* pad to 24 B = 3 qwords (bytes 20-23), 0     */
} blt_sprite_entry_t;

/* Wire size of ONE sprite-list entry. Every stride/cursor/cap computation in the
 * emitter, the channel, the reference model and the tests MUST use this — a stray
 * literal would place entries at the wrong base and corrupt SP_BUF silently. */
#define BLT_SPRITE_ENTRY_BYTES 24

static inline void blt_pack_sprite_entry(uint8_t *d, const blt_sprite_entry_t *e)
{
    d[0]=(uint8_t)(e->src_off); d[1]=(uint8_t)(e->src_off>>8);
    d[2]=(uint8_t)(e->src_off>>16); d[3]=(uint8_t)(e->src_off>>24);
    d[4]=(uint8_t)(e->src_x); d[5]=(uint8_t)(e->src_x>>8);
    d[6]=(uint8_t)(e->src_y); d[7]=(uint8_t)(e->src_y>>8);
    d[8]=(uint8_t)(e->w);     d[9]=(uint8_t)(e->w>>8);
    d[10]=(uint8_t)(e->h);    d[11]=(uint8_t)(e->h>>8);
    d[12]=(uint8_t)(e->dst_x);d[13]=(uint8_t)((uint16_t)e->dst_x>>8);
    d[14]=(uint8_t)(e->dst_y);d[15]=(uint8_t)((uint16_t)e->dst_y>>8);
    /* [Task 4b] bytes 16-19: per-entry palette word then the reserved half-word,
     * both little-endian like every other field. */
    d[16]=(uint8_t)(e->color); d[17]=(uint8_t)(e->color>>8);
    d[18]=(uint8_t)(e->_rsvd); d[19]=(uint8_t)(e->_rsvd>>8);
    /* Bytes 20-23: tail padding. Written explicitly (not left stale) so a re-used
     * SP_BUF slot never hands the fabric another frame's bytes in a field a later
     * wire revision might start reading. */
    d[20]=(uint8_t)(e->_rsvd2);      d[21]=(uint8_t)(e->_rsvd2>>8);
    d[22]=(uint8_t)(e->_rsvd2>>16);  d[23]=(uint8_t)(e->_rsvd2>>24);
}

/* [PAL8 v1.1] Palette-indexed source: pack pal_id (5b, 32 banks) and base_off (8b)
 * into the color word. pal_id occupies bits[12:8], base_off bits[7:0]; bits[15:13]
 * are free. The fabric decodes c_color[12:8] (comp_pipeline c_pal_id[4:0]). */
static inline uint16_t blt_pal_color(uint8_t pal_id, uint8_t base_off) {
    return (uint16_t)(((uint16_t)(pal_id & 0x1F) << 8) | base_off);
}
static inline uint8_t  blt_pal_id(uint16_t color)   { return (color >> 8) & 0x1F; }
static inline uint8_t  blt_base_off(uint16_t color) { return color & 0xFF; }

#endif /* BLT_WIRE_H */
