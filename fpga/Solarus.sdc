# Solarus MiSTer core project-level timing constraints.
# Forked from the MiSTer_OpenBOR core (shared DDR3 video/audio/joystick RTL).
#
# Background: same hybrid-architecture pattern as PICO-8 / OpenBOR.
# The user PLL (emu|pll|pll_inst) produces clk_sys (~100 MHz, DDR3)
# and clk_pix (53.693 MHz, exact Genesis MCLK / 8). A separate
# pll_audio drives the audio output domain. CDC paths between these
# domains are correctly handled by 2-FF synchronizers and dcfifos in
# the reader, but without explicit asynchronous-group declarations
# Quartus tries to time them as synchronous and reports phantom
# -2 to -3 ns setup failures. The bitstream may still work by silicon
# luck, but any RTL change or recompile risks tripping past the lucky
# margin into actual data corruption.
#
# Fix: declare each user PLL output (and pll_audio) as its own
# asynchronous clock group. Same pattern that fixed PICO-8 v1.0
# (clk_pix slack -4.4 ns -> +35.6 ns).

set_clock_groups -asynchronous \
    -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    -group [get_clocks {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
