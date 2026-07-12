#!/usr/bin/env python3
"""
Deploy the Solarus MiSTer port to a running MiSTer over SSH.

Modeled on MiSTer_OpenBOR_7533/deploy.py, but uses plain ssh/scp (the device is
SSH-key-authed — `ssh root@<HOST>` needs no password) instead of paramiko, so it
runs without extra Python deps.

What it does:
  1. Stops any running solarus-run engine (so libs/binary can be replaced).
  2. Uploads the ARM binary, runtime libs, handler + launch scripts, and the
     branded RBF.
  3. Installs the Scripts-menu launcher to /media/fat/Scripts/Solarus.sh.
  4. Fixes line endings + exec bits on the shell scripts.

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
    """scp + sha1 verify, retrying on mismatch.

    FAT on the device can leave a TRUNCATED file on a partial scp (a truncated
    executable then segfaults before main with no output). Always verify.
    """
    import hashlib
    want = hashlib.sha1(Path(src).read_bytes()).hexdigest()
    for attempt in range(1, retries + 1):
        ssh(host, f"rm -f {dst}")
        scp(host, src, dst)
        got = ssh(host, f"sha1sum {dst} 2>/dev/null").stdout.split()[:1]
        if got and got[0] == want:
            print(f"    sha1 ok ({want[:12]})")
            return
        print(f"    sha1 mismatch (attempt {attempt}/{retries}) — retrying")
    raise SystemExit(f"FATAL: {dst} failed sha1 verification after {retries} tries")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--no-rbf", action="store_true",
                    help="skip uploading the branded RBF")
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

    # Verify local source files exist.
    for p in (binary, handler, launcher, *game_scripts):
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
    # is a real binary so pidof finds it. Then remove the old binary so the scp
    # can replace it (FAT can't overwrite a still-open exe in place). The daemon is
    # restarted fresh after upload so the new code takes effect.
    ssh(host, "for pat in '[s]olarus_daemon.sh' '[q]uest_manager.sh'; do "
              "for p in $(ps -o pid,args 2>/dev/null | grep \"$pat\" | awk '{print $1}'); do "
              "kill -9 \"$p\" 2>/dev/null; done; done; "
              "kill -9 $(pidof solarus-run) 2>/dev/null; sleep 1; "
              f"rm -f {GAMEDIR}/solarus-run; rm -rf /tmp/solarus_quest; true")

    print("\n-- Creating remote dirs --")
    ssh(host, f"mkdir -p {GAMEDIR}/libs {GAMEDIR}/quests "
              "/media/fat/Scripts /media/fat/_Other /media/fat/logs/Solarus "
              "/media/fat/docs/Solarus", check=True)

    # Safety (#91): remove any stale diag.env. A dev-left file would otherwise
    # silently enable diagnostics (SOLARUS_BLITTER_DIAG / SOLARUS_BGPLANE = known
    # visual regressions) on an end-user device. Diagnostics are opt-in: after
    # deploy, recreate diag.env AND launch with SOLARUS_ALLOW_DIAG_ENV=1 (see
    # solarus_run.sh) to use it — a bare file is now ignored by the launcher too.
    print("\n-- Removing stale diag.env (diagnostics are opt-in) --")
    ssh(host, f"rm -f {GAMEDIR}/diag.env", check=False)

    print("\n-- Uploading ARM binary (sha1-verified) --")
    scp_verified(host, binary, f"{GAMEDIR}/solarus-run")

    print(f"\n-- Uploading {len(libs)} runtime libs (sha1-verified) --")
    # Clear stale libs FIRST: FAT extract over an existing .so can leave a
    # truncated/partial file, and the tar-pipe is unverified — so a stale
    # libsolarus.so silently survives (observed: lib sha mismatched while the
    # binary matched). rm them, then extract, then verify EVERY lib's sha1.
    ssh(host, f"rm -f {GAMEDIR}/libs/*.so* {GAMEDIR}/libs/._*", check=False)
    # Tar-pipe the libs in one shot. macOS bsdtar: drop AppleDouble/xattr cruft.
    # Device busybox tar: -o = don't restore owner (FAT can't chown).
    tar = subprocess.Popen(
        ["tar", "--no-xattrs", "--no-mac-metadata", "-C", str(libsdir),
         "-cf", "-"] + [p.name for p in libs],
        stdout=subprocess.PIPE)
    sh(["ssh", f"{USER}@{host}", f"tar -C {GAMEDIR}/libs -xof -"],
       stdin=tar.stdout, check=True)
    tar.wait()
    # Verify each lib landed intact — one stale .so segfaults the engine with no
    # useful output, so fail the deploy loudly here instead.
    import hashlib
    want = {p.name: hashlib.sha1(p.read_bytes()).hexdigest() for p in libs}
    remote = ssh(host, f"cd {GAMEDIR}/libs && sha1sum *.so* 2>/dev/null").stdout
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
        raise SystemExit(f"FATAL: {len(bad)} lib(s) failed sha1 verification")
    print(f"    sha1 ok for all {len(libs)} libs")

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
