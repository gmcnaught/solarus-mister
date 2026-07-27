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

usage() { sed -n '2,9p' "$0"; exit 2; }

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

# Validate up front: `$((SOAK_MIN * 60))` in gate2 would otherwise blow up on
# a non-numeric value mid-gate, with the engine left running on the device.
case "$SOAK_MIN" in
    ''|*[!0-9]*)
        echo "invalid --soak-min: '$SOAK_MIN' (must be a positive integer)" >&2
        exit 2 ;;
esac
[ "$SOAK_MIN" -gt 0 ] || {
    echo "invalid --soak-min: '$SOAK_MIN' (must be a positive integer)" >&2
    exit 2
}

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
        cp "$ZIP" "$WORK/rc.zip" \
          || { rc_fail gate1 "download asset" "cannot read $ZIP" >> "$RESULTS"; return 0; }
    else
        echo "-- downloading $TAG asset"
        ( cd "$WORK" && rm -f ./*.zip \
          && gh release download "$TAG" --pattern '*.zip' --clobber ) \
          || { rc_fail gate1 "download asset" "gh release download failed" >> "$RESULTS"; return 0; }
        mv "$WORK"/solarus-mister-*.zip "$WORK/rc.zip" 2>/dev/null || true
    fi
    if [ ! -f "$WORK/rc.zip" ]; then
        rc_fail gate1 "download asset" "no rc.zip produced at $WORK/rc.zip" >> "$RESULTS"
        return 0
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

RSH() { ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$HOST" "$@"; }

gate2() {
    echo "== Gate 2: install + boot + soak on $HOST =="
    M="$WORK/tree/BUILD-INFO.txt"
    G=/media/fat/games/Solarus

    # -- the destructive wipe below must NEVER run without a verified local
    #    payload to put back afterward. Two reachable paths would otherwise
    #    leave the device with no install at all: `gate2` run standalone with
    #    no prior `gate1` ($WORK empty), or the `all` path when gate1's own
    #    download step soft-failed (it returns 0 on failure so its rows show
    #    up in the report). Check this BEFORE touching the device at all.
    if [ ! -f "$WORK/rc.zip" ] || [ ! -f "$M" ]; then
        rc_fail gate2 "rc payload present" "missing $WORK/rc.zip or $M — run gate1 first" >> "$RESULTS"
        return 0
    fi
    rc_pass gate2 "rc payload present" >> "$RESULTS"

    RSH true >/dev/null 2>&1 \
      || { rc_fail gate2 "device reachable" "$HOST" >> "$RESULTS"; return 0; }
    rc_pass gate2 "device reachable" "$HOST" >> "$RESULTS"

    # -- preflight: nothing of ours running. busybox has no pkill; pidof has
    #    no -x, so scripts are matched with a [x]-style ps|grep. Frontier's
    #    Master_Daemon (and the _handler.sh it spawns on core load) must die
    #    here too: load_core below is exactly the event that makes Master_Daemon
    #    route CORENAME=Solarus -> _handler.sh -> quest_manager.sh, which would
    #    race us into a second engine (the documented host-wedge condition).
    echo "-- stopping engine + daemon"
    # shellcheck disable=SC2016  # single-quoted so $ expands on the DEVICE, not the host
    RSH 'for p in $(ps -o pid,args 2>/dev/null | grep -E "[q]uest_manager.sh|[s]olarus_daemon.sh|[M]aster_Daemon.sh|[_]handler.sh" | awk "{print \$1}"); do kill -9 $p 2>/dev/null; done
         pids=$(pidof solarus-run); [ -n "$pids" ] && kill -9 $pids 2>/dev/null
         sleep 1; exit 0'
    left=$(RSH 'pidof solarus-run | wc -w' | tr -d ' ')
    if [ "${left:-1}" = "0" ]; then rc_pass gate2 "no engine running" >> "$RESULTS"
    else rc_fail gate2 "no engine running" "$left still alive" >> "$RESULTS"; return 0; fi

    # -- refuse to run if a prior aborted run left an unrecovered backup: that
    #    _rcsave IS the operator's only surviving copy of their quest files,
    #    and starting fresh would `rm -rf` it before ever restoring it.
    echo "-- checking for a leftover backup from a prior aborted run"
    # shellcheck disable=SC2016  # single-quoted so $ expands on the DEVICE, not the host
    leftover=$(RSH '[ -d /media/fat/_rcsave ] && [ -n "$(ls -A /media/fat/_rcsave 2>/dev/null)" ] && echo yes || echo no')
    # Fail closed on the ANSWER, not the absence of one bad answer: an ssh
    # blip or a dead host leaves $leftover empty, which must not be waved
    # through just because it isn't the literal string "yes". Only an
    # explicit "no" passes.
    if [ "$leftover" = "no" ]; then
        rc_pass gate2 "no leftover backup" >> "$RESULTS"
    else
        rc_fail gate2 "no leftover backup" "/media/fat/_rcsave is non-empty or unknown (got '${leftover:-<empty>}') — a prior run may have aborted mid-flight; recover it manually (it may be the only copy) before re-running" >> "$RESULTS"
        return 0
    fi

    # -- upload the RC zip and verify it landed BEFORE any destructive step.
    #    The old order (wipe, then scp, then extract) meant a scp failure —
    #    or standing this gate up before gate1 ever ran — left NO install on
    #    the device at all.
    echo "-- uploading the RC zip"
    scp -q "$WORK/rc.zip" "root@$HOST:/media/fat/rc.zip" \
      || { rc_fail gate2 "upload zip" "scp failed" >> "$RESULTS"; return 0; }
    localsz=$(wc -c < "$WORK/rc.zip" | tr -d ' ')
    remotesz=$(RSH 'wc -c < /media/fat/rc.zip 2>/dev/null' | tr -d ' ')
    if [ -n "$remotesz" ] && [ "$remotesz" = "$localsz" ]; then
        rc_pass gate2 "upload zip" "$remotesz bytes" >> "$RESULTS"
    else
        rc_fail gate2 "upload zip" "size mismatch: local $localsz remote ${remotesz:-<none>}" >> "$RESULTS"
        return 0
    fi

    # -- preserve quests + controls.cfg, VERIFIED, before anything is wiped.
    #    The wipe below is gated on this succeeding — if we can't prove the
    #    files landed in the backup, we do not touch the install.
    echo "-- preserving quests + controls.cfg"
    if RSH "mkdir -p /media/fat/_rcsave
         if [ -d $G/quests ]; then
             n_src=\$(ls $G/quests/*.sol 2>/dev/null | wc -l | tr -d ' ')
             if [ \"\$n_src\" -gt 0 ]; then
                 cp $G/quests/*.sol /media/fat/_rcsave/ 2>/dev/null
                 n_dst=\$(ls /media/fat/_rcsave/*.sol 2>/dev/null | wc -l | tr -d ' ')
                 [ \"\$n_dst\" = \"\$n_src\" ] || exit 1
             fi
         fi
         if [ -f $G/controls.cfg ]; then
             cp $G/controls.cfg /media/fat/_rcsave/ 2>/dev/null
             [ -f /media/fat/_rcsave/controls.cfg ] || exit 1
         fi
         exit 0"; then
        rc_pass gate2 "quests preserved" >> "$RESULTS"
    else
        rc_fail gate2 "quests preserved" "preserve verify failed on device; refusing to wipe" >> "$RESULTS"
        return 0
    fi

    # -- WIPE. Only reachable once the zip is on the device AND the backup is
    #    verified, so this can never destroy the only copy of anything.
    echo "-- wiping install"
    RSH "rm -rf $G
         rm -f /media/fat/_Other/Solarus_*.rbf
         rm -f /media/fat/Scripts/Solarus.sh
         rm -f /media/fat/config/Solarus.s0 /media/fat/config/Solarus_input.map
         exit 0"
    rbfleft=$(RSH 'ls /media/fat/_Other/Solarus_*.rbf 2>/dev/null | wc -l' | tr -d ' ')
    if [ "${rbfleft:-1}" = "0" ]; then rc_pass gate2 "old cores wiped" >> "$RESULTS"
    else rc_fail gate2 "old cores wiped" "$rbfleft remain" >> "$RESULTS"; fi

    # -- extract the (already-uploaded, already-verified) zip.
    echo "-- extracting the RC zip"
    RSH 'unzip -q -o /media/fat/rc.zip -d /media/fat && rm -f /media/fat/rc.zip' \
      || { rc_fail gate2 "extract zip" "unzip failed" >> "$RESULTS"; return 0; }
    rc_pass gate2 "extract zip" >> "$RESULTS"

    # -- restore quests + controls.cfg, VERIFIED, BEFORE removing the backup.
    echo "-- restoring quests + controls.cfg from backup"
    RSH "mkdir -p $G/quests
         cp /media/fat/_rcsave/*.sol $G/quests/ 2>/dev/null
         cp /media/fat/_rcsave/controls.cfg $G/ 2>/dev/null
         chmod +x $G/*.sh $G/solarus-run /media/fat/Scripts/Solarus.sh 2>/dev/null
         exit 0"
    # Verify BOTH restored artifacts, not just the .sol count: a controls.cfg
    # copy failure with a clean .sol restore must not read as OK, or the
    # `rm -rf /media/fat/_rcsave` below deletes the only surviving copy of
    # the operator's control remap.
    restore_check=$(RSH "n_bak=\$(ls /media/fat/_rcsave/*.sol 2>/dev/null | wc -l | tr -d ' ')
         n_g=\$(ls $G/quests/*.sol 2>/dev/null | wc -l | tr -d ' ')
         if [ \"\$n_bak\" -gt 0 ] && [ \"\$n_g\" != \"\$n_bak\" ]; then echo FAIL; exit 0; fi
         if [ -f /media/fat/_rcsave/controls.cfg ] && [ ! -f $G/controls.cfg ]; then echo FAIL; exit 0; fi
         echo OK")
    if [ "$restore_check" = "OK" ]; then
        rc_pass gate2 "quests restored" >> "$RESULTS"
        RSH 'rm -rf /media/fat/_rcsave'
    else
        rc_fail gate2 "quests restored" "backup/restore count mismatch — NOT deleting /media/fat/_rcsave; recover manually" >> "$RESULTS"
    fi

    # -- installed bytes match the manifest.
    RBF=$(rc_get "$M" rbf_file)
    for pair in "sha256_rbf:/media/fat/_Other/$RBF" \
                "sha256_solarus_run:$G/solarus-run" \
                "sha256_libsolarus:$G/libs/libsolarus.so.1.6.5"; do
        key=${pair%%:*}; path=${pair#*:}
        want=$(rc_get "$M" "$key")
        got=$(RSH "sha256sum '$path' 2>/dev/null | cut -d' ' -f1")
        if [ -n "$got" ] && [ "$got" = "$want" ]; then
            rc_pass gate2 "installed sha256" "$(basename "$path")" >> "$RESULTS"
        else
            rc_fail gate2 "installed sha256" "$(basename "$path"): got '$got' want '$want'" >> "$RESULTS"
        fi
    done
    n=$(RSH 'ls /media/fat/_Other/Solarus_*.rbf 2>/dev/null | wc -l' | tr -d ' ')
    if [ "$n" = "1" ]; then rc_pass gate2 "single rbf on card" >> "$RESULTS"
    else rc_fail gate2 "single rbf on card" "$n present" >> "$RESULTS"; fi

    # -- link probe + the software-only invariant.
    if RSH "cd $G && LD_LIBRARY_PATH=$G/libs:$G ./solarus-run -help >/dev/null 2>&1"; then
        rc_pass gate2 "lib closure links" >> "$RESULTS"
    else
        rc_fail gate2 "lib closure links" "solarus-run -help failed (missing/ABI-bad .so)" >> "$RESULTS"
    fi
    # Capture the FULL ldd output (stderr included): an unreachable host, a
    # missing ldd, or any ldd error must never read as "no GL" just because
    # grep found nothing on an empty/garbled string. Assert non-empty AND a
    # known-good sentinel (libSDL2, which the engine definitely links) before
    # trusting the GL grep at all.
    glfull=$(RSH "cd $G && LD_LIBRARY_PATH=$G/libs:$G ldd ./solarus-run 2>&1")
    if [ -z "$glfull" ] || ! echo "$glfull" | grep -q 'libSDL2'; then
        rc_fail gate2 "no GL linkage" "ldd output unusable/empty (sentinel libSDL2 not found): $(echo "$glfull" | tr '\n' ' ')" >> "$RESULTS"
    elif echo "$glfull" | grep -Eqi 'libGL|GLEW|EGL'; then
        rc_fail gate2 "no GL linkage" "$(echo "$glfull" | grep -Ei 'libGL|GLEW|EGL' | tr '\n' ' ')" >> "$RESULTS"
    else
        rc_pass gate2 "no GL linkage" >> "$RESULTS"
    fi

    # -- launch: core first, then the engine with an S0_FILE override. The
    #    daemon stays DOWN so it cannot race us into a second engine.
    QUEST=$(RSH "ls $G/quests/*.sol 2>/dev/null | head -1")
    if [ -z "$QUEST" ]; then
        rc_fail gate2 "quest available" "no .sol in $G/quests" >> "$RESULTS"; return 0
    fi
    rc_pass gate2 "quest available" "$(basename "$QUEST")" >> "$RESULTS"
    LOG="/media/fat/logs/rc-$TAG.log"
    echo "-- loading core"
    RSH "echo 'load_core /media/fat/_Other/$RBF' > /dev/MiSTer_cmd; sleep 4; exit 0"
    # Re-check right after load_core, BEFORE our own scripted launch: this is
    # exactly the window where Master_Daemon (if it wasn't fully killed, or
    # respawns) could route the core load into _handler.sh -> quest_manager.sh
    # and beat us to a second engine.
    race=$(RSH 'pidof solarus-run | wc -w' | tr -d ' ')
    # Fail closed: an ssh blip or a device wedged by load_core must read as
    # "cannot prove no race", never as "0 engines". ${race:-1} matches the
    # sibling check at "no engine running" above.
    if [ "${race:-1}" = "0" ]; then
        rc_pass gate2 "no race after load_core" >> "$RESULTS"
    else
        rc_fail gate2 "no race after load_core" "$race engine(s) already running before our scripted launch" >> "$RESULTS"
        return 0
    fi
    echo "-- launching engine (log: $LOG)"
    RSH "printf '%s\n' '${QUEST#/media/fat/}' > /tmp/rc_s0
         mkdir -p /media/fat/logs
         cd '$G' && S0_FILE=/tmp/rc_s0 GAMEDIR='$G' setsid sh '$G'/solarus_run.sh \
            > '$LOG' 2>&1 </dev/null &
         sleep 5; exit 0"
    alive=$(RSH 'pidof solarus-run | wc -w' | tr -d ' ')
    if [ "${alive:-0}" -ge 1 ]; then rc_pass gate2 "engine launched" >> "$RESULTS"
    else rc_fail gate2 "engine launched" "no solarus-run after launch" >> "$RESULTS"; return 0; fi
    # Capture the launched engine's PID now: the soak-end check re-reads it
    # and asserts the SAME pid is still there, catching both a plain crash
    # and a crash-then-relaunch (which "something named solarus-run is
    # running" alone would miss). No buffering dependency, unlike the
    # log-tail check this replaces (see "same engine after soak" below).
    enginepid=$(RSH 'pidof solarus-run' | awk '{print $1}')
    if [ "${alive:-0}" -gt 1 ]; then
        rc_fail gate2 "single engine" "$alive engines — host wedge risk" >> "$RESULTS"
        return 0
    else
        rc_pass gate2 "single engine" >> "$RESULTS"
    fi

    # -- log assertions, run BEFORE the wait-for-ready poll: a build that
    #    fell back to SDL times out at the fps poll below and used to
    #    `return 0` before these rows ever ran, deleting exactly the
    #    'reverting to SDL' / 'pass-through SDLRenderer' evidence that would
    #    tell the operator why. Assert the log exists and is non-empty
    #    FIRST: grep on a missing file (status 2) and ssh on a dead host
    #    (status 255) both take the "not found" branch, which must never
    #    read as a clean PASS.
    logsz=$(RSH "wc -c < '$LOG' 2>/dev/null" | tr -d ' ')
    if [ -z "$logsz" ] || [ "$logsz" = "0" ]; then
        rc_fail gate2 "log present" "$LOG missing or empty" >> "$RESULTS"
        return 0
    fi
    rc_pass gate2 "log present" "$logsz bytes" >> "$RESULTS"
    for want in 'renderer active (DDR @' 'ring double-buffer ENABLED' \
                'tilemap channel ENABLED'; do
        if RSH "grep -qF '$want' '$LOG'"; then
            rc_pass gate2 "log has" "$want" >> "$RESULTS"
        else
            rc_fail gate2 "log has" "missing: $want" >> "$RESULTS"
        fi
    done
    # scene_too_big and 'Segmentation fault' were dropped: scene_too_big has
    # no emission site left in the engine (deleted 4f91c1b), and a shell
    # fault message can never reach this log because solarus_run.sh `exec`s
    # the engine — no shell survives to write it. Both rows passed under
    # every possible outcome. The real crash signals are the process-identity
    # checks: "engine launched"/"single engine" above and "same engine after
    # soak" below.
    for bad in 'video-region map failed' 'reverting to SDL' \
               'pass-through SDLRenderer'; do
        # Capture the remote grep's own exit status explicitly: `grep -qF`
        # returns 0 (found), 1 (not found), or 2/255-class (file/ssh error).
        # The naive `if RSH ...; then FAIL; else PASS; fi` treated status 1
        # AND any error status alike as "else" == PASS, so an ssh blip or a
        # vanished log would read as a clean bill of health. `\$?` must
        # reach the DEVICE literally, not expand on the host.
        # shellcheck disable=SC2016
        gcout=$(RSH "grep -qF '$bad' '$LOG'; echo rc=\$?")
        grc=$(echo "$gcout" | sed -n 's/^rc=//p')
        case "$grc" in
            0) rc_fail gate2 "log clean" "found: $bad" >> "$RESULTS" ;;
            1) rc_pass gate2 "log clean" "no '$bad'" >> "$RESULTS" ;;
            *) rc_fail gate2 "log clean" "grep status unusable ('${grc:-<none>}') for '$bad'" >> "$RESULTS" ;;
        esac
    done

    # -- wait for ready: poll the frame counter until fps first exceeds the
    #    floor, instead of a fixed sleep. Whole-quest atlas preload can
    #    legitimately take a while, and a fixed settle can make a healthy
    #    build fail here for no reason; a timeout still FAILs if it never
    #    comes up so a truly wedged engine is still caught.
    echo "-- waiting for fps to reach the floor (preload can take a while)"
    # shellcheck disable=SC2016  # single-quoted so $ expands on the DEVICE, not the host
    ready=$(RSH 'i=0; prev=""; streak=0
         while [ $i -lt 90 ]; do
           c=$(busybox devmem 0x3A000000 2>/dev/null); f=$(( c >> 2 ))
           if [ -n "$prev" ]; then
             d=$(( f - prev ))
             if [ $d -ge 45 ]; then streak=$((streak+1)); else streak=0; fi
             # Require TWO consecutive samples at/above the floor: one noisy
             # sample must not promote the poll to the strict-minimum stage.
             [ $streak -ge 2 ] && { echo READY; exit 0; }
           fi
           prev=$f; i=$((i+1)); sleep 1
         done
         echo TIMEOUT')
    if [ "$ready" = "READY" ]; then
        rc_pass gate2 "fps reaches floor" "floor 45 reached (2 consecutive samples) before soak-sampling" >> "$RESULTS"
    else
        rc_fail gate2 "fps reaches floor" "fps never reached 45 for 2 consecutive samples within 90s" >> "$RESULTS"
        return 0
    fi

    # -- fps floor, sustained: 30 one-second samples, strict minimum. This
    #    keeps its ability to catch a mid-run stall now that the preload
    #    settle is handled by the wait-for-ready poll above.
    echo "-- sampling fps for 30s"
    # shellcheck disable=SC2016  # single-quoted so $ expands on the DEVICE, not the host
    RSH 'prev=""; i=0
         while [ $i -lt 31 ]; do
           c=$(busybox devmem 0x3A000000 2>/dev/null); f=$(( c >> 2 ))
           [ -n "$prev" ] && echo $(( f - prev ))
           prev=$f; i=$((i+1)); sleep 1
         done' > "$WORK/fps.txt"
    fmin=$(rc_fps_min "$WORK/fps.txt")
    if [ "$fmin" -ge 45 ]; then
        rc_pass gate2 "fps floor" "min ${fmin} fps (floor 45)" >> "$RESULTS"
    else
        rc_fail gate2 "fps floor" "min ${fmin} fps below floor 45" >> "$RESULTS"
    fi

    # -- soak.
    echo "-- soaking ${SOAK_MIN} min"
    RSH "sleep $((SOAK_MIN * 60))"
    still=$(RSH 'pidof solarus-run | wc -w' | tr -d ' ')
    if [ "${still:-0}" -ge 1 ]; then rc_pass gate2 "alive after soak" "${SOAK_MIN} min" >> "$RESULTS"
    else rc_fail gate2 "alive after soak" "engine died during soak" >> "$RESULTS"; fi

    # -- same engine after soak: the crash signal that does not depend on
    #    stdout buffering (stdout redirected to a file is block-buffered, so
    #    a healthy engine's last flushed byte lands mid-line routinely — a
    #    tail-based truncation check flaps on every good run and treats
    #    "command produced nothing" the same as "clean trailing newline",
    #    both PASS). Compare the pid captured right after launch to the pid
    #    now: identical means no crash and no crash-then-relaunch (the
    #    latter still shows up as "alive after soak" above, since something
    #    named solarus-run is running either way). Fail closed: an empty
    #    read on EITHER side is a FAIL, never a PASS.
    endpid=$(RSH 'pidof solarus-run' | awk '{print $1}')
    if [ -n "$enginepid" ] && [ -n "$endpid" ] && [ "$endpid" = "$enginepid" ]; then
        rc_pass gate2 "same engine after soak" "pid $enginepid" >> "$RESULTS"
    else
        rc_fail gate2 "same engine after soak" "launch pid '${enginepid:-<empty>}' vs post-soak pid '${endpid:-<empty>}'" >> "$RESULTS"
    fi

    a=$(RSH 'busybox devmem 0x3A000000'); sleep 2
    b=$(RSH 'busybox devmem 0x3A000000')
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]; then
        rc_pass gate2 "frames advancing" >> "$RESULTS"
    else
        rc_fail gate2 "frames advancing" "frame counter frozen or unreadable (a='${a:-<empty>}' b='${b:-<empty>}')" >> "$RESULTS"
    fi

    echo
    echo "Gate 2 done. Engine is RUNNING for Gate 3 (operator visual gate)."
    echo "For the real user path, run on the device:  sh /media/fat/Scripts/Solarus.sh"
    echo "Device log: $LOG"
    echo "NOTE: Frontier's Master_Daemon was stopped by this gate's preflight and was"
    echo "  NOT restarted (OSD game-load depends on it). Re-running"
    echo "  Scripts/Solarus.sh on the device starts the Solarus daemon; Master_Daemon"
    echo "  itself only comes back on reboot."
}

# Print the exact pinned publish command. NEVER publish by pushing the tag
# blind: release.yml would re-resolve "latest successful on master" and could
# ship binaries other than the ones that just passed Gates 1-3.
rc_publish_cmd() {
    [ -f "$WORK/pins.env" ] || { echo "(run gate1 first — no pins recorded)"; return; }
    # shellcheck disable=SC1091  # generated file, path is computed at runtime
    . "$WORK/pins.env"
    _rel=$(echo "$TAG" | sed 's/-rc[0-9]*$//')
    # shellcheck disable=SC2154  # rbf_run_id/engine_run_id come from the sourced pins.env above
    cat <<EOF

Publish the tested artifacts as $_rel:

  gh workflow run release.yml \\
    -f tag=$_rel \\
    -f rbf_run_id=$rbf_run_id \\
    -f engine_run_id=$engine_run_id

Then verify:  scripts/release_test.sh gate4 $_rel --rc $TAG
EOF
}

gate4() {
    echo "== Gate 4: post-publish identity =="
    RCW="$ROOT/_rc/$RC_TAG"
    if [ ! -f "$RCW/tree/BUILD-INFO.txt" ]; then
        : > "$RESULTS"
        rc_fail gate4 "rc manifest available" "no $RCW/tree/BUILD-INFO.txt — run gate1 $RC_TAG first" >> "$RESULTS"
        return 0
    fi
    : > "$RESULTS"
    rm -rf "$WORK/pub"; mkdir -p "$WORK/pub"
    ( cd "$WORK/pub" && gh release download "$TAG" --pattern '*.zip' --clobber ) \
      || { rc_fail gate4 "download published" "gh release download failed" >> "$RESULTS"; return 0; }
    rc_pass gate4 "download published" "$TAG" >> "$RESULTS"
    unzip -q -o "$WORK"/pub/*.zip -d "$WORK/pub/tree" \
      || { rc_fail gate4 "unzip published" "extract failed" >> "$RESULTS"; return 0; }

    rc_manifest_identical "$RCW/tree/BUILD-INFO.txt" "$WORK/pub/tree/BUILD-INFO.txt" >> "$RESULTS"
    rc_structure_check "$WORK/pub/tree" "$WORK/pub/tree/BUILD-INFO.txt" >> "$RESULTS"

    if [ "$(gh release view "$TAG" --json isPrerelease -q .isPrerelease)" = "false" ]; then
        rc_pass gate4 "not a prerelease" >> "$RESULTS"
    else
        rc_fail gate4 "not a prerelease" "$TAG is marked prerelease" >> "$RESULTS"
    fi
    if [ "$(gh release view --json tagName -q .tagName)" = "$TAG" ]; then
        rc_pass gate4 "marked Latest" >> "$RESULTS"
    else
        rc_fail gate4 "marked Latest" "Latest is $(gh release view --json tagName -q .tagName)" >> "$RESULTS"
    fi
}

case "$CMD" in
    gate1) : > "$RESULTS"; gate1 ;;
    gate2) gate2 ;;
    gate4) gate4 ;;
    all)   : > "$RESULTS"; gate1 && gate2; rc_report; rc=$?; rc_publish_cmd; exit "$rc" ;;
    publish-cmd) rc_publish_cmd; exit 0 ;;
    *)     usage ;;
esac
rc_report
