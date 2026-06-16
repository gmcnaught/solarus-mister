# quest_lib.sh — shared Solarus quest resolution (productionization #2).
# Sourced by solarus_run.sh (launch) and quest_manager.sh (wait/switch) so the
# OSD-selection logic has one correct implementation. No side effects on source.

# resolve_quest <s0_file> [fatroot]
#   Reads the OSD selection that MiSTer wrote to the .s0 config and echoes the
#   resolved quest .sol path, or nothing if there is no valid selection.
#   The OSD writes a path relative to the MiSTer root (/media/fat) and may not
#   truncate trailing bytes, so we cut at the first ".sol" and resolve both
#   as-given and fatroot-relative.
resolve_quest() {
    _s0="$1"
    _fat="${2:-${FATROOT:-/media/fat}}"
    [ -f "$_s0" ] || return 0

    _raw=$(tr -d '\r\000' < "$_s0")
    _sel="${_raw%%.sol*}"           # cut everything after the first .sol
    [ -n "$_sel" ] || return 0
    _sel="${_sel}.sol"
    # strip leading/trailing whitespace
    _sel=$(printf '%s' "$_sel" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$_sel" ] || return 0

    if [ -f "$_sel" ]; then
        printf '%s\n' "$_sel"
        return 0
    fi
    # /media/fat-relative (the usual OSD form)
    case "$_sel" in
        /*) : ;;                    # absolute, already tried above
        *)  if [ -f "$_fat/$_sel" ]; then printf '%s\n' "$_fat/$_sel"; return 0; fi ;;
    esac
    return 0
}
