#!/bin/bash
# TEETH test for the CDC edge-detect rule (issue #114). A reintroduction-guard is
# worthless if it silently matches nothing — the other ast-grep tests only assert
# "0 findings on real code", which a broken rule (wrong kind name, typo'd regex)
# passes forever. This test proves the rule actually FIRES on the known-bad
# #103/#104 pattern and stays QUIET on the resolved-stage fix, so the guard can't
# rot into a no-op.
#
# Needs the custom SystemVerilog grammar (rule is SV) — provisions it if absent,
# then scans through the real project sgconfig.yml (which loads the grammar) with
# --rule restricting to just the CDC rule. Fixtures are written to a tmp dir, NOT
# committed as .sv files, so the hdl-lint ratchet gate (which scans changed *.sv)
# never trips over an intentionally-bad fixture.
set -euo pipefail
cd "$(dirname "$0")/../.."

command -v ast-grep >/dev/null 2>&1 || { echo "FATAL: ast-grep not on PATH (npm i -g @ast-grep/cli)"; exit 1; }
[ -f .ast-grep/systemverilog.so ] || bash scripts/provision_ast_grep_sv.sh

RULE="rules/hdl-cdc-edge-detect.yaml"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# BAD — every operand-[0] edge-detect the rule must catch: rising/falling edge,
# with the [0] operand on either side of the &.
cat > "$tmp/bad.sv" <<'EOF'
module cdc_bad;
  // #103/#104 shape: edge-detect on bit [0] (still-metastable, 1 FF from async)
  wire bad_rise_a = ~new_line_sync[1] & new_line_sync[0];
  wire bad_rise_b =  new_line_sync[0] & ~new_line_sync[1];
  wire bad_fall_a =  vs_sync[2] & ~vs_sync[0];
  wire bad_fall_b = ~vs_sync[0] & vs_sync[2];
endmodule
EOF

# GOOD — the resolved-stage fix ([2]&[1]) plus a non-sync combinational decode that
# must NOT be mistaken for a CDC edge-detect.
cat > "$tmp/good.sv" <<'EOF'
module cdc_good;
  wire good_a = ~new_frame_sync[2] & new_frame_sync[1];  // resolved stages
  wire good_b =  vs_sync[2] & ~vs_sync[1];               // resolved stages
  wire decode = ~state[1] & state[0];                    // non-sync decode, not CDC
endmodule
EOF

# ast-grep exits non-zero when it finds ERROR-severity results, so under `pipefail`
# never pipe it directly — capture with `|| true` first, then count from the string
# (mirrors test_ast_grep_hdl.sh). Prints -1 on unparseable JSON (grammar/tool error).
count() {
  local json
  json=$(ast-grep scan -c sgconfig.yml --rule "$RULE" "$1" --json 2>/dev/null || true)
  printf '%s' "$json" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)))' 2>/dev/null || echo -1
}

bad=$(count "$tmp/bad.sv")
good=$(count "$tmp/good.sv")
echo "[cdc-lint] bad-fixture findings=$bad (expect 4)   good-fixture findings=$good (expect 0)"

fail=0
if [ "$bad" -lt 4 ]; then
  echo "CDC-LINT FAIL — rule has NO TEETH: matched $bad/4 known-bad edge-detects"
  ast-grep scan -c sgconfig.yml --rule "$RULE" "$tmp/bad.sv" || true
  fail=1
fi
if [ "$good" -ne 0 ]; then
  echo "CDC-LINT FAIL — FALSE POSITIVE: $good finding(s) on resolved-stage/decode code"
  ast-grep scan -c sgconfig.yml --rule "$RULE" "$tmp/good.sv" || true
  fail=1
fi
[ "$fail" -eq 0 ] || exit 1
echo "CDC-LINT OK — rule fires on all 4 known-bad forms, clean on resolved-stage + decode"
