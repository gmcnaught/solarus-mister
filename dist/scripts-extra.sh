# Remove what pre-platform releases (<= v1.2.0) installed. Rendered into
# Scripts/Solarus.sh. solarus_daemon.sh (started from user-startup.sh) spawned
# _handler.sh -> quest_manager.sh -> solarus_run.sh on core load, and MiSTer
# Frontier's Master_Daemon runs _handler.sh too: either would start a second engine.
STARTUP=/media/fat/linux/user-startup.sh
had_daemon=0
[ -f "$GAMEDIR/solarus_daemon.sh" ] && had_daemon=1
if [ -f "$STARTUP" ] && grep -q "solarus_daemon.sh" "$STARTUP"; then
	had_daemon=1
	grep -v -e "solarus_daemon.sh" -e "^# Solarus .* self-owned core-load daemon" "$STARTUP" > "$STARTUP.tmp.$$" \
		&& mv "$STARTUP.tmp.$$" "$STARTUP" && echo "launcher: removed the old daemon from $STARTUP"
fi
# shellcheck disable=SC2009  # busybox pgrep -f is not guaranteed on MiSTer
for pid in $(ps -o pid,args | awk '/[s]olarus_daemon.sh|[q]uest_manager.sh|[c]ore_watch.sh/{print $1}'); do
	kill "$pid" 2>/dev/null && echo "launcher: stopped an old watcher (pid $pid)"
done
# An old engine's CPU placement (solarus_run.sh saved it; core_watch.sh restored it).
if [ -s /tmp/solarus_cpu_state ] && ! pidof solarus-run >/dev/null; then
	while read -r kind id mask; do
		case "$kind" in
			irq) echo "$mask" > "/proc/irq/$id/smp_affinity" 2>/dev/null ;;
			pid) taskset -a -p "$mask" "$id" >/dev/null 2>&1 ;;
		esac
	done < /tmp/solarus_cpu_state
fi
rm -f /tmp/solarus_cpu_state /tmp/solarus_corewatch.pid
for f in _handler.sh solarus_daemon.sh quest_manager.sh quest_lib.sh solarus_run.sh core_watch.sh mem_wc.ko; do
	[ -f "$GAMEDIR/$f" ] && rm -f "$GAMEDIR/$f" && echo "launcher: removed $f"
done
# mem_wc modules moved to platform/mem_wc/.
[ -d "$GAMEDIR/mem_wc" ] && rm -rf "$GAMEDIR/mem_wc" && echo "launcher: removed mem_wc/"
# The daemon started the game on every Solarus core load. Keep that: turn main=
# on for [Solarus] unless the section already has a main= line (active, or
# commented out by Solarus_CoresMenu).
sec_has_main() {
	awk -v sec="[$MH_INI_SECTION]" '/^\[/ { ins = ($0 == sec); next } ins && /^;?main=/ { f = 1 } END { exit !f }' \
		"$MH_INI_FILE" 2>/dev/null
}
if [ -x "$HOOK" ] && [ -f "/media/fat/linux/hybrid.d/$CORENAME.conf" ] && ! sec_has_main; then
	mh_ini_set_main "$HOOK" && echo "launcher: MiSTer.ini [$CORENAME] main=$HOOK (loading the core starts the quest picker; Scripts -> Solarus_CoresMenu turns it off)"
fi
[ "$had_daemon" = 1 ] && echo "launcher: migrated from the solarus_daemon start path"
chmod +x "$GAMEDIR/solarus_start.sh" 2>/dev/null
# Stale fabric handshake: C_SUBMIT/C_DONE live in DDR3 (0x3B000000, bank 1 at
# 0x3B080000) and survive core loads and warm reboots. After a killed or wedged
# run they can be left with C_DONE != C_SUBMIT; the next Solarus core then chases
# the ring from its first cycle and the engine hangs in preload (.81 2026-09-26,
# both start paths). Zero both control blocks while MENU is loaded (no fabric
# runs), just before this entry loads the core. Not from launch.sh: by then the
# core is up and C_DONE is fabric-owned.
if [ "$(cat /tmp/CORENAME 2>/dev/null)" = MENU ]; then
	for b in 0x3B000000 0x3B080000; do
		for o in 0 4 8 12 16 20 24 28 32 36 40 44 48 52 56 60; do busybox devmem $((b + o)) 32 0; done
	done
	echo "launcher: zeroed the Solarus fabric control blocks"
fi
