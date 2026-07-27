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

    RSH true >/dev/null 2>&1 \
      || { rc_fail gate2 "device reachable" "$HOST" >> "$RESULTS"; return 0; }
    rc_pass gate2 "device reachable" "$HOST" >> "$RESULTS"

    # -- preflight: nothing of ours running. busybox has no pkill; pidof has
    #    no -x, so scripts are matched with a [x]-style ps|grep.
    echo "-- stopping engine + daemon"
    # shellcheck disable=SC2016  # single-quoted so $ expands on the DEVICE, not the host
    RSH 'for p in $(ps -o pid,args 2>/dev/null | grep -E "[q]uest_manager.sh|[s]olarus_daemon.sh" | awk "{print \$1}"); do kill -9 $p 2>/dev/null; done
         pids=$(pidof solarus-run); [ -n "$pids" ] && kill -9 $pids 2>/dev/null
         sleep 1; exit 0'
    left=$(RSH 'pidof solarus-run | wc -w' | tr -d ' ')
    if [ "${left:-1}" = "0" ]; then rc_pass gate2 "no engine running" >> "$RESULTS"
    else rc_fail gate2 "no engine running" "$left still alive" >> "$RESULTS"; return 0; fi

    # -- preserve quests + controls.cfg, then WIPE.
    echo "-- preserving quests + controls.cfg, wiping install"
    RSH "rm -rf /media/fat/_rcsave && mkdir -p /media/fat/_rcsave
         cp $G/quests/*.sol /media/fat/_rcsave/ 2>/dev/null
         cp $G/controls.cfg /media/fat/_rcsave/ 2>/dev/null
         rm -rf $G
         rm -f /media/fat/_Other/Solarus_*.rbf
         rm -f /media/fat/Scripts/Solarus.sh
         rm -f /media/fat/config/Solarus.s0 /media/fat/config/Solarus_input.map
         exit 0"
    rbfleft=$(RSH 'ls /media/fat/_Other/Solarus_*.rbf 2>/dev/null | wc -l' | tr -d ' ')
    if [ "${rbfleft:-1}" = "0" ]; then rc_pass gate2 "old cores wiped" >> "$RESULTS"
    else rc_fail gate2 "old cores wiped" "$rbfleft remain" >> "$RESULTS"; fi

    # -- install from the zip, exactly as a user would.
    echo "-- uploading + extracting the RC zip"
    scp -q "$WORK/rc.zip" "root@$HOST:/media/fat/rc.zip" \
      || { rc_fail gate2 "upload zip" "scp failed" >> "$RESULTS"; return 0; }
    RSH 'unzip -q -o /media/fat/rc.zip -d /media/fat && rm -f /media/fat/rc.zip' \
      || { rc_fail gate2 "extract zip" "unzip failed" >> "$RESULTS"; return 0; }
    rc_pass gate2 "extract zip" >> "$RESULTS"
    RSH "mkdir -p $G/quests
         cp /media/fat/_rcsave/*.sol $G/quests/ 2>/dev/null
         cp /media/fat/_rcsave/controls.cfg $G/ 2>/dev/null
         chmod +x $G/*.sh $G/solarus-run /media/fat/Scripts/Solarus.sh 2>/dev/null
         rm -rf /media/fat/_rcsave; exit 0"

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
    gl=$(RSH "cd $G && LD_LIBRARY_PATH=$G/libs:$G ldd ./solarus-run 2>/dev/null | grep -Ei 'libGL|GLEW|EGL'")
    if [ -z "$gl" ]; then rc_pass gate2 "no GL linkage" >> "$RESULTS"
    else rc_fail gate2 "no GL linkage" "$(echo "$gl" | tr '\n' ' ')" >> "$RESULTS"; fi

    # -- launch: core first, then the engine with an S0_FILE override. The
    #    daemon stays DOWN so it cannot race us into a second engine.
    QUEST=$(RSH "ls $G/quests/*.sol 2>/dev/null | head -1")
    if [ -z "$QUEST" ]; then
        rc_fail gate2 "quest available" "no .sol in $G/quests" >> "$RESULTS"; return 0
    fi
    rc_pass gate2 "quest available" "$(basename "$QUEST")" >> "$RESULTS"
    LOG="/media/fat/logs/rc-$TAG.log"
    echo "-- loading core + launching engine (log: $LOG)"
    RSH "echo 'load_core /media/fat/_Other/$RBF' > /dev/MiSTer_cmd; sleep 4
         printf '%s\n' '${QUEST#/media/fat/}' > /tmp/rc_s0
         mkdir -p /media/fat/logs
         cd $G && S0_FILE=/tmp/rc_s0 GAMEDIR=$G setsid sh $G/solarus_run.sh \
            > $LOG 2>&1 </dev/null &
         sleep 25; exit 0"
    alive=$(RSH 'pidof solarus-run | wc -w' | tr -d ' ')
    if [ "${alive:-0}" -ge 1 ]; then rc_pass gate2 "engine launched" >> "$RESULTS"
    else rc_fail gate2 "engine launched" "no solarus-run after 25s" >> "$RESULTS"; return 0; fi
    if [ "${alive:-0}" -gt 1 ]; then
        rc_fail gate2 "single engine" "$alive engines — host wedge risk" >> "$RESULTS"
    else
        rc_pass gate2 "single engine" >> "$RESULTS"
    fi

    # -- log assertions.
    for want in 'renderer active (DDR @' 'ring double-buffer ENABLED' \
                'tilemap channel ENABLED'; do
        if RSH "grep -qF '$want' $LOG"; then
            rc_pass gate2 "log has" "$want" >> "$RESULTS"
        else
            rc_fail gate2 "log has" "missing: $want" >> "$RESULTS"
        fi
    done
    for bad in 'video-region map failed' 'reverting to SDL' \
               'pass-through SDLRenderer' 'scene_too_big' 'Segmentation fault'; do
        if RSH "grep -qF '$bad' $LOG"; then
            rc_fail gate2 "log clean" "found: $bad" >> "$RESULTS"
        else
            rc_pass gate2 "log clean" "no '$bad'" >> "$RESULTS"
        fi
    done

    # -- fps floor on the title screen (~57 measured; floor 45 catches a
    #    fallback to the SDL path without flapping on scheduling noise).
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
    a=$(RSH 'busybox devmem 0x3A000000'); sleep 2
    b=$(RSH 'busybox devmem 0x3A000000')
    if [ "$a" != "$b" ]; then rc_pass gate2 "frames advancing" >> "$RESULTS"
    else rc_fail gate2 "frames advancing" "frame counter frozen at $a" >> "$RESULTS"; fi

    echo
    echo "Gate 2 done. Engine is RUNNING for Gate 3 (operator visual gate)."
    echo "For the real user path, run on the device:  sh /media/fat/Scripts/Solarus.sh"
    echo "Device log: $LOG"
}

case "$CMD" in
    gate1) : > "$RESULTS"; gate1 ;;
    gate2) gate2 ;;
    all)   : > "$RESULTS"; gate1 && gate2 ;;
    *)     usage ;;
esac
rc_report
