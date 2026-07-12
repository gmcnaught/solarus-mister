#!/bin/bash
# GATING C++ structural lint (issue #92). Runs the cache-without-invalidate rule
# over the MiSTer-authored engine C++ and FAILS on any finding. C++ is an ast-grep
# BUILT-IN language, so this needs neither sgconfig.yml nor the custom SystemVerilog
# grammar — it runs rule-directly and is a hard gate (clean on today's tree).
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v ast-grep >/dev/null 2>&1 || { echo "FATAL: ast-grep not on PATH (npm i -g @ast-grep/cli)"; exit 1; }

RULE="rules/cpp-cache-invalidate.yaml"
SCAN_PATHS=("patches/mister")

echo "[cpp-lint] $RULE over ${SCAN_PATHS[*]}"
json=$(ast-grep scan --rule "$RULE" "${SCAN_PATHS[@]}" --json 2>/dev/null || true)
n=$(printf '%s' "$json" | python3 -c "import sys,json;print(len(json.load(sys.stdin)))" 2>/dev/null || echo -1)

if [ "$n" -lt 0 ]; then
  echo "FATAL: ast-grep scan produced no parseable JSON (rule/tool error)"; exit 1
fi
if [ "$n" -gt 0 ]; then
  echo "CPP-LINT FAIL — $n cache-without-invalidate finding(s):"
  ast-grep scan --rule "$RULE" "${SCAN_PATHS[@]}" || true
  exit 1
fi
echo "CPP-LINT OK — 0 findings"
