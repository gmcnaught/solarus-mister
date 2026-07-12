#!/bin/bash
# Post-apply structural verification gate. Each patches/verify/*.yml rule must
# match >=1 time in the applied tree; a zero-match rule fails the build. This is
# a cheap safety net (the export round-trip, scripts/tests/test_export_roundtrip.sh,
# is the primary correctness gate).
set -euo pipefail
cd "$(dirname "$0")/.."
TREE="${1:?usage: verify_patches.sh <src_dir>}"

# ast-grep is not installed in the armhf build container; the authoritative gate
# runs on the host / CI (scripts/tests/test_verify.sh). Skip gracefully in-build.
# NOTE: check the real `ast-grep` binary — Debian ships an unrelated `sg`.
if ! command -v ast-grep >/dev/null 2>&1; then
  echo "[verify] ast-grep not present — skipping structural gate (host/CI enforces it)"
  exit 0
fi

# Minimal project config so `ast-grep scan` does NOT auto-discover the repo-root
# sgconfig.yml (issue #92): that config registers a custom SystemVerilog language
# backed by .ast-grep/systemverilog.so, and ast-grep loads it even for a `--rule`
# cpp scan — erroring out with EMPTY stdout when the grammar .so is absent (this
# gate's job does not build it, only hdl-lint does). A `ruleDirs: []` config with no
# customLanguages sidesteps that; `--rule` still drives the actual scan. Mirrors
# scripts/tests/test_ast_grep_cpp.sh.
CFG=$(mktemp); trap 'rm -f "$CFG"' EXIT
printf 'ruleDirs: []\n' > "$CFG"

fail=0
for rule in patches/verify/*.yml; do
  id=$(python3 -c "import sys,re;print(re.search(r'id:\s*(\S+)',open(sys.argv[1]).read()).group(1))" "$rule")
  json=$(ast-grep scan -c "$CFG" --rule "$rule" "$TREE" --json 2>/dev/null || true)
  n=$(printf '%s' "$json" | python3 -c "import sys,json;print(len(json.load(sys.stdin)))" 2>/dev/null || echo -1)
  if [ "$n" -lt 0 ]; then
    echo "VERIFY FAIL: $id — ast-grep produced no parseable JSON (rule/tool error):"
    ast-grep scan -c "$CFG" --rule "$rule" "$TREE" --json || true
    fail=1
  elif [ "$n" -eq 0 ]; then echo "VERIFY FAIL: $id matched 0 times"; fail=1
  else echo "verify ok: $id ($n)"; fi
done
[ "$fail" -eq 0 ] && echo "VERIFY PASS"
exit $fail
