#!/bin/bash
# SystemVerilog structural lint (issue #92) — RATCHET gate. hdl-lint.yaml flags real
# defects (inferred latches, blocking-in-sequential, deep mux chains), but the
# legacy RTL still carries pre-existing findings that are out of this change's scope
# to fix. So this gate is diff-scoped: it FAILS on any finding in the .sv/.svh/.v
# files CHANGED vs the merge base, and only REPORTS (never fails on) the whole-tree
# baseline. New/edited RTL must be clean; legacy is grandfathered until cleaned up.
#
# Needs the custom SystemVerilog grammar — provisions it if absent.
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v ast-grep >/dev/null 2>&1 || { echo "FATAL: ast-grep not on PATH (npm i -g @ast-grep/cli)"; exit 1; }
[ -f .ast-grep/systemverilog.so ] || bash scripts/provision_ast_grep_sv.sh

# Count findings in a captured JSON string (ast-grep may exit non-zero, so capture
# with `|| true` first and count from the variable — never pipe under pipefail).
count_json() { printf '%s' "$1" | python3 -c "import sys,json;print(len(json.load(sys.stdin)))" 2>/dev/null || echo -1; }

# Whole-tree baseline — informational only (visibility into the legacy debt).
base_json=$(ast-grep scan -c sgconfig.yml fpga --json 2>/dev/null || true)
base_n=$(count_json "$base_json")
echo "[hdl-lint] whole-tree baseline (informational): $base_n finding(s) across fpga/"

# Changed SV files vs the merge base (BASE_REF override for CI/local).
BASE_REF="${BASE_REF:-origin/master}"
base_sha=$(git merge-base HEAD "$BASE_REF" 2>/dev/null || echo "$BASE_REF")
mapfile -t changed < <(git diff --name-only "$base_sha" HEAD -- '*.sv' '*.svh' '*.v' 2>/dev/null | while read -r f; do [ -f "$f" ] && echo "$f"; done)

if [ "${#changed[@]}" -eq 0 ]; then
  echo "HDL-LINT OK — no changed SystemVerilog files to gate (vs $BASE_REF)"
  exit 0
fi
echo "[hdl-lint] gating ${#changed[@]} changed SV file(s) vs $base_sha"
printf '  %s\n' "${changed[@]}"

changed_json=$(ast-grep scan -c sgconfig.yml "${changed[@]}" --json 2>/dev/null || true)
n=$(count_json "$changed_json")
if [ "$n" -lt 0 ]; then
  echo "FATAL: ast-grep scan produced no parseable JSON (grammar/tool error)"; exit 1
fi
if [ "$n" -gt 0 ]; then
  echo "HDL-LINT FAIL — $n finding(s) in changed SV files:"
  ast-grep scan -c sgconfig.yml "${changed[@]}" || true
  exit 1
fi
echo "HDL-LINT OK — 0 findings in ${#changed[@]} changed SV file(s)"
