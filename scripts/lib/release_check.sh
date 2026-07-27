# shellcheck shell=sh
# Pure helpers for the release-test gates. Sourced, never executed.
#
# Every check emits exactly one TSV row on stdout:
#   STATUS<TAB>GATE<TAB>CHECK<TAB>DETAIL
# so the driver can tee them to results.tsv and the host test can assert on
# them without a device, a network, or gh.

RC_KEYS="tag commit built_utc rbf_run_id rbf_head_sha rbf_file engine_run_id engine_head_sha sha256_rbf sha256_solarus_run sha256_libsolarus"

# Absolute path to the pathspec parser; set by the sourcing script so the
# library works from a test, from the driver, and from any cwd.
: "${RC_WF_PATHSPEC:=}"

rc_pass() { printf 'PASS\t%s\t%s\t%s\n' "$1" "$2" "${3:-}"; }
rc_fail() { printf 'FAIL\t%s\t%s\t%s\n' "$1" "$2" "${3:-}"; }

# rc_is_digits <value> -> status 0 if value is a non-empty string of ASCII
# digits, 1 otherwise. Used to validate manifest-derived run-ids before they
# are written to pins.env — pins.env is later `.`-sourced (release_test.sh's
# rc_publish_cmd), so a value that is anything other than plain digits (e.g.
# a `$(...)` command-substitution payload smuggled into a downloaded
# BUILD-INFO.txt) must never reach that file.
rc_is_digits() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

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

# rc_structure_check <extracted-root> <manifest> [gate] -> rows
# [gate] defaults to "gate1" (Gate 1's own use); Gate 4 passes "gate4" so its
# reused structural check records the right gate in the sign-off table.
rc_structure_check() {
    _r="$1"; _m="$2"; _gate="${3:-gate1}"
    _g="$_r/games/Solarus"

    # Exactly one RBF. More than one means the OSD can load the wrong core
    # against this engine — a silent garbage-tile pairing, since there is no
    # engine<->RBF version handshake.
    _n=$(find "$_r/_Other" -maxdepth 1 -type f -name 'Solarus_*.rbf' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$_n" = "1" ]; then rc_pass "$_gate" "single rbf" "$_n"
    else rc_fail "$_gate" "single rbf" "found $_n, expected 1"; fi

    # The RBF present is the one the manifest names.
    _want=$(rc_get "$_m" rbf_file)
    if [ -n "$_want" ] && [ -f "$_r/_Other/$_want" ]; then
        rc_pass "$_gate" "rbf matches manifest" "$_want"
    else
        rc_fail "$_gate" "rbf matches manifest" "manifest names '$_want', not present"
    fi

    # Engine is a 32-bit ARM ELF (file(1) exists on macOS and ubuntu).
    #
    # RC_ALLOW_FIXTURE=1 relaxes this to an ELF-magic check so the host test
    # can use cheap synthetic trees. It is set ONLY by tests/release_test_test.sh.
    # A real release run leaves it unset, so `file` is the only way to pass —
    # a truncated 4-byte engine must not slip through a release gate.
    if file "$_g/solarus-run" 2>/dev/null | grep -q 'ELF 32-bit.*ARM'; then
        rc_pass "$_gate" "engine is armhf ELF"
    elif [ "${RC_ALLOW_FIXTURE:-0}" = "1" ] \
         && head -c 4 "$_g/solarus-run" 2>/dev/null | grep -q 'ELF'; then
        rc_pass "$_gate" "engine is armhf ELF" "magic only (RC_ALLOW_FIXTURE)"
    else
        rc_fail "$_gate" "engine is armhf ELF" "not a 32-bit ARM ELF"
    fi

    # Lib closure size.
    _l=$(find "$_g/libs" -maxdepth 1 -type f -name '*.so*' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$_l" -ge 20 ]; then rc_pass "$_gate" "lib closure" "$_l libs"
    else rc_fail "$_gate" "lib closure" "only $_l libs, expected >=20"; fi

    # Both libsolarus names must be REAL FILES — FAT cannot carry the symlink.
    for _n2 in libsolarus.so.1 libsolarus.so.1.6.5; do
        if [ -L "$_g/libs/$_n2" ]; then
            rc_fail "$_gate" "libsolarus real file" "$_n2 is a symlink (FAT cannot ship it)"
        elif [ -f "$_g/libs/$_n2" ]; then
            rc_pass "$_gate" "libsolarus real file" "$_n2"
        else
            rc_fail "$_gate" "libsolarus real file" "$_n2 missing"
        fi
    done

    # Required scripts + data files, present and executable.
    for _s in $RC_SCRIPTS; do
        if [ ! -f "$_g/$_s" ]; then rc_fail "$_gate" "script present" "$_s missing"
        elif [ ! -x "$_g/$_s" ]; then rc_fail "$_gate" "script present" "$_s not executable"
        else rc_pass "$_gate" "script present" "$_s"; fi
    done
    for _f in "$_g/controls.cfg.default" "$_r/Scripts/Solarus.sh" "$_r/docs/Solarus/README.md"; do
        if [ -f "$_f" ]; then rc_pass "$_gate" "file present" "${_f#"$_r"/}"
        else rc_fail "$_gate" "file present" "${_f#"$_r"/} missing"; fi
    done
    if [ -f "$_r/Scripts/Solarus.sh" ] && [ ! -x "$_r/Scripts/Solarus.sh" ]; then
        rc_fail "$_gate" "script present" "Scripts/Solarus.sh not executable"
    fi

    # No CRLF in any shipped shell script. Match a literal CR byte via a
    # command-substituted printf rather than a \r regex escape: an earlier
    # version used `awk '/\r/{exit 0} END{exit 1}'`, which is not a portability
    # gap — `exit` inside an awk rule still runs the END block, and that
    # block's `exit 1` overrides the rule's `exit 0`, so the whole pipeline
    # returns 1 (no match) unconditionally on every platform, GNU included. A
    # literal CR byte in a grep pattern has no such trap and works identically
    # under BSD and GNU.
    #
    # Enumerate matches via `find -exec … +` (not `for _s in $(find …)`) so a
    # path containing a space cannot be word-split into bogus entries.
    #
    # Enumeration and search are two separate find invocations, checked
    # separately: a bare `find` (no -exec) exits non-zero only on a real
    # traversal error (e.g. an unreadable subdirectory) and exits 0 whether
    # or not it printed any paths, so its status cleanly means "enumeration
    # broke". `find -exec grep -l …` conflates that with grep's own exit
    # code (1 for "no match", same as a real error), so checking ITS status
    # cannot tell "nothing found" from "broke partway" apart. A `2>/dev/null`
    # spanning that combined command hides both alike, and a broken
    # enumeration must never be read as "no CRLF found" — that would let a
    # scan that silently skipped part of the tree pass the very check it
    # broke.
    #
    # Per-file grep is scanned the same way: `grep -l …` exits 0 (match), 1
    # (no match), or >1 (a real error — e.g. an individual file that `find`
    # could enumerate, being just metadata, but cannot itself read, e.g.
    # mode 000). Silently discarding a >1 status (the old `2>/dev/null` with
    # no status check) let an unreadable file read as "no CRLF" — the same
    # fail-open hole `find`'s own enumeration status guards above. Capture
    # grep's status per file and treat >1 as its own failure, distinct from
    # both "no CRLF" and "has CRLF".
    _crlf=""
    _cr=$(printf '\r')
    _sh_files=$(find "$_r" -name '*.sh' -type f)
    _find_st=$?
    if [ "$_find_st" -ne 0 ]; then
        rc_fail "$_gate" "no CRLF" "find enumeration failed (status $_find_st)"
    else
        _matches=""
        _greperr=""
        if [ -n "$_sh_files" ]; then
            # if/elif, not `case`, deliberately: a `case ... esac` nested
            # inside a `$(...)` command substitution is mis-parsed by the
            # bash 3.2 shipped as macOS's /bin/sh (and /bin/bash) — its
            # command-substitution scanner treats the bare `)` closing a
            # case pattern (e.g. `0)`) as the end of the `$(...)`, splitting
            # the rest of the loop body off as a syntax error. Confirmed:
            # fails under macOS /bin/sh and /bin/bash 3.2.57, passes under
            # dash and bash >=4. `if`/`elif`/`fi` has no bare `)` to confuse
            # that scanner.
            _scan=$(printf '%s\n' "$_sh_files" | while IFS= read -r _f; do
                grep -q "$_cr" -- "$_f" 2>/dev/null
                _gst=$?
                if [ "$_gst" -eq 0 ]; then
                    printf 'HIT:%s\n' "$_f"
                elif [ "$_gst" -eq 1 ]; then
                    :
                else
                    printf 'ERR:%s\n' "$_f"
                fi
            done)
            if [ -n "$_scan" ]; then
                while IFS= read -r _line; do
                    case "$_line" in
                        HIT:*) _matches="$_matches${_line#HIT:}
" ;;
                        ERR:*) _greperr="$_greperr ${_line#ERR:}" ;;
                    esac
                done <<_SCAN_EOF
$_scan
_SCAN_EOF
            fi
        fi
        if [ -n "$_matches" ]; then
            while IFS= read -r _s; do
                [ -n "$_s" ] || continue
                _crlf="$_crlf ${_s#"$_r"/}"
            done <<_CRLF_EOF
$_matches
_CRLF_EOF
        fi
        if [ -n "$_greperr" ]; then
            rc_fail "$_gate" "no CRLF" "grep could not read:$_greperr (scan cannot be trusted)"
        elif [ -n "$_crlf" ]; then rc_fail "$_gate" "no CRLF" "$_crlf"
        else rc_pass "$_gate" "no CRLF"; fi
    fi

    # No macOS AppleDouble cruft.
    _ad=$(find "$_r" \( -name '._*' -o -name '__MACOSX' \) 2>/dev/null | head -5)
    if [ -n "$_ad" ]; then rc_fail "$_gate" "no AppleDouble" "$(echo "$_ad" | tr '\n' ' ')"
    else rc_pass "$_gate" "no AppleDouble"; fi

    # Engine executable bit.
    if [ -x "$_g/solarus-run" ]; then rc_pass "$_gate" "engine executable"
    else rc_fail "$_gate" "engine executable" "exec bit not set"; fi
}

# rc_stale_files <repo> <from-sha> <to-sha> <workflow.yml>
# Prints the files changed between the two commits that match the workflow's
# own trigger paths. Empty output == the artifact is current w.r.t. <to-sha>.
# Returns 2 (printing nothing) if the pathspecs cannot be derived — the caller
# MUST treat that as a FAIL, never as "nothing changed", or a parser break
# would silently pass every artifact.
rc_stale_files() {
    _repo="$1"; _from="$2"; _to="$3"; _wf="$4"
    _py="${RC_WF_PATHSPEC:-$_repo/scripts/lib/wf_pathspec.py}"
    [ -f "$_py" ] || return 2
    _specs=$(python3 "$_py" "$_wf" 2>/dev/null) || return 2
    [ -n "$_specs" ] || return 2
    # Intentional word-split: one pathspec per line, none contain spaces.
    # shellcheck disable=SC2086
    git -C "$_repo" diff --name-only "$_from" "$_to" -- $_specs
}

# rc_provenance_check <repo> <tag> <manifest> -> rows
#
# Three assertions per the spec:
#   1. the manifest's `commit` is the tag's commit
#   2. the tag is an ancestor of (or equal to) origin/master
#   3. for each artifact: its head_sha is an ancestor of the tag AND no commit
#      between them touched that workflow's own trigger paths
rc_provenance_check() {
    _repo="$1"; _tag="$2"; _m="$3"

    _tagsha=$(git -C "$_repo" rev-parse --verify "${_tag}^{commit}" 2>/dev/null)
    if [ -z "$_tagsha" ]; then
        rc_fail gate1 "tag resolves" "$_tag not found (git fetch --tags?)"
        return 0
    fi
    rc_pass gate1 "tag resolves" "$_tag -> $(echo "$_tagsha" | cut -c1-12)"

    _mc=$(rc_get "$_m" commit)
    if [ "$_mc" = "$_tagsha" ]; then
        rc_pass gate1 "manifest commit == tag"
    else
        rc_fail gate1 "manifest commit == tag" \
            "manifest $(echo "$_mc" | cut -c1-12) != tag $(echo "$_tagsha" | cut -c1-12)"
    fi

    if git -C "$_repo" merge-base --is-ancestor "$_tagsha" origin/master 2>/dev/null; then
        rc_pass gate1 "tag is on master"
    else
        rc_fail gate1 "tag is on master" "tag is not an ancestor of origin/master"
    fi

    rc_artifact_check "$_repo" "$_tagsha" "$_m" rbf    .github/workflows/build-rbf.yml
    rc_artifact_check "$_repo" "$_tagsha" "$_m" engine .github/workflows/build-engine-ship.yml
}

# rc_artifact_check <repo> <tagsha> <manifest> <rbf|engine> <workflow-relpath>
rc_artifact_check() {
    _repo="$1"; _tagsha="$2"; _m="$3"; _which="$4"; _wfrel="$5"
    _sha=$(rc_get "$_m" "${_which}_head_sha")
    _wf="$_repo/$_wfrel"

    if [ -z "$_sha" ]; then
        rc_fail gate1 "$_which built from" "no ${_which}_head_sha in manifest"
        return 0
    fi
    if ! git -C "$_repo" cat-file -e "${_sha}^{commit}" 2>/dev/null; then
        rc_fail gate1 "$_which built from" "commit $_sha not in this repo (fetch?)"
        return 0
    fi
    if git -C "$_repo" merge-base --is-ancestor "$_sha" "$_tagsha" 2>/dev/null; then
        rc_pass gate1 "$_which is an ancestor" "$(echo "$_sha" | cut -c1-12)"
    else
        rc_fail gate1 "$_which is an ancestor" \
            "$(echo "$_sha" | cut -c1-12) is not an ancestor of the tag"
        return 0
    fi

    _touched=$(rc_stale_files "$_repo" "$_sha" "$_tagsha" "$_wf")
    _st=$?
    case $_st in
        0) : ;;
        2) rc_fail gate1 "$_which is current" "cannot derive pathspecs from $_wfrel"
           return 0 ;;
        *) rc_fail gate1 "$_which is current" "git diff failed (status $_st)"
           return 0 ;;
    esac
    if [ -z "$_touched" ]; then
        rc_pass gate1 "$_which is current" "no trigger-path change since build"
    else
        rc_fail gate1 "$_which is current" \
            "rebuild needed; changed: $(echo "$_touched" | tr '\n' ' ')"
    fi
}

# rc_fps_min <file-of-integers> -> minimum on stdout, or -1 if the file is
# empty. -1 (not 0) so "no samples" is distinguishable from "engine stalled".
rc_fps_min() {
    awk 'NF{ if (m=="" || $1+0 < m) m=$1+0 } END{ print (m=="" ? -1 : m) }' "$1"
}

# Fields that must be byte-identical between the RC and the published release.
# `tag` and `built_utc` are deliberately excluded: they always differ, and
# comparing them would make the gate unpassable.
RC_IDENTITY_KEYS="commit rbf_run_id rbf_head_sha rbf_file engine_run_id engine_head_sha sha256_rbf sha256_solarus_run sha256_libsolarus"

# rc_manifest_identical <rc-manifest> <published-manifest> -> rows
rc_manifest_identical() {
    _a="$1"; _b="$2"
    for _k in $RC_IDENTITY_KEYS; do
        _va=$(rc_get "$_a" "$_k"); _vb=$(rc_get "$_b" "$_k")
        if [ -n "$_va" ] && [ "$_va" = "$_vb" ]; then
            rc_pass gate4 "identical" "$_k"
        else
            rc_fail gate4 "identical" "$_k: rc='$_va' published='$_vb'"
        fi
    done
}
