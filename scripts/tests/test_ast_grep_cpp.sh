#!/bin/bash
# GATING C++ structural lint (issue #92). Runs EVERY rules/cpp-*.yaml recurring-bug rule
# over the MiSTer-authored engine C++ and FAILS on any finding. C++ is an ast-grep
# BUILT-IN language, so this must NOT need the custom SystemVerilog grammar.
#
# Rules gated here (add a new rules/cpp-*.yaml and it is picked up automatically):
#   cpp-cache-invalidate.yaml    — a *cache* member with zero invalidation (#92)
#   cpp-src-off-mux-bypass.yaml  — `src_off = .off` bypassing the SDRAM source resolver (#142)
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

SCAN_PATHS=("patches/mister")

# All cpp recurring-bug rules. Sorted for stable output; every rules/cpp-*.yaml gates.
shopt -s nullglob
RULES=(rules/cpp-*.yaml)
shopt -u nullglob
if [ "${#RULES[@]}" -eq 0 ]; then echo "FATAL: no rules/cpp-*.yaml found"; exit 1; fi

# Minimal project config: no customLanguages -> no SV grammar load. `--rule` still
# drives the actual scan, so the empty ruleDirs is irrelevant to what runs.
# languageGlobs maps *.c to the cpp parser: the vendored blitter emitter is C (*.c),
# and the src_off-mux-bypass bug lives there, but a `language: cpp` rule otherwise skips
# *.c (ast-grep routes it to the `c` language). C is a structural subset of C++ for these
# patterns, so parsing *.c as cpp is safe; the cache rule finds no C classes -> no noise.
CFG=$(mktemp); trap 'rm -f "$CFG"' EXIT
printf 'ruleDirs: []\nlanguageGlobs:\n  cpp: ["*.c"]\n' > "$CFG"

# Exclude reference-model TEST files: they legitimately hand-build raw blt_cmd_t arrays
# from fixture structs to drive blt_execute (the software reference model over a CPU heap
# — no SDRAM staging, no fabric, no mux), so `cmds[i].src_off = SPR[i].off` there is
# correct and must not trip cpp-src-off-mux-bypass. The guard targets PRODUCTION emitters.
EXCLUDES=(--globs '!**/test_*.c' --globs '!**/test_*.cpp'
          --globs '!**/*_test.c' --globs '!**/*_test.cpp')

fail=0
for RULE in "${RULES[@]}"; do
  scan() { ast-grep scan -c "$CFG" --rule "$RULE" "${EXCLUDES[@]}" "${SCAN_PATHS[@]}" "$@"; }
  echo "[cpp-lint] $RULE over ${SCAN_PATHS[*]}"
  json=$(scan --json 2>/dev/null || true)
  n=$(printf '%s' "$json" | python3 -c "import sys,json;print(len(json.load(sys.stdin)))" 2>/dev/null || echo -1)

  if [ "$n" -lt 0 ]; then
    echo "FATAL: ast-grep scan produced no parseable JSON for $RULE (rule/tool error)"
    echo "---- stderr ----"; scan --json || true
    exit 1
  fi
  if [ "$n" -gt 0 ]; then
    echo "CPP-LINT FAIL — $RULE: $n finding(s):"
    scan || true
    fail=1
  else
    echo "  OK — 0 findings"
  fi
done

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "CPP-LINT OK — 0 findings across ${#RULES[@]} rule(s)"
