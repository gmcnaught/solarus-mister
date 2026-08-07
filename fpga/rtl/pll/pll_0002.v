`timescale 1ns/10ps
module  pll_0002(

	// interface 'refclk'
	input wire refclk,

	// interface 'reset'
	input wire rst,

	// interface 'outclk0'
	output wire outclk_0,

	// interface 'outclk1'
	output wire outclk_1,

	// interface 'outclk2'
	output wire outclk_2,

	// interface 'outclk3'
	output wire outclk_3,

	// interface 'locked'
	output wire locked
);

	altera_pll #(
		.fractional_vco_multiplier("false"),
		.reference_clock_frequency("50.0 MHz"),
		.operation_mode("direct"),
		.number_of_clocks(4),
		.output_clock_frequency0("98.437500 MHz"),
		.phase_shift0("0 ps"),
		.duty_cycle0(50),
		.output_clock_frequency1("20.000000 MHz"),
		.phase_shift1("0 ps"),
		.duty_cycle1(50),
		.output_clock_frequency2("53.693182 MHz"),
		.phase_shift2("0 ps"),
		.duty_cycle2(50),
		.output_clock_frequency3("98.437500 MHz"),
		// [#44] SDRAM_CLK capture phase. MUST be a non-zero ~105.8ps PLL tap:
		// at 0 ps outclk_3 is bit-identical to outclk_0, so Quartus merges them
		// and SDRAM_CLK goes unconstrained (frame-wide banding).
		//
		// 2540ps (24 taps, ~90deg). This was 5079ps (~180deg, half the 10159ps
		// period) until 2026-08-06, when a board-to-board render fault was traced
		// to it: on 192.168.20.62 the shipped 5079 was the ONLY failing phase of
		// the sweep — 1270/2540/3810/6349/7619/8889 all rendered correctly, 5079
		// alone produced period-2 pixel corruption (alternate 16-bit words read as
		// zero), and re-failed when retested straight after the six passes.
		// 192.168.20.81 passes at 5079, 2540 and 3810, so 5079 is marginal rather
		// than wrong, and .62 sits on the wrong side of it.
		//
		// 2540 is chosen over the other passing taps because it is what the
		// sibling Maldita Castilla core uses — same sdram_fb_cache, same
		// jtframe_burst_sdram, same SDRAM_AW(25) 128MB XL geometry, same
		// 98.4375MHz clocks — and that core has always worked on the failing
		// board. It also sits 2539ps from the bad window, versus 3810's 1269ps.
		//
		// Caveats, do not overstate this: two-board sample, and it is symptomatic.
		// It does not address jtframe_burst_ctrl never gating traffic on SDRAM
		// init completion. Quantify it with DQCAP_SLACK_NS per phase — that metric
		// was only just repaired and has never yet reported a correct number.
		// Evidence: docs/superpowers/2026-08-06-sdram-62-phase-root-cause.md
		.phase_shift3("2540 ps"),
		.duty_cycle3(50),
		.output_clock_frequency4("0 MHz"),
		.phase_shift4("0 ps"),
		.duty_cycle4(50),
		.output_clock_frequency5("0 MHz"),
		.phase_shift5("0 ps"),
		.duty_cycle5(50),
		.output_clock_frequency6("0 MHz"),
		.phase_shift6("0 ps"),
		.duty_cycle6(50),
		.output_clock_frequency7("0 MHz"),
		.phase_shift7("0 ps"),
		.duty_cycle7(50),
		.output_clock_frequency8("0 MHz"),
		.phase_shift8("0 ps"),
		.duty_cycle8(50),
		.output_clock_frequency9("0 MHz"),
		.phase_shift9("0 ps"),
		.duty_cycle9(50),
		.output_clock_frequency10("0 MHz"),
		.phase_shift10("0 ps"),
		.duty_cycle10(50),
		.output_clock_frequency11("0 MHz"),
		.phase_shift11("0 ps"),
		.duty_cycle11(50),
		.output_clock_frequency12("0 MHz"),
		.phase_shift12("0 ps"),
		.duty_cycle12(50),
		.output_clock_frequency13("0 MHz"),
		.phase_shift13("0 ps"),
		.duty_cycle13(50),
		.output_clock_frequency14("0 MHz"),
		.phase_shift14("0 ps"),
		.duty_cycle14(50),
		.output_clock_frequency15("0 MHz"),
		.phase_shift15("0 ps"),
		.duty_cycle15(50),
		.output_clock_frequency16("0 MHz"),
		.phase_shift16("0 ps"),
		.duty_cycle16(50),
		.output_clock_frequency17("0 MHz"),
		.phase_shift17("0 ps"),
		.duty_cycle17(50),
		.pll_type("General"),
		.pll_subtype("General")
	) altera_pll_i (
		.rst	(rst),
		.outclk	({outclk_3, outclk_2, outclk_1, outclk_0}),
		.locked	(locked),
		.fboutclk	( ),
		.fbclk	(1'b0),
		.refclk	(refclk)
	);
endmodule

