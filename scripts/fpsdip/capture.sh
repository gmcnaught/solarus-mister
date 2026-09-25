#!/bin/bash
# Host: run one fps-dip capture on the device, pull it, analyse it.
#   capture.sh <tag> <seconds> <engine subdir of $DEVDIR or ""> [ENV=val ...]
# Env passed as trailing args goes to run.sh (PROF=1, SCHED=1, EXTRA_ENV="...", SEED=...).
# HOST (default 192.168.20.62), DEVDIR (default /media/fat/games/Solarus/fpsdip),
# OUT (default docs/superpowers/data/fpsdip).
set -euo pipefail
TAG=$1; SECS=$2; ENG=$3; shift 3
HOST=${HOST:-192.168.20.62}
DEVDIR=${DEVDIR:-/media/fat/games/Solarus/fpsdip}
OUT=${OUT:-docs/superpowers/data/fpsdip}
ENV_ARGS=""
for kv in "$@"; do ENV_ARGS="$ENV_ARGS $(printf '%q' "$kv")"; done
ENGPATH=""; [ -n "$ENG" ] && ENGPATH="$DEVDIR/$ENG"
ssh "root@$HOST" "cd $DEVDIR && env $ENV_ARGS ./run.sh $TAG $SECS $ENGPATH > /tmp/fpsdip_run.out 2>&1; tail -1 /tmp/fpsdip_run.out"
mkdir -p "$OUT"
rm -rf "${OUT:?}/$TAG"
scp -q -r "root@$HOST:/media/fat/logs/Solarus/fpsdip/$TAG" "$OUT/"
python3 "$(dirname "$0")/frames.py" "$OUT/$TAG" $( [ -f "$OUT/$TAG/prof.txt.gz" ] && echo --prof ) > "$OUT/$TAG.txt"
head -12 "$OUT/$TAG.txt"
