`ifndef COMP_CLUT_VH
`define COMP_CLUT_VH
`define CLUT_BANKS   8
`define CLUT_ENTRIES 256
// entry: {A4[19:16], R5[15:11], G6[10:5], B5[4:0]} in a 32-bit word (high 12 = 0)
`define CLUT_MAKE(a4, rgb) ({8'd0, (a4), (rgb)})   // a4:4b, rgb:16b
`define CLUT_A4(e)  ((e)[19:16])
`define CLUT_RGB(e) ((e)[15:0])
`endif
