#!/bin/sh
# Device: sample the per-frame fabric profile block N times and print the mean.
#   fabric_prof.sh [samples=60] [interval_s=0.25]
#
# Needs an RBF with S_WR_PROF (PROF_QW 0x3A070010, 4 qwords written once per frame
# after C_STATUS) and a running engine. Each sample is the LAST published frame;
# frames with no compositing (C_DONE not moving) are skipped.
#   0x3A070010 issue    0x3A070014 bubble   0x3A070018 srcwait  0x3A07001C collect
#   0x3A070020 ctl      0x3A070024 spans    0x3A070028 blits    0x3A07002C walk
#   C_DONE+4 (0x3B00002C) frame cycles      C_STATUS+4 (0x3B000034) pipe-busy cycles
N=${1:-60}; DT=${2:-0.25}
dm() { echo $(( $(busybox devmem "$1" 32) )); }   # decimal (busybox awk has no strtonum)
i=0; tries=0; last=""
# give up after 20x the samples asked for (no engine = C_DONE never moves)
while [ $i -lt "$N" ] && [ $tries -lt $((N * 20)) ]; do
	tries=$((tries+1))
	d=$(dm 0x3B000028)
	if [ "$d" != "$last" ]; then
		last=$d
		echo "$(dm 0x3B00002C) $(dm 0x3B000034) $(dm 0x3A070010) $(dm 0x3A070014) $(dm 0x3A070018) $(dm 0x3A07001C) $(dm 0x3A070020) $(dm 0x3A070024) $(dm 0x3A070028) $(dm 0x3A07002C)"
		i=$((i+1))
	fi
	sleep "$DT"
done | awk '
{ for (k = 1; k <= 10; k++) s[k] += $k; n++ }
END {
	if (n == 0) { print "no samples"; exit 1 }
	split("frame pipe issue bubble srcwait collect ctl spans blits walk", nm, " ")
	for (k = 1; k <= 10; k++) m[k] = s[k] / n
	printf "samples %d  (mean per frame, clk_sys cycles; 98.4375 MHz)\n", n
	printf "  frame   %9.0f  %6.2f ms\n", m[1], m[1] / 98437.5
	printf "  pipe    %9.0f  %6.2f ms  (%4.1f%% of frame)\n", m[2], m[2] / 98437.5, 100 * m[2] / m[1]
	for (k = 3; k <= 7; k++)
		printf "    %-8s %8.0f  %6.2f ms  (%4.1f%% of pipe)\n", nm[k], m[k], m[k] / 98437.5, 100 * m[k] / m[2]
	printf "  non-pipe%9.0f  %6.2f ms  (walk %.0f of it)\n", m[1] - m[2], (m[1] - m[2]) / 98437.5, m[10]
	printf "  spans %.0f  blits %.0f  px/span %.1f  cyc/px(pipe) %.2f  bubble/span %.1f  ctl/span %.1f\n",
		m[8], m[9], m[3] / (m[8] ? m[8] : 1), m[2] / (m[3] ? m[3] : 1), m[4] / (m[8] ? m[8] : 1), m[7] / (m[8] ? m[8] : 1)
}'
