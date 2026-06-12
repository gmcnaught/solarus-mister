#!/bin/bash
#
# Package a Solarus quest into a single-file .sol archive for the MiSTer OSD.
#
# A .sol IS a Solarus data.solarus archive: a zip of the quest's data/ CONTENTS
# (the quest files sit at the ROOT of the zip, NOT under a data/ prefix). MiSTer
# CONF_STR extensions are 3 chars, so the OSD file browser filters on "SOL".
#
# Usage:
#   scripts/package_quest.sh <quest_dir> [output.sol]
#
#   <quest_dir>  a Solarus quest directory containing data/ (with
#                project_db.dat etc.), OR a directory that already has a
#                data.solarus / data.solarus.zip archive.
#   [output.sol] output path. Default: deploy/quests/<basename>.sol
#
# Examples:
#   scripts/package_quest.sh deploy/quests/mystery_of_solarus_dx
#   scripts/package_quest.sh /path/to/zsdx mystery_of_solarus_dx.sol
#
set -euo pipefail

SRC="${1:?usage: package_quest.sh <quest_dir> [output.sol]}"
SRC="${SRC%/}"

if [ ! -d "$SRC" ]; then
  echo "error: not a directory: $SRC" >&2
  exit 1
fi

NAME="$(basename "$SRC")"
OUT="${2:-deploy/quests/${NAME}.sol}"
OUT_ABS="$(cd "$(dirname "$OUT")" 2>/dev/null && pwd)/$(basename "$OUT")" || {
  mkdir -p "$(dirname "$OUT")"
  OUT_ABS="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
}
mkdir -p "$(dirname "$OUT_ABS")"

command -v zip >/dev/null 2>&1 || { echo "error: 'zip' not found" >&2; exit 1; }

DATADIR=""
if [ -d "$SRC/data" ]; then
  DATADIR="$SRC/data"
elif [ -f "$SRC/data.solarus" ]; then
  echo "Quest already packaged: $SRC/data.solarus -> $OUT_ABS"
  cp -f "$SRC/data.solarus" "$OUT_ABS"
  echo "Wrote $OUT_ABS ($(du -h "$OUT_ABS" | cut -f1))"
  exit 0
elif [ -f "$SRC/data.solarus.zip" ]; then
  echo "Quest already packaged: $SRC/data.solarus.zip -> $OUT_ABS"
  cp -f "$SRC/data.solarus.zip" "$OUT_ABS"
  echo "Wrote $OUT_ABS ($(du -h "$OUT_ABS" | cut -f1))"
  exit 0
else
  echo "error: $SRC has no data/ dir or data.solarus archive" >&2
  exit 1
fi

# Sanity check: a Solarus quest data/ contains project_db.dat.
if [ ! -f "$DATADIR/project_db.dat" ]; then
  echo "warning: $DATADIR has no project_db.dat — is this a Solarus quest data/ dir?" >&2
fi

echo "Packaging $DATADIR/* -> $OUT_ABS"
rm -f "$OUT_ABS"
# Zip the CONTENTS of data/ (quest files at the zip root).
( cd "$DATADIR" && zip -rq "$OUT_ABS" . )

echo "Wrote $OUT_ABS ($(du -h "$OUT_ABS" | cut -f1))"
echo
echo "Top-level entries in the archive (should be quest files, NOT a data/ prefix):"
unzip -l "$OUT_ABS" 2>/dev/null | awk 'NR>3 {print $4}' | grep -v '^$' | sed 's#/.*##' | sort -u | head -20
