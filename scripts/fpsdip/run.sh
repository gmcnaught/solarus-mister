#!/bin/bash
# Device: fps-dip capture through the real launcher (games/Solarus/solarus_run.sh:
# mem_wc, ship flags) with an instrumented engine and scripted, invincible play.
#
#   run.sh <tag> [seconds=300] [engine dir with solarus-run + libsolarus.so.1.6.5]
#
# Engine: SOLARUS_FRAMELOG per-iteration records (mister_framelog.h) + a maps sidecar.
# Play:   driver.lua through the Lua console on a held-open FIFO (never EOFs, so the
#         console thread blocks instead of spinning). Hero invincible, sword granted,
#         map tour + random play. The game is never saved.
# System: 1 Hz /proc/stat, /proc/interrupts, /proc/softirqs, /proc/meminfo samples.
# PROF=1  adds `perf record -e cpu-clock -F 1000` on the engine main thread
#         (prof.txt.gz; frames.py --prof). PERF_BIN overrides the perf path.
# SCHED=1 adds a CPU0 sched_switch/irq/softirq trace (cpu.txt.gz). Perturbs the run
#         (tmpfs memory): use for attribution, never for pass/fail numbers.
# EXTRA_ENV="A=1 B=2" exports more engine env for A/B knobs.
# DWELL / TOUR / SEED pass through to driver.lua.
#
# Everything is written to /tmp during the run (/media/fat is mounted sync: every
# write there is an SD write) and copied to /media/fat/logs/Solarus/fpsdip/<tag>/.
set -u
TAG=$1; SECS=${2:-300}; ENGINE_DIR=${3:-}
HERE=$(cd "$(dirname "$0")" && pwd)
G=/media/fat/games/Solarus
OUT=/media/fat/logs/Solarus/fpsdip/$TAG
PERF=${PERF_BIN:-$HERE/perf/perf}
FIFO=/tmp/fpsdip_in
mkdir -p "$OUT"; rm -f "$OUT"/*
[ "$(cat /tmp/CORENAME 2>/dev/null)" = Solarus ] || { echo "Solarus core not loaded"; exit 1; }
# One capture at a time: two runs means two engines on one fabric (wedges the host).
mkdir /tmp/fpsdip.lock 2>/dev/null || { echo "another fpsdip run holds /tmp/fpsdip.lock"; exit 1; }

# No auto-launch machinery and no second engine (two engines wedge the host).
for p in quest_manager.sh core_watch.sh solarus_daemon.sh; do
	for pid in $(ps | grep "$p" | grep -v grep | awk '{print $1}'); do kill -9 "$pid" 2>/dev/null; done
done
# shellcheck disable=SC2046  # pidof may return multiple PIDs; word-split is intended
pidof solarus-run >/dev/null && { kill -9 $(pidof solarus-run); sleep 1; }

# FAT has no symlinks: every soname spelling is its own copy, and the binary loads .so.1.
LIBS="libsolarus.so.1 libsolarus.so.1.6.5 libsolarus.so"
restore_files() {
	[ -f "$G/solarus-run.fpsdip-orig" ] && { rm -f "$G/solarus-run"; mv "$G/solarus-run.fpsdip-orig" "$G/solarus-run"; }
	for l in $LIBS; do
		[ -f "$G/libs/$l.fpsdip-orig" ] && { rm -f "$G/libs/$l"; mv "$G/libs/$l.fpsdip-orig" "$G/libs/$l"; }
	done
}
restore() {
	restore_files
	for p in $(ps | grep "[t]ail -f /dev/null" | awk '{print $1}'); do kill "$p" 2>/dev/null; done
	rm -f "$FIFO" /tmp/fpsdip_s0
	rmdir /tmp/fpsdip.lock 2>/dev/null
}
restore_files   # a run killed with -9 skips its trap: put the ship engine back first
trap restore EXIT
if [ -n "$ENGINE_DIR" ]; then
	mv "$G/solarus-run" "$G/solarus-run.fpsdip-orig"
	cp "$ENGINE_DIR/solarus-run" "$G/solarus-run"; chmod +x "$G/solarus-run"
	for l in $LIBS; do
		[ -f "$G/libs/$l" ] || continue
		mv "$G/libs/$l" "$G/libs/$l.fpsdip-orig"
		cp "$ENGINE_DIR/libsolarus.so.1.6.5" "$G/libs/$l"
	done
fi
md5sum "$G/solarus-run" "$G"/libs/libsolarus.so* > "$OUT/engine.md5"

rm -f /tmp/fpsdip_frames.bin /tmp/fpsdip_frames.bin.maps /tmp/fpsdip_state.txt
rm -f "$FIFO"; mkfifo "$FIFO"
setsid sh -c "tail -f /dev/null > $FIFO" </dev/null >/dev/null 2>&1 &
printf %s "$G/quests/mystery_of_solarus_dx.sol" > /tmp/fpsdip_s0

(
	export S0_FILE=/tmp/fpsdip_s0 SOLARUS_LUACONSOLE=0 SOLARUS_NO_DIAG_ENV=1
	export SOLARUS_FRAMELOG=/tmp/fpsdip_frames.bin
	# shellcheck disable=SC2163  # each word is a NAME=value pair to export
	for kv in ${EXTRA_ENV:-}; do export "$kv"; done
	cd "$G" && exec setsid sh "$G/solarus_run.sh" < "$FIFO" > /tmp/fpsdip_engine.log 2>&1
) &
echo "EXTRA_ENV=${EXTRA_ENV:-}" > "$OUT/test.env"

# Wait for the title screen (preload ~10 s), then start the driver.
w=0; until grep -q "Simulation started" /tmp/fpsdip_engine.log 2>/dev/null; do
	sleep 1; w=$((w+1)); [ $w -gt 90 ] && { echo "engine did not start"; tail -20 /tmp/fpsdip_engine.log; exit 1; }
done
sleep 3
EPID=$(pidof solarus-run)
taskset -p 2 $$ >/dev/null 2>&1      # keep this shell and its children off CPU0
{
	echo "engine pid $EPID"
	for t in /proc/$EPID/task/*; do echo "$(cat "$t"/comm) tid ${t##*/} $(taskset -p "${t##*/}" | awk '{print $NF}')"; done
} > /tmp/fpsdip_info.txt
printf 'FPSDIP_STATE="/tmp/fpsdip_state.txt" FPSDIP_DWELL=%s FPSDIP_SEED=%s %s %s dofile("%s/driver.lua")\n' \
	"${DWELL:-40000}" "${SEED:-1}" "${TOUR:+FPSDIP_TOUR=\"$TOUR\"}" "${TRACEFILL:+FPSDIP_TRACEFILL=true}" "$HERE" > "$FIFO"

( while :; do echo "T $(awk '{print $1}' /proc/uptime)"; grep -E '^cpu[01] ' /proc/stat
  grep -E "MemFree|MemAvailable|^Cached" /proc/meminfo | awk '{print "M", $1, $2}'
  grep -E ':' /proc/interrupts | awk '{print "I", $1, $2, $3, $NF}'
  grep -E 'TIMER|NET_RX|TASKLET|SCHED|RCU|BLOCK|HRTIMER' /proc/softirqs | awk '{print "S", $1, $2, $3}'
  sleep 1; done > /tmp/fpsdip_sys.txt ) &
SAMP=$!
PIDS=""
if [ "${PROF:-0}" = 1 ]; then
	LD_LIBRARY_PATH=$HERE/perf/lib taskset 2 "$PERF" record -q -k mono -e cpu-clock -F 1000 -t "$EPID" \
		-o /tmp/fpsdip_prof.data -- sleep "$SECS" >/dev/null 2>&1 &
	PIDS="$PIDS $!"
fi
if [ "${SCHED:-0}" = 1 ]; then
	# CPU0 only (the render thread's CPU) and without the per-CPU timer IRQ 24: an
	# all-CPU trace with it fills /tmp (tmpfs) within ~20 s and silently stops the
	# frame log too.
	LD_LIBRARY_PATH=$HERE/perf/lib taskset 2 "$PERF" record -q -k mono -C 0 -e sched:sched_switch \
		-e irq:irq_handler_entry --filter "irq != 24" -e irq:irq_handler_exit --filter "irq != 24" \
		-e irq:softirq_entry -e irq:softirq_exit -o /tmp/fpsdip_sched.data -- sleep "$SECS" >/dev/null 2>&1 &
	PIDS="$PIDS $!"
fi
sleep "$SECS"
for p in $PIDS; do wait "$p"; done
kill $SAMP 2>/dev/null
kill -TERM "$EPID" 2>/dev/null   # SIGTERM = clean exit (patch 0017): the frame log flushes
for _ in 1 2 3 4 5 6 7 8 9 10; do pidof solarus-run >/dev/null || break; sleep 1; done
# shellcheck disable=SC2046  # pidof may return multiple PIDs; word-split is intended
pidof solarus-run >/dev/null && kill -9 $(pidof solarus-run)

cp /tmp/fpsdip_frames.bin "$OUT/frames.bin"; cp /tmp/fpsdip_frames.bin.maps "$OUT/maps.txt"
cp /tmp/fpsdip_state.txt "$OUT/state.txt" 2>/dev/null
[ -f /tmp/fpsdip_fill.txt ] && mv /tmp/fpsdip_fill.txt "$OUT/fill.txt"
mv /tmp/fpsdip_sys.txt "$OUT/sys.txt"; cp /tmp/fpsdip_engine.log "$OUT/engine.log"
mv /tmp/fpsdip_info.txt "$OUT/info.txt"
[ -f /tmp/fpsdip_prof.data ] && LD_LIBRARY_PATH=$HERE/perf/lib "$PERF" script -i /tmp/fpsdip_prof.data -F time,ip,sym,dso 2>/dev/null | gzip -1 > "$OUT/prof.txt.gz"
[ -f /tmp/fpsdip_sched.data ] && LD_LIBRARY_PATH=$HERE/perf/lib "$PERF" script -i /tmp/fpsdip_sched.data -F time,cpu,comm,tid,event,trace 2>/dev/null | gzip -1 > "$OUT/cpu.txt.gz"
rm -f /tmp/fpsdip_prof.data /tmp/fpsdip_sched.data /tmp/fpsdip_frames.bin
ls -la "$OUT"
