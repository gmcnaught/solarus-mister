#include "mister_bgfill_probe.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    /* Ground pid=7 as 3 big rects (coalesced) + two small pid=9 decorations. */
    bgfill_ent_t ents[] = {
        {  0,   0, 320, 240, 7 },   /* 76800 px */
        {320,   0, 320, 240, 7 },   /* 76800 px */
        {  0, 240, 640, 264, 7 },   /* 168960 px -> pid 7 total 322560 */
        { 16,  16,   8,   8, 9 },
        { 48,  16,   8,   8, 9 },   /* pid 9 total 128 px */
    };
    unsigned short pid = 0; int x0=0,y0=0,x1=0,y1=0;
    int hit = bgfill_pick(ents, 5, /*area_min=*/0x8000, &pid, &x0,&y0,&x1,&y1);
    assert(hit == 1);
    assert(pid == 7);
    assert(x0 == 0 && y0 == 0 && x1 == 640 && y1 == 504);
    printf("bbox pid=%u [%d,%d)-(%d,%d) OK\n", pid, x0, y0, x1, y1);

    /* No dominant fill: all small -> below area_min -> no hit. */
    bgfill_ent_t small[] = { {0,0,8,8,1}, {8,0,8,8,2}, {16,0,8,8,3} };
    int hit2 = bgfill_pick(small, 3, 0x8000, &pid, &x0,&y0,&x1,&y1);
    assert(hit2 == 0);

    /* Tokenless (pid 0xFFFF) is ignored even if largest. */
    bgfill_ent_t tok[] = { {0,0,640,504,0xFFFF}, {0,0,200,200,5} };  /* 40000 px */
    int hit3 = bgfill_pick(tok, 2, 0x8000, &pid, &x0,&y0,&x1,&y1);
    assert(hit3 == 1 && pid == 5);
    assert(x0==0 && y0==0 && x1==200 && y1==200);

    printf("bgfill_probe_test PASS\n");
    return 0;
}
