#!/bin/bash
# Capture the "golden tree" = the exact upstream source as patched by the CURRENT
# build_engine.sh patch phase, EXCLUDING the whole-file additions that
# patches/mister/** injects (those come from the cp step, not the git series).
# Run in-container (GNU sed/coreutils) so tool drift never pollutes the reference.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?usage: capture_golden.sh <out_dir>}"
SRC="work/solarus"
# Run the FROZEN legacy inline patch phase (not the live build_engine.sh, which is
# cut over to the series). This keeps the equivalence gate a durable regression
# test: golden = exactly what the old inline patcher produced.
LEGACY="scripts/legacy/build_engine_patchphase.sh"
rm -rf "$SRC" "$OUT"
SOLARUS_PATCH_ONLY=1 bash "$LEGACY"
mkdir -p "$OUT"
# Copy only tracked-upstream source (git ls-files honors .gitignore and lists
# exactly upstream's tracked set — new cp'd files are untracked, so excluded).
( cd "$SRC" && git ls-files ) | while read -r f; do
  mkdir -p "$OUT/$(dirname "$f")"; cp "$SRC/$f" "$OUT/$f"
done
( cd "$OUT" && find . -type f -print0 | sort -z | xargs -0 sha1sum ) | sha1sum | awk '{print "GOLDEN " $1}'
