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

RC_SCRIPTS="_handler.sh solarus_run.sh quest_manager.sh quest_lib.sh core_watch.sh solarus_daemon.sh"

# rc_structure_check <extracted-root> <manifest> -> rows
rc_structure_check() {
    _r="$1"; _m="$2"
    _g="$_r/games/Solarus"

    # Exactly one RBF. More than one means the OSD can load the wrong core
    # against this engine — a silent garbage-tile pairing, since there is no
    # engine<->RBF version handshake.
    _n=$(find "$_r/_Other" -maxdepth 1 -type f -name 'Solarus_*.rbf' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$_n" = "1" ]; then rc_pass gate1 "single rbf" "$_n"
    else rc_fail gate1 "single rbf" "found $_n, expected 1"; fi

    # The RBF present is the one the manifest names.
    _want=$(rc_get "$_m" rbf_file)
    if [ -n "$_want" ] && [ -f "$_r/_Other/$_want" ]; then
        rc_pass gate1 "rbf matches manifest" "$_want"
    else
        rc_fail gate1 "rbf matches manifest" "manifest names '$_want', not present"
    fi

    # Engine is a 32-bit ARM ELF (file(1) exists on macOS and ubuntu).
    #
    # RC_ALLOW_FIXTURE=1 relaxes this to an ELF-magic check so the host test
    # can use cheap synthetic trees. It is set ONLY by tests/release_test_test.sh.
    # A real release run leaves it unset, so `file` is the only way to pass —
    # a truncated 4-byte engine must not slip through a release gate.
    if file "$_g/solarus-run" 2>/dev/null | grep -q 'ELF 32-bit.*ARM'; then
        rc_pass gate1 "engine is armhf ELF"
    elif [ "${RC_ALLOW_FIXTURE:-0}" = "1" ] \
         && head -c 4 "$_g/solarus-run" 2>/dev/null | grep -q 'ELF'; then
        rc_pass gate1 "engine is armhf ELF" "magic only (RC_ALLOW_FIXTURE)"
    else
        rc_fail gate1 "engine is armhf ELF" "not a 32-bit ARM ELF"
    fi

    # Lib closure size.
    _l=$(find "$_g/libs" -maxdepth 1 -type f -name '*.so*' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$_l" -ge 20 ]; then rc_pass gate1 "lib closure" "$_l libs"
    else rc_fail gate1 "lib closure" "only $_l libs, expected >=20"; fi

    # Both libsolarus names must be REAL FILES — FAT cannot carry the symlink.
    for _n2 in libsolarus.so.1 libsolarus.so.1.6.5; do
        if [ -L "$_g/libs/$_n2" ]; then
            rc_fail gate1 "libsolarus real file" "$_n2 is a symlink (FAT cannot ship it)"
        elif [ -f "$_g/libs/$_n2" ]; then
            rc_pass gate1 "libsolarus real file" "$_n2"
        else
            rc_fail gate1 "libsolarus real file" "$_n2 missing"
        fi
    done

    # Required scripts + data files, present and executable.
    for _s in $RC_SCRIPTS; do
        if [ ! -f "$_g/$_s" ]; then rc_fail gate1 "script present" "$_s missing"
        elif [ ! -x "$_g/$_s" ]; then rc_fail gate1 "script present" "$_s not executable"
        else rc_pass gate1 "script present" "$_s"; fi
    done
    for _f in "$_g/controls.cfg.default" "$_r/Scripts/Solarus.sh" "$_r/docs/Solarus/README.md"; do
        if [ -f "$_f" ]; then rc_pass gate1 "file present" "${_f#"$_r"/}"
        else rc_fail gate1 "file present" "${_f#"$_r"/} missing"; fi
    done
    if [ -f "$_r/Scripts/Solarus.sh" ] && [ ! -x "$_r/Scripts/Solarus.sh" ]; then
        rc_fail gate1 "script present" "Scripts/Solarus.sh not executable"
    fi

    # No CRLF in any shipped shell script. Match a literal CR byte via a
    # command-substituted printf rather than a \r regex escape: BSD awk/grep
    # (macOS) don't expand \r the way GNU does (grep -P is GNU-only, and BSD
    # awk's own /\r/ silently never matches), but a literal CR byte in the
    # pattern works identically under both.
    _crlf=""
    _cr=$(printf '\r')
    for _s in $(find "$_r" -name '*.sh' -type f 2>/dev/null); do
        grep -q "$_cr" "$_s" 2>/dev/null && _crlf="$_crlf ${_s#"$_r"/}"
    done
    if [ -n "$_crlf" ]; then rc_fail gate1 "no CRLF" "$_crlf"
    else rc_pass gate1 "no CRLF"; fi

    # No macOS AppleDouble cruft.
    _ad=$(find "$_r" \( -name '._*' -o -name '__MACOSX' \) 2>/dev/null | head -5)
    if [ -n "$_ad" ]; then rc_fail gate1 "no AppleDouble" "$(echo "$_ad" | tr '\n' ' ')"
    else rc_pass gate1 "no AppleDouble"; fi

    # Engine executable bit.
    if [ -x "$_g/solarus-run" ]; then rc_pass gate1 "engine executable"
    else rc_fail gate1 "engine executable" "exec bit not set"; fi
}
