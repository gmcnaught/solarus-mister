`ifndef COMP_CLUT_VH
`define COMP_CLUT_VH
`define CLUT_BANKS   32
`define CLUT_ENTRIES 256
// entry: {A4[19:16], R5[15:11], G6[10:5], B5[4:0]} in a 32-bit word (high 12 = 0)
`define CLUT_MAKE(a4, rgb) ({8'd0, (a4), (rgb)})   // a4:4b, rgb:16b
// NOTE: single-paren wrap only — iverilog 13.0's parser rejects a part-select
// applied to a double-parenthesized expression (`((e)[15:0])`), a real syntax
// incompatibility caught when Task 1.2 first compiled these macros. Semantics
// unchanged (e[19:16] / e[15:0]).
`define CLUT_A4(e)  (e[19:16])
`define CLUT_RGB(e) (e[15:0])
`endif
