#!/bin/sh
# Host test for resolve_quest() in games/Solarus/quest_lib.sh (productionization #2).
# resolve_quest <s0_file> [fatroot] -> echoes the resolved quest file path, or nothing.
set -u
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "$HERE/../games/Solarus/quest_lib.sh"
TMP=$(mktemp -d)
FAT="$TMP/fat"            # fake /media/fat
QDIR="$FAT/games/Solarus/quests"
mkdir -p "$QDIR"
: > "$QDIR/zelda.sol"     # an installed quest
fails=0
ok()  { echo "  PASS $1"; }
bad() { echo "  FAIL $1 (got: '$2')"; fails=$((fails+1)); }

echo "== resolve_quest (productionization #2: OSD quest select) =="

# T1: OSD writes a /media/fat-relative path -> resolve against fatroot
printf 'games/Solarus/quests/zelda.sol\n' > "$TMP/s0"
r=$(resolve_quest "$TMP/s0" "$FAT")
[ "$r" = "$QDIR/zelda.sol" ] && ok "T1 relative path resolves against fatroot" || bad "T1 relative" "$r"

# T2: absolute path that exists -> returned as-is
printf '%s\n' "$QDIR/zelda.sol" > "$TMP/s0"
r=$(resolve_quest "$TMP/s0" "$FAT")
[ "$r" = "$QDIR/zelda.sol" ] && ok "T2 absolute existing path" || bad "T2 absolute" "$r"

# T3: selected file does not exist -> empty
printf 'games/Solarus/quests/missing.sol\n' > "$TMP/s0"
r=$(resolve_quest "$TMP/s0" "$FAT")
[ -z "$r" ] && ok "T3 missing file -> empty" || bad "T3 missing" "$r"

# T4: trailing CR + junk after .sol (MiSTer may not truncate) -> cut at .sol, resolve
printf 'games/Solarus/quests/zelda.sol\r\x00junk' > "$TMP/s0"
r=$(resolve_quest "$TMP/s0" "$FAT")
[ "$r" = "$QDIR/zelda.sol" ] && ok "T4 CR/junk suffix tolerated" || bad "T4 junk" "$r"

# T5: empty / no .s0 -> empty
: > "$TMP/s0"
r=$(resolve_quest "$TMP/s0" "$FAT")
[ -z "$r" ] && ok "T5 empty .s0 -> empty" || bad "T5 empty" "$r"
r=$(resolve_quest "$TMP/does_not_exist" "$FAT")
[ -z "$r" ] && ok "T5b absent .s0 -> empty" || bad "T5b absent" "$r"

rm -rf "$TMP"
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "FAILURES: $fails"; exit 1; fi
