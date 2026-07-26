#!/usr/bin/env python3
"""
Deploy the Solarus MiSTer port to a running MiSTer over SSH.

Modeled on MiSTer_OpenBOR_7533/deploy.py, but uses plain ssh/scp (the device is
SSH-key-authed — `ssh root@<HOST>` needs no password) instead of paramiko, so it
runs without extra Python deps.

What it does:
  1. Stops any running solarus-run engine (so libs/binary can be replaced).
  2. Uploads the ARM binary, runtime libs, handler + launch scripts, and the
     branded RBF. Every artifact is uploaded to a temp name (`<dst>.new`, or a
     `libs/.stage` dir for the lib closure), sha1-verified there, then swapped
     into place with `mv` — so a failed/truncated transfer leaves the previous
     working file untouched instead of a missing/partial one.
  3. Installs the Scripts-menu launcher to /media/fat/Scripts/Solarus.sh.
  4. Fixes line endings + exec bits on the shell scripts.
  5. Post-deploy sanity checks (all automatic, fatal on failure): every
     artifact's sha1 verified device-side; the lib closure link-probed by
     running `solarus-run -help` under the deploy env (catches a missing/ABI-
     incompatible .so); an ldd assertion that no libGL/GLEW/EGL DT_NEEDED crept
     in (software-only); and a double-launch guard on the restarted daemon.

Source-of-truth in the repo:
  deploy/solarus-run                 ARM engine binary (gitignored build artifact)
  deploy/libs/                       runtime .so closure (gitignored)
  games/Solarus/_handler.sh          auto-launch dispatcher (committed)
  games/Solarus/solarus_run.sh       shared launch logic (committed)
  games/Solarus/quest_manager.sh     OSD quest lifecycle manager (committed)
  games/Solarus/quest_lib.sh         shared resolve_quest helper (committed)
  games/Solarus/core_watch.sh        core-change exit watcher (committed)
  scripts/Solarus.sh                 Scripts-menu launcher (committed)
  _Other/Solarus_*.rbf               branded FPGA core (gitignored; gh-downloaded)

Usage:
  ./deploy.py                 deploy everything
  ./deploy.py --no-rbf        skip the RBF (engine/libs/scripts only)
  ./deploy.py --host 1.2.3.4  override device IP
"""

import argparse
import glob
import subprocess
import sys
from pathlib import Path

HOST = "192.168.20.81"
USER = "root"
REPO = Path(__file__).resolve().parent
GAMEDIR = "/media/fat/games/Solarus"


def sh(args, **kw):
    print("  $", " ".join(args))
    return subprocess.run(args, **kw)


def ssh(host, cmd, check=False):
    return sh(["ssh", f"{USER}@{host}", cmd],
              check=check, text=True, capture_output=True)


def scp(host, src, dst):
    return sh(["scp", "-q", str(src), f"{USER}@{host}:{dst}"], check=True)


def scp_verified(host, src, dst, retries=3):
    """scp to a temp path, sha1-verify it, then atomically mv it into place.

    FAT on the device can leave a TRUNCATED file on a partial scp (a truncated
    executable then segfaults before main with no output), so we ALWAYS verify.
    Uploading to `{dst}.new` and swapping only AFTER the temp verifies means a
    failed/interrupted transfer leaves the existing `{dst}` untouched — the old
    `rm {dst}; scp {dst}` left nothing on a mid-scp failure. The engine + daemon
    are killed before any upload, so `{dst}` is never an open exe at swap time;
    `mv -f` (busybox: unlink dest + rename) reliably replaces it, and the swap
    window is a rename, not a whole transfer. `mv` moves directory entries only,
    so it can't re-truncate the already-verified bytes.
    """
    import hashlib
    want = hashlib.sha1(Path(src).read_bytes()).hexdigest()
    tmp = f"{dst}.new"
    for attempt in range(1, retries + 1):
        ssh(host, f"rm -f {tmp}")
        scp(host, src, tmp)
        got = ssh(host, f"sha1sum {tmp} 2>/dev/null").stdout.split()[:1]
        if got and got[0] == want:
            ssh(host, f"mv -f {tmp} {dst}", check=True)
            print(f"    sha1 ok ({want[:12]}) -> swapped into place")
            return
        print(f"    sha1 mismatch (attempt {attempt}/{retries}) — retrying")
    ssh(host, f"rm -f {tmp}")   # leave the existing (good) {dst} intact
    raise SystemExit(f"FATAL: {dst} failed sha1 verification after {retries} tries")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--no-rbf", action="store_true",
                    help="skip uploading the branded RBF")
    ap.add_argument("--diag", action="store_true",
                    help="upload games/Solarus/diag.env instead of removing it "
                         "(diagnostics session; NEVER use for an end-user deploy)")
    args = ap.parse_args()
    host = args.host

    binary = REPO / "deploy/solarus-run"
    libsdir = REPO / "deploy/libs"
    handler = REPO / "games/Solarus/_handler.sh"
    launcher = REPO / "scripts/Solarus.sh"

    # Helper shell scripts under games/Solarus/ pushed alongside the engine:
    #   solarus_run.sh   shared launch logic (env + quest resolve + exec)
    #   quest_manager.sh OSD quest lifecycle manager (#2: idle-until-pick + switch)
    #   quest_lib.sh     shared resolve_quest helper (sourced by the two above)
    #   core_watch.sh      core-change exit watcher (#3)
    #   solarus_daemon.sh  Frontier-independent core-load watcher (auto-launch)
    game_scripts = [REPO / "games/Solarus" / n for n in (
        "solarus_run.sh", "quest_manager.sh", "quest_lib.sh", "core_watch.sh",
        "solarus_daemon.sh")]
    # [controls] Per-quest controller mapping. Shipped as .default and copied to
    # controls.cfg only when absent, so a user's edits survive redeploys.
    controls_default = REPO / "games/Solarus" / "controls.cfg.default"

    # Verify local source files exist.
    for p in (binary, handler, launcher, controls_default, *game_scripts):
        if not p.exists():
            print(f"MISSING: {p}", file=sys.stderr)
            sys.exit(1)
    libs = sorted(p for p in libsdir.glob("*.so*")
                  if not p.name.startswith("._"))
    if not libs:
        print(f"MISSING: no .so files in {libsdir}", file=sys.stderr)
        sys.exit(1)

    rbf = None
    if not args.no_rbf:
        # RBF selection convention (MUST match scripts/Solarus.sh): the
        # lexicographically-last Solarus_*.rbf. Names are Solarus_YYYYMMDD.rbf so
        # a name sort is chronological and deterministic; Solarus.sh sorts the
        # remote _Other/ the same way, so both pick the identical core.
        rbfs = sorted(glob.glob(str(REPO / "_Other" / "Solarus_*.rbf")))
        if rbfs:
            rbf = Path(rbfs[-1])
        else:
            print("note: no local _Other/Solarus_*.rbf — skipping RBF upload "
                  "(use `gh run download <id> -n solarus-rbf` to fetch one)")

    print(f"Deploying to {USER}@{host}\n")

    print("-- Stopping running daemon + manager + engine --")
    # Kill the daemon FIRST (so it doesn't respawn the handler), then the quest
    # manager (so it doesn't relaunch the engine we're about to replace), then the
    # engine. Device busybox has no pkill and its pidof has no -x (won't match a
    # script), so match the scripts in ps ([x] keeps grep off itself); the engine
    # is a real binary so pidof finds it. We do NOT pre-remove the old binary: the
    # atomic scp_verified() below uploads to solarus-run.new and mv's it over the
    # (now-not-open) binary, so a failed deploy leaves the working binary in place.
    # The daemon is restarted fresh after upload so the new code takes effect.
    ssh(host, "for pat in '[s]olarus_daemon.sh' '[q]uest_manager.sh'; do "
              "for p in $(ps -o pid,args 2>/dev/null | grep \"$pat\" | awk '{print $1}'); do "
              "kill -9 \"$p\" 2>/dev/null; done; done; "
              "kill -9 $(pidof solarus-run) 2>/dev/null; sleep 1; "
              "rm -rf /tmp/solarus_quest; true")

    print("\n-- Creating remote dirs --")
    ssh(host, f"mkdir -p {GAMEDIR}/libs {GAMEDIR}/quests "
              "/media/fat/Scripts /media/fat/_Other /media/fat/logs/Solarus "
              "/media/fat/docs/Solarus", check=True)

    # Safety (#91), revised 2026-07-19: solarus_run.sh now sources diag.env on
    # PRESENCE alone (the old SOLARUS_ALLOW_DIAG_ENV second key is gone, because a
    # session that created the file but forgot the var silently measured the
    # DEFAULT path). End-user protection therefore rests HERE: absence. A normal
    # deploy removes the file, so a shipped device has nothing to source.
    # --diag uploads it instead — diagnostics sessions only, never end-user.
    diag_env = REPO / "games" / "Solarus" / "diag.env"
    if args.diag:
        if not diag_env.is_file():
            sys.exit(f"--diag given but {diag_env} does not exist")
        print("\n-- Uploading diag.env (DIAGNOSTICS BUILD — not for end users) --")
        scp_verified(host, diag_env, f"{GAMEDIR}/diag.env")
        # Echo back what the device will actually source, so a mis-set flag is
        # caught here rather than after a wasted validation session.
        print("-- Active (uncommented) flags on device --")
        # ssh() captures stdout, so the result MUST be printed — without this the
        # echo-back above is a silent no-op and a mis-set flag sails through.
        print(ssh(host, f"grep -vE '^[[:space:]]*(#|$)' {GAMEDIR}/diag.env || true",
                  check=False).stdout, end="")
    else:
        print("\n-- Removing stale diag.env (diagnostics are opt-in; use --diag) --")
        ssh(host, f"rm -f {GAMEDIR}/diag.env", check=False)

    # [controls] Always refresh the reference copy; only seed controls.cfg when the
    # device has none, so hand-edits on the SD card survive a redeploy.
    print("\n-- Uploading controls.cfg.default (per-quest controller mapping) --")
    scp_verified(host, controls_default, f"{GAMEDIR}/controls.cfg.default")
    ssh(host, f"[ -f {GAMEDIR}/controls.cfg ] || cp {GAMEDIR}/controls.cfg.default "
              f"{GAMEDIR}/controls.cfg", check=False)
    # Echo back the section header line that is actually on the device, so a
    # mis-seeded or hand-broken config is caught here rather than during play.
    print("-- controls.cfg on device (first line) --")
    print(ssh(host, f"head -1 {GAMEDIR}/controls.cfg", check=False).stdout, end="")

    print("\n-- Uploading ARM binary (sha1-verified) --")
    scp_verified(host, binary, f"{GAMEDIR}/solarus-run")

    print(f"\n-- Uploading {len(libs)} runtime libs (staged + sha1-verified) --")
    # Stage-then-swap: extract into libs/.stage, sha1-verify EVERY lib THERE, and
    # only then swap the verified set into libs/. A FAT extract over an existing
    # .so can leave a truncated/partial file, and the tar-pipe is itself unverified
    # (observed: a stale libsolarus.so silently survived, sha mismatched while the
    # binary matched) — so verifying in the staging dir first means a bad/truncated
    # upload never touches the working closure. Only after all libs verify do we
    # clear the old .so* and mv the staged ones in.
    stage = f"{GAMEDIR}/libs/.stage"
    ssh(host, f"rm -rf {stage} && mkdir -p {stage}", check=True)
    # Tar-pipe the libs in one shot. macOS bsdtar: drop AppleDouble/xattr cruft.
    # Device busybox tar: -o = don't restore owner (FAT can't chown).
    tar = subprocess.Popen(
        ["tar", "--no-xattrs", "--no-mac-metadata", "-C", str(libsdir),
         "-cf", "-"] + [p.name for p in libs],
        stdout=subprocess.PIPE)
    sh(["ssh", f"{USER}@{host}", f"tar -C {stage} -xof -"],
       stdin=tar.stdout, check=True)
    tar.wait()
    # Verify each staged lib before the swap — one stale .so segfaults the engine
    # with no useful output, so fail the deploy loudly here (working libs intact).
    import hashlib
    want = {p.name: hashlib.sha1(p.read_bytes()).hexdigest() for p in libs}
    remote = ssh(host, f"cd {stage} && sha1sum *.so* 2>/dev/null").stdout
    got = {}
    for line in remote.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            got[parts[-1]] = parts[0]
    bad = [n for n, h in want.items() if got.get(n) != h]
    if bad:
        for n in bad:
            print(f"    sha1 MISMATCH: {n} (want {want[n][:12]}, "
                  f"got {(got.get(n) or 'MISSING')[:12]})")
        ssh(host, f"rm -rf {stage}")   # leave the working libs closure untouched
        raise SystemExit(f"FATAL: {len(bad)} lib(s) failed sha1 verification")
    # All staged libs verified — atomically-ish swap into place: drop the old
    # .so*/AppleDouble cruft, move the verified set in, remove the staging dir.
    ssh(host, f"rm -f {GAMEDIR}/libs/*.so* {GAMEDIR}/libs/._* && "
              f"mv -f {stage}/*.so* {GAMEDIR}/libs/ && rmdir {stage}", check=True)
    print(f"    sha1 ok for all {len(libs)} libs -> swapped into place")

    print("\n-- Uploading handler + launch scripts (sha1-verified) --")
    # sha1-verify EVERY artifact, not just the binary/libs: a truncated launcher
    # or handler silently bricks the no-fallback session (the daemon exec's a
    # half-written script), and FAT can leave a partial file on an interrupted
    # scp. (The CRLF-strip sed below runs AFTER this, so it only touches files
    # whose transfer already verified byte-exact.)
    scp_verified(host, handler, f"{GAMEDIR}/_handler.sh")
    for p in game_scripts:
        scp_verified(host, p, f"{GAMEDIR}/{p.name}")
    scp_verified(host, launcher, "/media/fat/Scripts/Solarus.sh")

    docs = REPO / "docs/Solarus/README.md"
    if docs.exists():
        scp_verified(host, docs, "/media/fat/docs/Solarus/README.md")

    if rbf:
        print(f"\n-- Uploading RBF {rbf.name} (sha1-verified) --")
        # The RBF is the largest single artifact and the most likely to truncate
        # on a partial transfer; a truncated core fails to load with no video.
        scp_verified(host, rbf, f"/media/fat/_Other/{rbf.name}")

    print("\n-- Fixing line endings + exec bits --")
    # IMPORTANT: only run the CRLF-stripping sed over the SHELL SCRIPTS. busybox
    # sed splits a file on \n and strips any line ending in \r — on the ELF
    # binary that deletes every 0x0D byte preceding a 0x0A, corrupting/truncating
    # it AFTER the verified upload (observed: 88 bytes removed -> segfault before
    # main). The binary just needs its exec bit; never sed it.
    sh_targets = " ".join(
        [f"{GAMEDIR}/_handler.sh"]
        + [f"{GAMEDIR}/{p.name}" for p in game_scripts]
        + ["/media/fat/Scripts/Solarus.sh"])
    ssh(host,
        f"for f in {sh_targets}; do "
        "sed -i 's/\\r$//' \"$f\" 2>/dev/null; chmod 755 \"$f\"; done; "
        f"chmod 755 {GAMEDIR}/solarus-run",
        check=True)

    print("\n-- Post-deploy link smoke test --")
    # A dead/incompatible lib closure passes sha1 (every file transferred intact)
    # yet segfaults at first launch — nothing above catches that. Run the engine's
    # -help (which returns before SDL/quest init) with the exact deploy env; the
    # dynamic loader aborts with a recognizable signature if any .so is missing or
    # ABI-incompatible. We key on the loader's error text (not -help's own exit
    # code, which we don't assume) so this can't spuriously fail a good deploy.
    print("-- $ ./solarus-run -help  (loader probe) --")
    probe = ssh(host,
                f"cd {GAMEDIR} && SDL_VIDEODRIVER=dummy "
                f"LD_LIBRARY_PATH={GAMEDIR}/libs:{GAMEDIR} ./solarus-run -help "
                "2>&1; echo \"__rc:$?\"")
    pout = (probe.stdout or "") + (probe.stderr or "")
    loader_errs = ("error while loading shared libraries",
                   "cannot open shared object", "undefined symbol")
    if any(sig in pout for sig in loader_errs):
        print(pout.strip())
        raise SystemExit(
            "FATAL: shipped lib closure does not link (loader error above) — the "
            "engine would segfault at first launch. Re-run scripts/"
            "collect_runtime_libs.sh and redeploy.")
    print("    lib closure links OK (no loader error)")

    # Software-only invariant: the engine is built with -force-software-rendering
    # and find_package(OpenGL) empty, so it must carry NO libGL/GLEW/EGL DT_NEEDED.
    # If one crept in it needs a Mesa libGL armhf we do NOT ship, so the engine
    # would fail to load on the device — a build regression, caught here explicitly
    # (clearer than the generic loader error above).
    print("-- $ ldd check: no libGL/GLEW/EGL DT_NEEDED (software-only) --")
    gl = ssh(host,
             f"cd {GAMEDIR} && LD_LIBRARY_PATH={GAMEDIR}/libs:{GAMEDIR} "
             "ldd ./solarus-run 2>/dev/null | grep -iE 'libGL|libGLEW|libEGL' || true")
    if (gl.stdout or "").strip():
        print(gl.stdout.strip())
        raise SystemExit(
            "FATAL: engine links libGL/GLEW/EGL — expected software-only "
            "(-force-software-rendering, no libGL shipped). Rebuild the engine "
            "without OpenGL (find_package(OpenGL) must be empty).")
    print("    no libGL/GLEW/EGL (software-only OK)")

    print("\n-- Starting core-load daemon (auto-launch without Frontier) --")
    # Start our Solarus daemon fresh (we killed any old one above). On first run
    # it self-registers into user-startup.sh so it persists across reboot; it
    # defers to Frontier's Master_Daemon when that is running. setsid detaches it
    # from this ssh session so it keeps running after deploy.
    r = ssh(host,
            f"setsid bash {GAMEDIR}/solarus_daemon.sh >/dev/null 2>&1 & sleep 1; "
            "ps -o pid,args 2>/dev/null | grep '[s]olarus_daemon.sh' "
            "|| echo 'WARN: solarus_daemon not running'")
    print(r.stdout.strip())

    # Double-launch guard: the core idles until a quest is picked, so at most ONE
    # solarus-run should ever be alive (a daemon+manager both spawning the engine
    # is the classic regression). Right after deploy — no pick yet — expect 0; >1
    # means a stray/duplicate engine survived teardown. Warn (non-fatal: a leftover
    # engine doesn't corrupt the install, and the manager reconciles on next pick).
    rc = ssh(host, "pidof solarus-run | wc -w")
    try:
        nrun = int((rc.stdout or "0").strip() or "0")
    except ValueError:
        nrun = 0
    if nrun > 1:
        print(f"    WARN: {nrun} solarus-run processes running (expected <=1) — "
              "possible double-launch; check the daemon/manager teardown")
    else:
        print(f"    solarus-run instances: {nrun} (<=1 OK)")

    print("\n-- Deployed tree --")
    r = ssh(host, f"ls -la {GAMEDIR}/ {GAMEDIR}/libs/ | head -60; "
                  "ls -la /media/fat/_Other/Solarus_*.rbf 2>/dev/null; "
                  "ls -la /media/fat/Scripts/Solarus.sh")
    print(r.stdout)

    print("Done. Load the Solarus core from the MiSTer menu — our solarus_daemon "
          "(or Frontier, if installed) auto-launches it; or run Scripts/Solarus.sh.")


if __name__ == "__main__":
    main()
