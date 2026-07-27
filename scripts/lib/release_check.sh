# Pure helpers for the release-test gates. Sourced, never executed.
#
# Every check emits exactly one TSV row on stdout:
#   STATUS<TAB>GATE<TAB>CHECK<TAB>DETAIL
# so the driver can tee them to results.tsv and the host test can assert on
# them without a device, a network, or gh.

RC_KEYS="tag commit built_utc rbf_run_id rbf_head_sha rbf_file engine_run_id engine_head_sha sha256_rbf sha256_solarus_run sha256_libsolarus"

rc_pass() { printf 'PASS\t%s\t%s\t%s\n' "$1" "$2" "${3:-}"; }
rc_fail() { printf 'FAIL\t%s\t%s\t%s\n' "$1" "$2" "${3:-}"; }

# rc_get <manifest> <key> -> value on stdout ('' if absent)
# tr strips CR first: a manifest that has been through FAT or a Windows editor
# would otherwise yield values with a trailing \r that compare unequal.
rc_get() {
    [ -f "$1" ] || return 0
    tr -d '\r' < "$1" | sed -n "s/^$2=//p" | head -1
}

# rc_manifest_check <manifest> -> rows
rc_manifest_check() {
    _m="$1"
    if [ ! -f "$_m" ]; then
        rc_fail gate1 "manifest present" "no BUILD-INFO.txt at $_m"
        return 0
    fi
    _bad=""
    for _k in $RC_KEYS; do
        [ -n "$(rc_get "$_m" "$_k")" ] || _bad="$_bad $_k"
    done
    if [ -n "$_bad" ]; then
        rc_fail gate1 "manifest keys" "missing/empty:$_bad"
    else
        rc_pass gate1 "manifest keys" "11/11 present"
    fi
}
