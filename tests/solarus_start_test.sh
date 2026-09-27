#!/bin/sh
# Host test for games/Solarus/solarus_start.sh, the per-quest engine start the
# platform launcher (games/Solarus/launch.sh, mister-port.toml) runs with the
# OSD-picked .sol as $1.
#
# What a wrong branch would break silently: WHICH binary is exec'd, which
# LD_LIBRARY_PATH it gets, whether the blitter env is exported (SOLARUS_ENGINE=2
# test option, docs/solarus2.md), and the quest indirection (data.solarus link +
# SOLARUS_QUEST_ID for controls.cfg).
#
# Harness: solarus_start.sh ends in `exec <engine> ...`, so a fake executable at
# each candidate path that prints its argv + env turns the exec into output.
set -u
# shellcheck disable=SC1007  # `CDPATH= cd` is the intended idiom (clear CDPATH for this one command)
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1007
REPO=$(CDPATH= cd "$HERE/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

GAMEDIR="$TMP/fat/games/Solarus"
mkdir -p "$GAMEDIR/quests" "$GAMEDIR/v2/libs" "$GAMEDIR/libs"
: > "$GAMEDIR/quests/zelda.sol"
QUEST="$GAMEDIR/quests/zelda.sol"
RUNDIR="$TMP/run"

for p in "$GAMEDIR/solarus-run" "$GAMEDIR/v2/solarus-run"; do
  cat > "$p" <<'EOS'
#!/bin/sh
echo "RAN=$0"
echo "ARGS=$*"
echo "LDPATH=$LD_LIBRARY_PATH"
echo "BLITTER=${SOLARUS_BLITTER:-unset}"
echo "QUESTID=${SOLARUS_QUEST_ID:-unset}"
EOS
  chmod +x "$p"
done

fails=0
ok()  { echo "  PASS $1"; }
bad() { echo "  FAIL $1"; echo "$2" | sed 's/^/      /'; fails=$((fails+1)); }

run() {  # run <SOLARUS_ENGINE or ""> [SOLARUS_ENGINE2_STOCK] [quest]
  env -i PATH="$PATH" HOME="$TMP/home" MH_GAMEDIR="$GAMEDIR" SOLARUS_RUNDIR="$RUNDIR" \
      LD_LIBRARY_PATH="$GAMEDIR/libs:$GAMEDIR" SOLARUS_NO_DIAG_ENV=1 SOLARUS_CPUISOLATE=0 \
      ${1:+SOLARUS_ENGINE="$1"} ${2:+SOLARUS_ENGINE2_STOCK="$2"} \
      bash "$REPO/games/Solarus/solarus_start.sh" "${3-$QUEST}" 2>&1
}
# The script cd's to $GAMEDIR and execs `./solarus-run`: $0 is either form.
ran_ship() { echo "$1" | grep -qE "^RAN=(\./|$GAMEDIR/)solarus-run$"; }

echo "== solarus_start.sh (per-quest engine start) =="

out=$(run "")
if ran_ship "$(echo "$out" | grep '^RAN=')" && echo "$out" | grep -q "BLITTER=1"; then
  ok "T1 default runs the shipping engine with the blitter env"
else bad "T1 default" "$out"; fi
if echo "$out" | grep -q "LDPATH=.*$GAMEDIR/v2"; then bad "T1b default leaked v2 onto LD_LIBRARY_PATH" "$out"
else ok "T1b default keeps v2 off LD_LIBRARY_PATH"; fi
if echo "$out" | grep -q "^ARGS=-force-software-rendering -lua-console=no $RUNDIR$" \
   && [ "$(readlink "$RUNDIR/data.solarus")" = "$QUEST" ]; then
  ok "T1c quest linked in as data.solarus, engine pointed at the directory"
else bad "T1c quest indirection" "$out $(ls -la "$RUNDIR" 2>&1)"; fi
if echo "$out" | grep -q "^QUESTID=zelda$"; then ok "T1d SOLARUS_QUEST_ID = .sol basename"
else bad "T1d quest id" "$out"; fi
if [ -d "$TMP/home/.solarus" ]; then ok "T1e save dir created under HOME"
else bad "T1e save dir" "$(ls -la "$TMP/home" 2>&1)"; fi

out=$(run 2)
if echo "$out" | grep -q "RAN=$GAMEDIR/v2/solarus-run" && echo "$out" | grep -q "LDPATH=$GAMEDIR/v2/libs:" \
   && echo "$out" | grep -q "BLITTER=1"; then
  ok "T2 engine=2 execs v2, v2/libs first, blitter env on"
else bad "T2 engine=2" "$out"; fi

outs=$(run 2 1)
if echo "$outs" | grep -q "RAN=$GAMEDIR/v2/solarus-run" && echo "$outs" | grep -q "BLITTER=unset"; then
  ok "T2d engine=2 + ENGINE2_STOCK=1 runs v2 with NO blitter env"
else bad "T2d engine=2 stock leg" "$outs"; fi

a=$(run "" | grep '^ARGS='); b=$(run 2 | grep '^ARGS=')
if [ "$a" = "$b" ]; then ok "T3 identical launch args on both engines"; else bad "T3 args differ" "1.6: $a
2.x: $b"; fi

mv "$GAMEDIR/v2/solarus-run" "$GAMEDIR/v2/solarus-run.away"
out=$(run 2); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "SOLARUS_ENGINE=2 but" && ! echo "$out" | grep -q "^RAN="; then
  ok "T4 missing v2 build fails loudly, no fallback to 1.6"
else bad "T4 missing v2 build (rc=$rc)" "$out"; fi
mv "$GAMEDIR/v2/solarus-run.away" "$GAMEDIR/v2/solarus-run"

out=$(run 99)
if ran_ship "$(echo "$out" | grep '^RAN=')"; then ok "T5 unknown SOLARUS_ENGINE falls back to the shipping engine"
else bad "T5 unknown value" "$out"; fi

out=$(run "" "" "$GAMEDIR/quests/missing.sol"); rc=$?
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "quest not found" && ! echo "$out" | grep -q "^RAN="; then
  ok "T6 missing quest file: no engine"
else bad "T6 missing quest (rc=$rc)" "$out"; fi

printf 'SOLARUS_ENGINE=2\n' > "$GAMEDIR/diag.env"
out=$(env -i PATH="$PATH" HOME="$TMP/home" MH_GAMEDIR="$GAMEDIR" SOLARUS_RUNDIR="$RUNDIR" \
      SOLARUS_CPUISOLATE=0 bash "$REPO/games/Solarus/solarus_start.sh" "$QUEST" 2>&1)
if echo "$out" | grep -q "sourced diag.env" && echo "$out" | grep -q "RAN=$GAMEDIR/v2/solarus-run"; then
  ok "T7 diag.env is sourced (SOLARUS_ENGINE=2 from it takes effect)"
else bad "T7 diag.env" "$out"; fi
rm -f "$GAMEDIR/diag.env"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "FAILURES: $fails"; exit 1; fi
