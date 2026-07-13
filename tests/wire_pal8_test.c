#include "blitter_ref.h"
#include "blt_wire.h"
#include <assert.h>
#include <string.h>
int main(void) {
    /* pal_id/base_off pack into the color field and survive a wire round-trip */
    assert(blt_pal_color(0xA, 0x37) == ((0xA << 8) | 0x37));
    assert(blt_pal_id(blt_pal_color(0xA, 0x37)) == 0xA);
    assert(blt_base_off(blt_pal_color(0xA, 0x37)) == 0x37);

    blt_cmd_t c; memset(&c, 0, sizeof c);
    c.opcode = BLT_OP_BLIT; c.format = BLT_FMT_PAL8; c.blend_mode = BLT_BLEND_COLORKEY;
    c.color  = blt_pal_color(0x5, 0x80);
    uint8_t wire[BLT_CMD_BYTES]; blt_pack_cmd(&c, wire);
    blt_cmd_t d; blt_unpack_cmd(wire, &d);
    assert(d.format == BLT_FMT_PAL8);
    assert(blt_pal_id(d.color) == 0x5 && blt_base_off(d.color) == 0x80);
    assert(BLT_FMT_PAL8 == 2);
    return 0;
}
