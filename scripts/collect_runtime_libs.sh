#!/bin/bash
#
# Task 006: collect the armhf runtime shared-library closure for solarus-run.
# Walks DT_NEEDED transitively from build/armhf/{solarus-run,libsolarus*} using
# the :armhf libs installed in the build image, copies the ones we must SHIP into
# deploy/libs/, and reports max GLIBC symbol version per lib (must be <= MiSTer's
# Buildroot glibc — same focal/<=2.31 constraint as the Mesa/gmloader deploy).
#
# Run inside solarus-armhf-build:bullseye:
#   docker run --rm -v "$(pwd):/src" -w /src solarus-armhf-build:bullseye scripts/collect_runtime_libs.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

LIBDIR=/usr/lib/arm-linux-gnueabihf
OUT=deploy/libs
mkdir -p "$OUT"

# Libs the MiSTer already provides in /usr/lib — do NOT ship (per gmloader recipe:
# device has libstdc++, libgcc_s, libz, libexpat; plus the glibc core set).
SKIP_RE='^(ld-linux|libc|libm|libdl|libpthread|librt|libresolv|libutil|libstdc\+\+|libgcc_s|libz|libexpat)\.'

declare -A seen
queue=()

enqueue_needed() {
  local f="$1"
  arm-linux-gnueabihf-readelf -d "$f" 2>/dev/null \
    | awk -F'[][]' '/\(NEEDED\)/{print $2}' \
    | while read -r n; do echo "$n"; done
}

# Seed from the built artifacts.
for f in build/armhf/solarus-run build/armhf/libsolarus.so.*; do
  [ -f "$f" ] || continue
  while read -r n; do queue+=("$n"); done < <(enqueue_needed "$f")
done

# BFS the closure.
ship=()
while [ ${#queue[@]} -gt 0 ]; do
  name="${queue[0]}"; queue=("${queue[@]:1}")
  [ -n "${seen[$name]:-}" ] && continue
  seen[$name]=1
  # locate the soname in the multiarch dir
  path="$LIBDIR/$name"
  if [ ! -e "$path" ]; then
    # try resolving without exact symlink
    path=$(ls "$LIBDIR/$name"* 2>/dev/null | head -1 || true)
  fi
  if echo "$name" | grep -Eq "$SKIP_RE"; then
    echo "skip (on device): $name"
  else
    if [ -n "$path" ] && [ -e "$path" ]; then
      ship+=("$name")
      # copy following symlinks to the real file, but keep the soname filename
      cp -L "$path" "$OUT/$name"
    else
      echo "WARN: cannot locate $name in $LIBDIR" >&2
    fi
  fi
  # recurse into this lib's NEEDED
  if [ -n "$path" ] && [ -e "$path" ]; then
    while read -r n; do queue+=("$n"); done < <(enqueue_needed "$path")
  fi
done

echo ""
echo "=== SHIP set ($OUT) ==="
ls -1 "$OUT"
echo ""
echo "=== max GLIBC symbol version per shipped lib (must be <= MiSTer ~2.31) ==="
for so in "$OUT"/*; do
  v=$(arm-linux-gnueabihf-objdump -T "$so" 2>/dev/null \
      | grep -oE 'GLIBC_[0-9]+\.[0-9]+(\.[0-9]+)?' \
      | sort -V | tail -1)
  printf '  %-28s %s\n' "$(basename "$so")" "${v:-none}"
done
