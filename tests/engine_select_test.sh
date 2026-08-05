#!/bin/sh
# Host test for the SOLARUS_ENGINE selector in games/Solarus/solarus_run.sh
# (the Solarus 2.x test option — docs/solarus2.md).
#
# Why this is worth a test: solarus_run.sh is a no-fallback on-device launcher,
# and the selector touches the three things a wrong branch would break silently —
# WHICH binary is exec'd, which LD_LIBRARY_PATH it gets, and whether the blitter
# env is exported. Getting engine=2 wrong would run the SHIPPING engine while a
# log line claims 2.x; getting engine=1 wrong would break every ordinary launch.
#
# Harness: solarus_run.sh ends in `exec <engine> ...`, so a fake executable at
# each candidate path that prints its argv + the env it inherited turns the exec
# into observable output. Everything the script reads is env-overridable
# (GAMEDIR/S0_FILE/FATROOT/QUEST_LIB), so no device paths are touched.
set -u
# shellcheck disable=SC1007  # `CDPATH= cd` is the intended idiom (clear CDPATH for this one command), as in resolve_quest_test.sh
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1007
REPO=$(CDPATH= cd "$HERE/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAT="$TMP/fat"
GAMEDIR="$FAT/games/Solarus"
QDIR="$GAMEDIR/quests"
mkdir -p "$QDIR" "$GAMEDIR/v2/libs" "$GAMEDIR/libs"
: > "$QDIR/zelda.sol"
printf 'games/Solarus/quests/zelda.sol\n' > "$TMP/s0"

# Fake engines. Each reports which one ran, plus the env the launcher set up.
for p in "$GAMEDIR/solarus-run" "$GAMEDIR/v2/solarus-run"; do
  cat > "$p" <<'EOF'
#!/bin/sh
echo "RAN=$0"
echo "ARGS=$*"
echo "LDPATH=$LD_LIBRARY_PATH"
echo "BLITTER=${SOLARUS_BLITTER:-unset}"
EOF
  chmod +x "$p"
done

fails=0
ok()  { echo "  PASS $1"; }
bad() { echo "  FAIL $1"; echo "$2" | sed 's/^/      /'; fails=$((fails+1)); }

run() {  # run() <SOLARUS_ENGINE value or "">  -> launcher output + engine output
  _eng="$1"
  # SOLARUS_ENGINE=2 always CAPTURES the engine's stdout/stderr to $SOLARUS_DIAG_LOG
  # (that log is the only way to observe an engine that draws nothing), so point it
  # at a temp file and fold it back in — otherwise the engine's output would not
  # appear on this function's stdout at all.
  : > "$TMP/diag.log"
  env -i PATH="$PATH" HOME="$TMP/home" \
      GAMEDIR="$GAMEDIR" S0_FILE="$TMP/s0" FATROOT="$FAT" \
      QUEST_LIB="$REPO/games/Solarus/quest_lib.sh" \
      SOLARUS_NO_DIAG_ENV=1 SOLARUS_DIAG_LOG="$TMP/diag.log" \
      ${_eng:+SOLARUS_ENGINE="$_eng"} \
      sh "$REPO/games/Solarus/solarus_run.sh" 2>&1
  _rc=$?
  cat "$TMP/diag.log" 2>/dev/null
  return "$_rc"   # T4 asserts a NON-ZERO exit; `cat` must not mask it
}
# core_watch.sh is spawned detached from $GAMEDIR; give it a harmless stand-in
# so the launcher's `setsid sh "$GAMEDIR/core_watch.sh"` doesn't emit noise.
printf '#!/bin/sh\nexit 0\n' > "$GAMEDIR/core_watch.sh"; chmod +x "$GAMEDIR/core_watch.sh"

echo "== SOLARUS_ENGINE selector (Solarus 2.x test option) =="

# T1: default (unset) -> shipping 1.6 engine, blitter env exported.
out=$(run "")
if echo "$out" | grep -q "RAN=./solarus-run" && echo "$out" | grep -q "BLITTER=1"; then
  ok "T1 default runs the shipping engine with the blitter env"
else
  bad "T1 default" "$out"
fi

# T1b: default must NOT put v2 on the library path.
if echo "$out" | grep -q "LDPATH=.*v2"; then
  bad "T1b default leaked v2 onto LD_LIBRARY_PATH" "$out"
else
  ok "T1b default keeps v2 off LD_LIBRARY_PATH"
fi

# T2: SOLARUS_ENGINE=2 -> the v2 binary, v2 libs FIRST, and NO blitter env
# (stock 2.x has no blitter; exporting it would make the log lie).
out=$(run 2)
if echo "$out" | grep -q "RAN=$GAMEDIR/v2/solarus-run"; then
  ok "T2 engine=2 execs the v2 binary"
else
  bad "T2 engine=2 binary" "$out"
fi
if echo "$out" | grep -q "LDPATH=$GAMEDIR/v2/libs:"; then
  ok "T2b engine=2 puts v2/libs first on LD_LIBRARY_PATH"
else
  bad "T2b engine=2 LD_LIBRARY_PATH" "$out"
fi
if echo "$out" | grep -q "BLITTER=unset"; then
  ok "T2c engine=2 does not export the blitter env"
else
  bad "T2c engine=2 blitter env" "$out"
fi

# T3: both engines get the same launch arguments — the selector must change WHICH
# binary runs, not HOW it is invoked.
a=$(run "" | grep '^ARGS=')
b=$(run 2  | grep '^ARGS=')
if [ "$a" = "$b" ]; then ok "T3 identical launch args on both engines"; else bad "T3 args differ" "1.6: $a
2.x: $b"; fi

# T4: engine=2 with nothing deployed must FAIL LOUDLY, not silently fall back to
# the 1.6 engine — a silent fallback would invalidate every 2.x measurement.
mv "$GAMEDIR/v2/solarus-run" "$GAMEDIR/v2/solarus-run.away"
out=$(run 2); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "SOLARUS_ENGINE=2 but" && ! echo "$out" | grep -q "^RAN="; then
  ok "T4 missing v2 build fails loudly, no fallback to 1.6"
else
  bad "T4 missing v2 build (rc=$rc)" "$out"
fi
mv "$GAMEDIR/v2/solarus-run.away" "$GAMEDIR/v2/solarus-run"

# T5: an unrecognised value is treated as the shipping engine (fail safe: a typo
# in diag.env must not strand the device on an engine that shows nothing).
out=$(run 99)
if echo "$out" | grep -q "RAN=./solarus-run"; then
  ok "T5 unknown SOLARUS_ENGINE falls back to the shipping engine"
else
  bad "T5 unknown value" "$out"
fi

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "FAILURES: $fails"; exit 1; fi
