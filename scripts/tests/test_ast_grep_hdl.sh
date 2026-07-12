#!/bin/bash
# SystemVerilog structural lint (issue #92) — RATCHET gate, diff-scoped + severity-aware.
#
# Two reasons the gate is scoped, not a blanket fail-on-any-finding:
#  1. Diff-scope: the legacy RTL carries pre-existing findings (baseline ~80) that are
#     out of this change's scope to fix, so we gate only the .sv/.svh/.v files CHANGED
#     vs the merge base and merely REPORT the whole-tree baseline. New/edited HDL must
#     be clean; legacy is grandfathered until cleaned up.
#  2. Severity-scope: hdl-lint.yaml mixes real defects (inferred latch,
#     blocking-in-sequential, async-reset issues = severity ERROR) with style/perf
#     nits (deeply-nested-ternary = severity WARNING). Only ERROR-severity findings on
#     changed files FAIL the gate; warnings are reported, not gated — a style nit in a
#     changed testbench must not wedge CI.
#
# Needs the custom SystemVerilog grammar — provisions it if absent.
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v ast-grep >/dev/null 2>&1 || { echo "FATAL: ast-grep not on PATH (npm i -g @ast-grep/cli)"; exit 1; }
[ -f .ast-grep/systemverilog.so ] || bash scripts/provision_ast_grep_sv.sh

# From a captured JSON string print "<errors> <warnings> <total>" (ast-grep may exit
# non-zero, so capture with `|| true` first and count from the variable — never pipe
# under pipefail). Prints "-1 -1 -1" if the JSON can't be parsed (grammar/tool error).
sev_counts() {
  printf '%s' "$1" | python3 -c "import sys,json,collections
d=json.load(sys.stdin); c=collections.Counter(x.get('severity') for x in d)
print(c.get('error',0), c.get('warning',0), len(d))" 2>/dev/null || echo "-1 -1 -1"
}

# Whole-tree baseline — informational only (visibility into the legacy debt).
base_json=$(ast-grep scan -c sgconfig.yml fpga --json 2>/dev/null || true)
read -r base_err base_warn base_tot <<EOF
$(sev_counts "$base_json")
EOF
echo "[hdl-lint] whole-tree baseline (informational): $base_tot finding(s) across fpga/ (err=$base_err warn=$base_warn)"

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
read -r err warn _tot <<EOF
$(sev_counts "$changed_json")
EOF
if [ "$err" -lt 0 ]; then
  echo "FATAL: ast-grep scan produced no parseable JSON (grammar/tool error)"
  ast-grep scan -c sgconfig.yml "${changed[@]}" || true
  exit 1
fi

# Print every finding on the changed files (ast-grep labels each with its severity),
# then gate purely on the error count. Errors FAIL; warnings are advisory.
if [ "$err" -gt 0 ] || [ "$warn" -gt 0 ]; then
  echo "[hdl-lint] findings in changed SV files (errors gate, warnings advisory):"
  ast-grep scan -c sgconfig.yml "${changed[@]}" || true
fi
if [ "$err" -gt 0 ]; then
  echo "HDL-LINT FAIL — $err ERROR-severity finding(s) in changed SV files ($warn warning(s) advisory)"
  exit 1
fi
echo "HDL-LINT OK — 0 error-severity findings ($warn warning(s) advisory) in ${#changed[@]} changed SV file(s)"
