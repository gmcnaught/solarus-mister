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
# No main= for Solarus: under MiSTer_hybrid (upstream Main_MiSTer 3380931) the
# Solarus core's DDR3 path is dead -- scanout vsync counter frozen, C_DONE stuck
# (.81, 2026-09-26) -- and the fabric stays broken for later stock-MiSTer loads
# until a reboot. Undo a main= this entry's first version set.
if [ "$(mh_ini_main)" = "$HOOK" ]; then
	mh_ini_disable_main "$HOOK" "Solarus (main= unsupported on this core)" \
		&& echo "launcher: MiSTer.ini [$CORENAME] main=$HOOK disabled (not supported by the Solarus core)"
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
