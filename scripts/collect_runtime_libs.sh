#!/bin/bash
#
# Task 006: collect the armhf runtime shared-library closure for solarus-run.
# Walks DT_NEEDED transitively from build/armhf/{solarus-run,libsolarus*} using
# the :armhf libs installed in the build image, copies the ones we must SHIP into
# deploy/libs/, and reports max GLIBC symbol version per lib (must be <= MiSTer's
# Buildroot glibc — same focal/<=2.31 constraint as the Mesa/gmloader deploy).
#
# Run inside solarus-armhf-build:bullseye (scripts/docker_run.sh handles the
# /src mount + linked-worktree .git):
#   scripts/docker_run.sh scripts/collect_runtime_libs.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

LIBDIR=/usr/lib/arm-linux-gnueabihf
OUT=deploy/libs
mkdir -p "$OUT"

# Where to resolve each NEEDED soname, IN PRIORITY ORDER:
#   1. work/sdl2-prefix/lib -- our lean, from-source SDL2 (scripts/build_sdl2.sh).
#      MUST win over the stock :armhf libSDL2 in /usr/lib: both export the same
#      soname (libSDL2-2.0.so.0), but only the lean one has NO X11/Wayland/GBM/
#      DRM/PulseAudio(->dbus) DT_NEEDEDs. Resolving stock here would re-ship that
#      whole heavyweight subtree (and MiSTer lacks those libs).
#   2. /usr/lib/arm-linux-gnueabihf -- the stock :armhf multiarch dir.
#   3. build/luajit-armhf/lib -- our from-source LuaJIT (scripts/build_luajit.sh);
#      libluajit-5.1.so.2 is a libsolarus DT_NEEDED that does NOT exist in any
#      system dir, so without this it WARNed "cannot locate" and was never shipped
#      by this script (previously hand-placed).
#   4. /lib/arm-linux-gnueabihf -- some runtime sonames (e.g. libdbus-1.so.3)
#      live here, NOT under /usr/lib; searching only /usr/lib silently dropped
#      them from the closure (the "missing library" class of deploy failure).
SEARCH_DIRS=("$(pwd)/work/sdl2-prefix/lib" "$(pwd)/build/luajit-armhf/lib" \
             "$LIBDIR" /lib/arm-linux-gnueabihf)

# Resolve a soname to a real file across SEARCH_DIRS (exact name, then glob).
locate_soname() {
  local name="$1" d cand
  for d in "${SEARCH_DIRS[@]}"; do
    if [ -e "$d/$name" ]; then echo "$d/$name"; return 0; fi
    # shellcheck disable=SC2012  # sonames are simple ([A-Za-z0-9._+-]); ls-glob is fine and pipes to head
    cand=$(ls "$d/$name"* 2>/dev/null | head -1 || true)
    if [ -n "$cand" ]; then echo "$cand"; return 0; fi
  done
  return 1
}

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
  # locate the soname across SEARCH_DIRS (lean SDL2 prefix first, then multiarch)
  path="$(locate_soname "$name" || true)"
  if echo "$name" | grep -Eq "$SKIP_RE"; then
    echo "skip (on device): $name"
  else
    if [ -n "$path" ] && [ -e "$path" ]; then
      ship+=("$name")
      # copy following symlinks to the real file, but keep the soname filename
      cp -L "$path" "$OUT/$name"
    else
      echo "WARN: cannot locate $name in ${SEARCH_DIRS[*]}" >&2
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
