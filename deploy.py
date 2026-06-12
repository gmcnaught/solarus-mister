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
    runscript = REPO / "games/Solarus/solarus_run.sh"
    launcher = REPO / "scripts/Solarus.sh"

    # Verify local source files exist.
    for p in (binary, handler, runscript, launcher):
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
        rbfs = sorted(glob.glob(str(REPO / "_Other" / "Solarus_*.rbf")))
        if rbfs:
            rbf = Path(rbfs[-1])
        else:
            print("note: no local _Other/Solarus_*.rbf — skipping RBF upload "
                  "(use `gh run download <id> -n solarus-rbf` to fetch one)")

    print(f"Deploying to {USER}@{host}\n")

    print("-- Stopping running engine --")
    # Device busybox has no pkill — use pidof. Then remove the old binary so the
    # scp can replace it (FAT can't overwrite a still-open exe in place).
    ssh(host, "kill -9 $(pidof solarus-run) 2>/dev/null; sleep 1; "
              f"rm -f {GAMEDIR}/solarus-run; rm -rf /tmp/solarus_quest; true")

    print("\n-- Creating remote dirs --")
    ssh(host, f"mkdir -p {GAMEDIR}/libs {GAMEDIR}/quests "
              "/media/fat/Scripts /media/fat/_Other /media/fat/logs/Solarus "
              "/media/fat/docs/Solarus", check=True)

    print("\n-- Uploading ARM binary (sha1-verified) --")
    scp_verified(host, binary, f"{GAMEDIR}/solarus-run")

    print(f"\n-- Uploading {len(libs)} runtime libs --")
    # Tar-pipe the libs in one shot. macOS bsdtar: drop AppleDouble/xattr cruft.
    # Device busybox tar: -o = don't restore owner (FAT can't chown).
    tar = subprocess.Popen(
        ["tar", "--no-xattrs", "--no-mac-metadata", "-C", str(libsdir),
         "-cf", "-"] + [p.name for p in libs],
        stdout=subprocess.PIPE)
    sh(["ssh", f"{USER}@{host}", f"tar -C {GAMEDIR}/libs -xof -"],
       stdin=tar.stdout, check=True)
    tar.wait()

    print("\n-- Uploading handler + launch scripts --")
    scp(host, handler, f"{GAMEDIR}/_handler.sh")
    scp(host, runscript, f"{GAMEDIR}/solarus_run.sh")
    scp(host, launcher, "/media/fat/Scripts/Solarus.sh")

    docs = REPO / "docs/Solarus/README.md"
    if docs.exists():
        scp(host, docs, "/media/fat/docs/Solarus/README.md")

    if rbf:
        print(f"\n-- Uploading RBF {rbf.name} --")
        scp(host, rbf, f"/media/fat/_Other/{rbf.name}")

    print("\n-- Fixing line endings + exec bits --")
    ssh(host,
        "for f in "
        f"{GAMEDIR}/_handler.sh {GAMEDIR}/solarus_run.sh "
        f"{GAMEDIR}/solarus-run /media/fat/Scripts/Solarus.sh; do "
        "sed -i 's/\\r$//' \"$f\" 2>/dev/null; chmod 755 \"$f\"; done",
        check=True)

    print("\n-- Deployed tree --")
    r = ssh(host, f"ls -la {GAMEDIR}/ {GAMEDIR}/libs/ | head -60; "
                  "ls -la /media/fat/_Other/Solarus_*.rbf 2>/dev/null; "
                  "ls -la /media/fat/Scripts/Solarus.sh")
    print(r.stdout)

    print("Done. Load the Solarus core from the MiSTer menu (auto-launch via "
          "Master_Daemon), or run Scripts/Solarus.sh.")


if __name__ == "__main__":
    main()
