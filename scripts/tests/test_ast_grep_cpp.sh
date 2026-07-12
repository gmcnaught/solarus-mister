#!/bin/bash
# GATING C++ structural lint (issue #92). Runs the cache-without-invalidate rule
# over the MiSTer-authored engine C++ and FAILS on any finding. C++ is an ast-grep
# BUILT-IN language, so this must NOT need the custom SystemVerilog grammar.
#
# Gotcha (why the -c below): `ast-grep scan` AUTO-DISCOVERS the repo-root
# sgconfig.yml and EAGERLY loads customLanguages.systemverilog (its libraryPath
# .ast-grep/systemverilog.so) even for a `--rule` cpp scan — so without the grammar
# built it errors "cannot load custom language library" and the gate FATALs. We
# override discovery with a minimal, customLanguages-free project config so this
# job stays grammar-free and cheap.
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v ast-grep >/dev/null 2>&1 || { echo "FATAL: ast-grep not on PATH (npm i -g @ast-grep/cli)"; exit 1; }

RULE="rules/cpp-cache-invalidate.yaml"
SCAN_PATHS=("patches/mister")

# Minimal project config: no customLanguages -> no SV grammar load. `--rule` still
# drives the actual scan, so the empty ruleDirs is irrelevant to what runs.
CFG=$(mktemp); trap 'rm -f "$CFG"' EXIT
printf 'ruleDirs: []\n' > "$CFG"
scan() { ast-grep scan -c "$CFG" --rule "$RULE" "${SCAN_PATHS[@]}" "$@"; }

echo "[cpp-lint] $RULE over ${SCAN_PATHS[*]}"
json=$(scan --json 2>/dev/null || true)
n=$(printf '%s' "$json" | python3 -c "import sys,json;print(len(json.load(sys.stdin)))" 2>/dev/null || echo -1)

if [ "$n" -lt 0 ]; then
  echo "FATAL: ast-grep scan produced no parseable JSON (rule/tool error)"
  echo "---- stderr ----"; scan --json || true
  exit 1
fi
if [ "$n" -gt 0 ]; then
  echo "CPP-LINT FAIL — $n cache-without-invalidate finding(s):"
  scan || true
  exit 1
fi
echo "CPP-LINT OK — 0 findings"
