#!/bin/sh
# Device: sample the per-frame fabric profile block N times and print the mean.
#   fabric_prof.sh [samples=60] [interval_s=0.25]
#
# Needs an RBF with S_WR_PROF (PROF_QW 0x3A070010, 14 qwords written once per frame
# after C_STATUS; layout in fpga/rtl/blitter_defs.vh) and a running engine. Each
# sample is the LAST published frame; a sample is taken only when C_DONE moved.
# C_DONE+4 (0x3B00002C) = frame cycles, C_STATUS+4 (0x3B000034) = compositor-busy.
N=${1:-60}; DT=${2:-0.25}
dm() { echo $(( $(busybox devmem "$1" 32) )); }   # decimal (busybox awk has no strtonum)
i=0; tries=0; last=""
# give up after 20x the samples asked for (no engine = C_DONE never moves)
while [ $i -lt "$N" ] && [ $tries -lt $((N * 20)) ]; do
	tries=$((tries+1))
	d=$(dm 0x3B000028)
	if [ "$d" != "$last" ]; then
		last=$d
		line="$(dm 0x3B00002C) $(dm 0x3B000034)"
		a=$((0x3A070010))
		while [ $a -lt $((0x3A070080)) ]; do line="$line $(dm $a)"; a=$((a + 4)); done
		echo "$line"
		i=$((i+1))
	fi
	sleep "$DT"
done | awk '
{ for (k = 1; k <= NF; k++) s[k] += $k; n++ }
END {
	if (n == 0) { print "no samples"; exit 1 }
	# field order: frame pipe, then the 28 words of the profile block (low, high per qword)
	split("frame pipe issue bubble srcwait collect ctl spans blits walkold setup cmd clear stage upload walk snapgate snapdrain publish other rdwait rdcnt wrwait wrcnt srcrd srclat srcslow srcmax pfbeats pfwin", nm, " ")
	for (k = 1; k <= 30; k++) m[nm[k]] = s[k] / n
	f = m["frame"]; p = m["pipe"]; ms = 98437.5
	printf "samples %d  (mean per frame; clk_sys 98.4375 MHz)\n", n
	printf "  frame      %9.0f cyc %6.2f ms\n", f, f / ms
	printf "  compositor %9.0f cyc %6.2f ms  (%4.1f%% of frame)\n", p, p / ms, 100 * p / f
	split("issue bubble srcwait collect ctl", c, " ")
	for (k = 1; k <= 5; k++) printf "    %-10s %8.0f  %6.2f ms  (%4.1f%% of compositor)\n", c[k], m[c[k]], m[c[k]] / ms, 100 * m[c[k]] / p
	printf "  outside    %9.0f cyc %6.2f ms  (%4.1f%% of frame)\n", f - p, (f - p) / ms, 100 * (f - p) / f
	split("setup cmd clear stage upload walk snapgate snapdrain publish other", g, " ")
	for (k = 1; k <= 10; k++) printf "    %-10s %8.0f  %6.2f ms  (%4.1f%% of outside)\n", g[k], m[g[k]], m[g[k]] / ms, 100 * m[g[k]] / (f - p)
	printf "  DDR reads  %.0f, wait %.0f cyc (%.1f cyc/read)   writes %.0f, wait %.0f cyc\n",
		m["rdcnt"], m["rdwait"], m["rdwait"] / (m["rdcnt"] ? m["rdcnt"] : 1), m["wrcnt"], m["wrwait"]
	printf "  P_SRC      %.0f reads, %.2f cyc/read, %.1f%% slow (>6 cyc), max %.0f cyc\n",
		m["srcrd"], m["srclat"] / (m["srcrd"] ? m["srcrd"] : 1), 100 * m["srcslow"] / (m["srcrd"] ? m["srcrd"] : 1), m["srcmax"]
	printf "  walker prefetch: %.0f qwords streamed; walker waited %.0f cyc (%.2f ms) in S_PF_WIN\n",
		m["pfbeats"], m["pfwin"], m["pfwin"] / ms
	printf "  spans %.0f  blits %.0f  px/span %.1f  cyc/px(compositor) %.2f\n",
		m["spans"], m["blits"], m["issue"] / (m["spans"] ? m["spans"] : 1), p / (m["issue"] ? m["issue"] : 1)
}'
