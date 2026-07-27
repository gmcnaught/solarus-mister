#!/bin/sh
# Release-candidate test driver. See docs/release-testing.md.
#
#   release_test.sh gate1 <rc-tag> [--zip PATH]
#   release_test.sh gate2 <rc-tag> [--host IP] [--soak-min N]
#   release_test.sh gate4 <release-tag> --rc <rc-tag>
#   release_test.sh all   <rc-tag>     [--host IP]
#
# Exits non-zero if any check emitted a FAIL row.
set -u
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd)
RC_WF_PATHSPEC="$ROOT/scripts/lib/wf_pathspec.py"; export RC_WF_PATHSPEC
. "$ROOT/scripts/lib/release_check.sh"

HOST=192.168.20.81
SOAK_MIN=10
ZIP=""
RC_TAG=""

usage() { sed -n '2,10p' "$0"; exit 2; }

CMD="${1:-}"; [ -n "$CMD" ] || usage; shift
TAG="${1:-}"; [ -n "$TAG" ] || usage; shift
while [ $# -gt 0 ]; do
    case "$1" in
        --host)     HOST="$2"; shift 2 ;;
        --soak-min) SOAK_MIN="$2"; shift 2 ;;
        --zip)      ZIP="$2"; shift 2 ;;
        --rc)       RC_TAG="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done

WORK="$ROOT/_rc/$TAG"
mkdir -p "$WORK"
RESULTS="$WORK/results.tsv"

# Render the accumulated rows and set the exit status.
rc_report() {
    echo
    printf '%-6s %-8s %-34s %s\n' STATUS GATE CHECK DETAIL
    printf '%-6s %-8s %-34s %s\n' ------ ------ ---------------------------------- ------
    awk -F'\t' '{printf "%-6s %-8s %-34s %s\n", $1, $2, $3, $4}' "$RESULTS"
    _n=$(grep -c '^FAIL' "$RESULTS" 2>/dev/null || true)
    _n=${_n:-0}
    echo
    if [ "$_n" -eq 0 ]; then
        echo "ALL CHECKS PASSED ($(wc -l < "$RESULTS" | tr -d ' ') checks)"
        return 0
    fi
    echo "FAILURES: $_n"
    return 1
}

gate1() {
    echo "== Gate 1: provenance + structure =="
    if [ -n "$ZIP" ]; then
        cp "$ZIP" "$WORK/rc.zip"
    else
        echo "-- downloading $TAG asset"
        ( cd "$WORK" && rm -f ./*.zip \
          && gh release download "$TAG" --pattern '*.zip' --clobber ) \
          || { rc_fail gate1 "download asset" "gh release download failed" >> "$RESULTS"; return 0; }
        mv "$WORK"/solarus-mister-*.zip "$WORK/rc.zip" 2>/dev/null || true
    fi
    rc_pass gate1 "download asset" "$(wc -c < "$WORK/rc.zip" | tr -d ' ') bytes" >> "$RESULTS"

    rm -rf "$WORK/tree"; mkdir -p "$WORK/tree"
    unzip -q -o "$WORK/rc.zip" -d "$WORK/tree" \
      || { rc_fail gate1 "unzip" "extract failed" >> "$RESULTS"; return 0; }

    M="$WORK/tree/BUILD-INFO.txt"
    rc_manifest_check    "$M"                        >> "$RESULTS"
    rc_provenance_check  "$ROOT" "$TAG" "$M"         >> "$RESULTS"
    rc_structure_check   "$WORK/tree" "$M"           >> "$RESULTS"

    # version.txt at the tagged commit must name the shipped RBF.
    _vt=$(git -C "$ROOT" show "$TAG:version.txt" 2>/dev/null | tr -d '\r\n ')
    _rf=$(rc_get "$M" rbf_file)
    if [ "$_vt" = "$_rf" ]; then
        rc_pass gate1 "version.txt matches rbf" "$_rf" >> "$RESULTS"
    else
        rc_fail gate1 "version.txt matches rbf" "version.txt='$_vt' rbf_file='$_rf'" >> "$RESULTS"
    fi

    echo "rbf_run_id=$(rc_get "$M" rbf_run_id)"       > "$WORK/pins.env"
    echo "engine_run_id=$(rc_get "$M" engine_run_id)" >> "$WORK/pins.env"
}

case "$CMD" in
    gate1) : > "$RESULTS"; gate1 ;;
    *)     usage ;;
esac
rc_report
