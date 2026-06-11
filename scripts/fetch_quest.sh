#!/bin/bash
#
# Fetch the first target quest: The Legend of Zelda: Mystery of Solarus DX
# (free, by the Solarus team). solarus-run accepts either a packaged .solarus
# (zip) or an unpacked quest directory containing a data/ tree, so we clone the
# official quest source and run it from the directory.
#
# Upstream quest source:
#   https://gitlab.com/solarus-games/zsdx  branch release-1.12.3
#   (the latest zsdx release targeting the Solarus 1.6 engine — quest.dat
#    solarus_version = "1.6", normal_quest_size 320x240. NOT master/dev, which
#    target Solarus 2.0 and will not load on our 1.6.5 engine.)
#
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="deploy/quests/mystery_of_solarus_dx"

if [ -d "$DEST/data" ] || [ -f "$DEST/data.solarus" ]; then
  echo "Quest already present at $DEST"; exit 0
fi

mkdir -p deploy/quests
echo "Cloning Mystery of Solarus DX quest source..."
if git clone --depth 1 --branch release-1.12.3 https://gitlab.com/solarus-games/zsdx.git "$DEST"; then
  echo "Cloned to $DEST"
  echo "Quest version file:"; cat "$DEST/data/project_db.dat" 2>/dev/null | head -1 || true
else
  echo "Clone failed. Manually place the quest at:" >&2
  echo "  $DEST/data/      (unpacked quest), or" >&2
  echo "  $DEST.solarus    (packaged quest zip)" >&2
  echo "Free download: https://www.solarus-games.org/en/games/the-legend-of-zelda-mystery-of-solarus-dx" >&2
  exit 1
fi
