#!/usr/bin/env bash
#
# Build the self-contained Quartus + Actions-runner image used by the TrueNAS
# build runner. Run this ON THE NAS (or wherever the runner will live) — the
# resulting image stays in the local docker daemon; nothing is pushed.
#
#   fpga/docker/build-runner-image.sh [tag]
#
# Default tag: solarus-quartus-runner:17.0
#
# Expect a long first run: it pulls ~6 GB (raetro/quartus:17.0) plus ~500 MB
# (the runner base), and the Quartus COPY layer is ~10 GB uncompressed. Budget
# 40 GB of free space in the docker dataset and 20-40 min on a NAS.
#
# The Dockerfile ends in a `quartus_sh --version` gate, so a successful build
# means the toolchain actually loads — a broken image cannot be produced.
#
# Docs: docs/truenas-quartus-runner.md
set -euo pipefail

TAG="${1:-solarus-quartus-runner:17.0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: cannot reach a docker daemon." >&2
    echo "       On TrueNAS SCALE 24.10+ the daemon runs by default; check that" >&2
    echo "       you are root, or that DOCKER_HOST is set for a rootless setup." >&2
    exit 1
fi

echo "============================================"
echo "  Building $TAG"
echo "  Dockerfile: $HERE/quartus-runner.df"
echo "============================================"

# --pull keeps the two upstream bases current. Drop it for a byte-stable
# rebuild of an image you have already validated.
docker build \
    --pull \
    --file "$HERE/quartus-runner.df" \
    --tag "$TAG" \
    "$HERE"

echo ""
echo ">>> Image built. Verifying the toolchain in the finished image:"
docker run --rm --entrypoint quartus_sh "$TAG" --version

SIZE="$(docker image inspect "$TAG" --format '{{.Size}}' | awk '{printf "%.1f GB", $1/1e9}')"
echo ""
echo "============================================"
echo "  $TAG  ($SIZE)"
echo ""
echo "  Next: point the TrueNAS custom app at this tag —"
echo "  .github/runners/truenas/quartus-runner.compose.yaml"
echo "============================================"
