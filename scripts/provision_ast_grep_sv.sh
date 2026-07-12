#!/bin/bash
# Build the SystemVerilog tree-sitter grammar that ast-grep's custom-language
# support needs (issue #92). Emits .ast-grep/systemverilog.so at the repo root —
# the relative libraryPath sgconfig.yml points at. Idempotent: skips the build if
# the .so already exists (pass -f to force).
#
# The grammar is a pinned upstream (gmlarumbe/tree-sitter-systemverilog); its
# generated src/parser.c has no external scanner, so a single `cc -shared` builds
# it. Used by CI (hdl-lint job) and local dev alike — no per-machine absolute path.
set -euo pipefail
cd "$(dirname "$0")/.."

SV_REPO="${SV_REPO:-https://github.com/gmlarumbe/tree-sitter-systemverilog.git}"
SV_REF="${SV_REF:-v0.3.1}"
OUT=".ast-grep/systemverilog.so"
CC="${CC:-cc}"

if [ "${1:-}" != "-f" ] && [ -f "$OUT" ]; then
  echo "[sv-grammar] $OUT already present — skipping (pass -f to rebuild)"
  exit 0
fi

mkdir -p .ast-grep
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "[sv-grammar] cloning $SV_REPO @ $SV_REF"
git clone -q --depth 1 --branch "$SV_REF" "$SV_REPO" "$work/g"

test -f "$work/g/src/parser.c" || { echo "FATAL: $SV_REF has no src/parser.c (grammar not pre-generated)" >&2; exit 1; }
# External scanner is optional; include it only if the grammar ships one.
scanner=""
[ -f "$work/g/src/scanner.c" ] && scanner="$work/g/src/scanner.c"

echo "[sv-grammar] compiling -> $OUT"
# shellcheck disable=SC2086
"$CC" -shared -fPIC -I "$work/g/src" "$work/g/src/parser.c" $scanner -o "$OUT"
echo "[sv-grammar] built $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
