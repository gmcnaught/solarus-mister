// Host-side index recovery + palette (CLUT) extraction for paletted
// composition (task 2.1). Converts an SDL_Surface — either already 8-bit
// indexed, or 32-bit RGBA as produced by SDL_image for PNGs SDL didn't keep
// paletted — into an 8bpp index plane + a <=256-entry CLUT (RGB565 colour +
// 4-bit alpha per index), ready to stage to SDRAM as PAL8.
//
// Header-only, SDL types only (no Solarus/engine deps), so it builds and
// links into both mister_blitter_renderer.cpp (C++) and a plain-C host unit
// test. All functions are `static inline` -> safe to include in multiple
// translation units.
#ifndef MISTER_PALETTE_ATLAS_H
#define MISTER_PALETTE_ATLAS_H

#include <SDL.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifndef __cplusplus
#include <stdbool.h>
#endif

// out->index is caller-owned and must be freed with free() once no longer
// needed (pal_extract mallocs it, tightly packed row-major, stride == w).
typedef struct pal_surface {
    uint8_t* index;        // w*h bytes, one palette index per pixel
    int w, h;
    uint16_t clut_rgb[256]; // RGB565, one entry per palette index
    uint8_t clut_a4[256];   // 4-bit alpha (0..15), one entry per palette index
    int ncolors;            // number of CLUT entries actually populated
} pal_surface;

// RGB565 pack, per the paletted-composition CLUT format.
static inline uint16_t pal_rgb565(uint8_t r, uint8_t g, uint8_t b)
{
    return (uint16_t)(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3));
}

// 8-bit alpha (0..255) -> 4-bit alpha (0..15), rounded to nearest.
// Equivalent to round(a / 17.0): floor((a + 8) / 17) implements round-half-
// up for non-negative a, and 17*15 == 255 so the endpoints land exactly.
static inline uint8_t pal_alpha_to_a4(int a)
{
    if (a < 0) a = 0;
    if (a > 255) a = 255;
    return (uint8_t)((a + 8) / 17);
}

static inline bool pal_extract_indexed(SDL_Surface* s, pal_surface* out)
{
    const SDL_Palette* pal = s->format->palette;
    int ncolors = pal->ncolors;
    if (ncolors > 256) ncolors = 256; // 8bpp SDL palettes never exceed this

    uint8_t* index = (uint8_t*)malloc((size_t)s->w * (size_t)s->h);
    if (!index) return false;

    const uint8_t* src = (const uint8_t*)s->pixels;
    for (int y = 0; y < s->h; y++) {
        memcpy(index + (size_t)y * s->w, src + (size_t)y * s->pitch, (size_t)s->w);
    }

    int has_key = 0;
    Uint32 key = 0;
    has_key = (SDL_GetColorKey(s, &key) == 0);

    for (int i = 0; i < ncolors; i++) {
        const SDL_Color* c = &pal->colors[i];
        out->clut_rgb[i] = pal_rgb565(c->r, c->g, c->b);
        // [no-rgba-roundtrip] Alpha comes from the PALETTE ENTRY, which is where
        // SDL_image puts a PNG's tRNS chunk (per-index alpha), with an explicit
        // colour key overriding to fully transparent.
        //
        // This used to read SDL_GetSurfaceAlphaMod() instead and give every
        // non-key entry the same baseline alpha, which silently flattened tRNS to
        // opaque. It never showed because this branch could not be reached in
        // production: Surface::create_sdl_surface_from_file() converted every
        // decoded image to ABGR8888, so pal_extract always took the _rgba branch.
        // Now that paletted sources reach it directly, per-entry alpha is load
        // bearing -- 259 of the 270 paletted quest assets carry tRNS.
        //
        // Verified equivalent to the old RGBA32 round-trip, not assumed: resolving
        // every pixel natively (palette RGB + tRNS alpha -> RGB565/A4) matches the
        // RGBA32 path bit-for-bit over all 270 paletted assets, 0 pixels differing.
        // Surface alpha MOD is deliberately NOT baked in here: it is a draw-time
        // modulation, and the _rgba path never baked it either.
        out->clut_a4[i] = (has_key && (Uint32)i == key) ? 0 : pal_alpha_to_a4(c->a);
    }

    out->index = index;
    out->w = s->w;
    out->h = s->h;
    out->ncolors = ncolors;
    return true;
}

static inline bool pal_extract_rgba(SDL_Surface* s, pal_surface* out)
{
    uint8_t* index = (uint8_t*)malloc((size_t)s->w * (size_t)s->h);
    if (!index) return false;

    // First-appearance-order colour table; linear scan is fine here — this
    // runs once per asset at load time (<=256 entries by contract), not per
    // frame. (After the preload walk filter only ONE quest asset still reaches
    // this path — 9.tiles.png, the sole truecolour tileset — so the O(px*ncolors)
    // scan is ~0.2 Mpx of a 26.6 Mpx preload and needs no accelerator.)
    //
    // [always-PAL8] The dedup key is the QUANTIZED (RGB565, A4) pair, NOT the
    // source RGBA8888. That pair is exactly what the CLUT stores, so two source
    // colours that quantize together were ALWAYS going to become one CLUT entry;
    // keying on RGBA8888 merely counted them twice and could blow the 256-entry
    // budget over colours the fabric cannot tell apart. Measured on MoSDX's
    // 9.tiles.png: 258 distinct RGBA8888 -> 90 distinct (RGB565, A4), i.e. the
    // ONLY quest asset that used to fail pal_extract now fits with room to spare,
    // and no pixel changes value (the quantization below already happened).
    uint32_t seen_key[256];
    int nseen = 0;

    const uint8_t* rows = (const uint8_t*)s->pixels;
    bool ok = true;
    for (int y = 0; y < s->h && ok; y++) {
        const Uint32* px = (const Uint32*)(rows + (size_t)y * s->pitch);
        for (int x = 0; x < s->w; x++) {
            Uint8 r, g, b, a;
            SDL_GetRGBA(px[x], s->format, &r, &g, &b, &a);
            const uint16_t q_rgb = pal_rgb565(r, g, b);
            const uint8_t  q_a4  = pal_alpha_to_a4(a);
            uint32_t pkey = ((uint32_t)q_a4 << 16) | (uint32_t)q_rgb;

            int idx = -1;
            for (int i = 0; i < nseen; i++) {
                if (seen_key[i] == pkey) { idx = i; break; }
            }
            if (idx < 0) {
                if (nseen >= 256) { ok = false; break; } // >256 distinct colours
                idx = nseen;
                seen_key[nseen] = pkey;
                out->clut_rgb[nseen] = q_rgb;
                out->clut_a4[nseen] = q_a4;
                nseen++;
            }
            index[(size_t)y * s->w + x] = (uint8_t)idx;
        }
    }

    if (!ok) {
        free(index);
        return false;
    }

    out->index = index;
    out->w = s->w;
    out->h = s->h;
    out->ncolors = nseen;
    return true;
}

// See file header for the two-branch contract.
static inline bool pal_extract(SDL_Surface* s, pal_surface* out)
{
    memset(out, 0, sizeof(*out));
    if (s->format->BytesPerPixel == 1 && s->format->palette) {
        return pal_extract_indexed(s, out);
    }
    return pal_extract_rgba(s, out);
}

// ---------------------------------------------------------------------------
// Task 2.2: palette manager — CLUT bank packing.
//
// The fabric holds `PAL_CLUT_BANKS` banks of `PAL_CLUT_ENTRIES` CLUT entries
// each (comp_clut.vh: `CLUT_BANKS=32, `CLUT_ENTRIES=256). Each pal_surface's
// extracted palette (<=256 colours) is packed first-fit into these banks so
// a PAL8 index plane can carry a (bank, base) pair instead of raw colour.
// MUST stay in sync with CLUT_BANKS in mister_blitter_renderer.cpp and
// `CLUT_BANKS in comp_clut.vh (all three are one logical constant).
//
// Entry format matches the fabric's `CLUT_MAKE(a4, rgb) (comp_clut.vh):
// a 32-bit word with A4 in bits[19:16] and RGB565 in bits[15:0] (bits above
// 19 are zero). `CLUT_A4(e)`/`CLUT_RGB(e)` on the fabric side read those same
// bit ranges back out.
#define PAL_CLUT_BANKS   32
#define PAL_CLUT_ENTRIES 256

typedef struct pal_bankset {
    // [bank*PAL_CLUT_ENTRIES + slot] -> CLUT_MAKE-format 32-bit entry.
    uint32_t entries[PAL_CLUT_BANKS * PAL_CLUT_ENTRIES];
    // Number of slots already used (appended-to) in each bank.
    uint16_t used[PAL_CLUT_BANKS];
} pal_bankset;

static inline void pal_bankset_init(pal_bankset* bs)
{
    memset(bs, 0, sizeof(*bs));
}

// First-fit pack: find the lowest-numbered bank with enough free slots for
// s->ncolors, append s's CLUT entries starting at that bank's current used
// count, and report where they landed via *out_bank/*out_base.
//
// Banks are filled in order and never reused/compacted, so as long as the
// caller packs the map's tileset palette first (before any sprite/other
// palettes), first-fit naturally pins it to bank 0 -- no special-casing
// needed here.
//
// Returns false (bs unmodified) if no bank has room; caller falls back to
// direct-colour for that surface plus a loud log.
static inline bool pal_pack(pal_bankset* bs, const pal_surface* s,
                             uint8_t* out_bank, uint8_t* out_base)
{
    if (s->ncolors <= 0 || s->ncolors > PAL_CLUT_ENTRIES) return false;

    for (int b = 0; b < PAL_CLUT_BANKS; b++) {
        int free_slots = PAL_CLUT_ENTRIES - bs->used[b];
        if (free_slots < s->ncolors) continue;

        int base = bs->used[b];
        uint32_t* dst = &bs->entries[b * PAL_CLUT_ENTRIES + base];
        for (int i = 0; i < s->ncolors; i++) {
            uint32_t a4 = s->clut_a4[i] & 0xF;
            uint32_t rgb = s->clut_rgb[i];
            dst[i] = (a4 << 16) | rgb; // CLUT_MAKE(a4, rgb)
        }
        bs->used[b] = (uint16_t)(base + s->ncolors);
        *out_bank = (uint8_t)b;
        *out_base = (uint8_t)base;
        return true;
    }
    return false; // all PAL_CLUT_BANKS banks full
}

// Build the exact CLUTBUF byte image the fabric's BLT_OP_CLUT_UPLOAD DMA
// reads: PAL_CLUT_BANKS*PAL_CLUT_ENTRIES (2048) qwords, one 32-bit CLUT_MAKE
// entry per 64-bit qword in the low 4 bytes (little-endian), high 4 bytes
// zero -- matching tb_clut_upload.sv's preload (`wmem(..., {32'd0,
// pattern_word(k)})`) and blitter_top.sv's S_CLUT_WR (`clut_bram[...] <=
// rd_data[31:0]`). ddr must have room for PAL_CLUT_BANKS*PAL_CLUT_ENTRIES*8
// (16384) bytes.
static inline void pal_bankset_bytes(const pal_bankset* bs, uint8_t* ddr)
{
    for (int i = 0; i < PAL_CLUT_BANKS * PAL_CLUT_ENTRIES; i++) {
        uint32_t e = bs->entries[i];
        uint8_t* q = ddr + (size_t)i * 8;
        q[0] = (uint8_t)(e & 0xFF);
        q[1] = (uint8_t)((e >> 8) & 0xFF);
        q[2] = (uint8_t)((e >> 16) & 0xFF);
        q[3] = (uint8_t)((e >> 24) & 0xFF);
        q[4] = 0;
        q[5] = 0;
        q[6] = 0;
        q[7] = 0;
    }
}

#endif // MISTER_PALETTE_ATLAS_H
