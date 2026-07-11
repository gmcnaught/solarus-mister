# gprof profiling (Solarus engine + MiSTer Main)

Two binaries can be built with gcc's `-pg` mcount instrumentation to produce
gprof-compatible profiles. Both are **opt-in** — a normal build/ship path is
never instrumented — and both are cross-builds, so profiles are captured on the
DE10-Nano (or any armhf host) and post-processed on the build host with the
matching cross `gprof`.

| Target | Repo | Build knob | CI workflow |
| --- | --- | --- | --- |
| Solarus engine (`solarus-run` + `libsolarus`) | `solarus-mister` | `SOLARUS_GPROF=1 scripts/build_engine.sh` | `.github/workflows/build-engine-gprof.yml` |
| MiSTer Main (`MiSTer`) | `Main_MiSTer` | `make GPROF=1` | `.github/workflows/build-gprof.yml` |

## How `-pg` works (and why the rules below matter)

`-pg` makes the compiler emit an `mcount` call (`__gnu_mcount_nc` on ARM EABI) at
every function entry and links a startup hook that, **on normal process exit**,
writes a `gmon.out` with the call-arc counts + a PC-sampling histogram. `gprof`
then reads that plus the binary's symbol table.

Consequences baked into these builds:

- **`-pg` on compile *and* link, of every module that runs.** For Solarus nearly
  all code is in `libsolarus.so`, so the build puts `-pg` on the shared-library
  and executable link lines, not just the binary.
- **LTO off.** Cross-TU inlining dissolves the function boundaries gprof
  attributes samples to and can drop `mcount` calls. `SOLARUS_GPROF=1` forces
  `SOLARUS_LTO=OFF` for that build.
- **Not stripped.** gprof needs the symbol table. The Main Makefile skips
  `strip` when `GPROF=1`; `bin/MiSTer.elf` keeps symbols regardless.
- **Must exit normally to flush.** A `kill -9` writes nothing. On MiSTer the
  engine is normally `kill -9`'d on core-change, so to profile you must quit the
  quest through its in-game menu, or send `SIGTERM`/`SIGINT` (the atexit hook
  still runs).

## Solarus engine

### Build

```bash
# in solarus-mister/
docker build -f Dockerfile.solarus-build -t solarus-armhf-build:bullseye .
# (optional) match ship exactly with LuaJIT — needs the qemu binfmt handler:
#   docker run --rm --privileged tonistiigi/binfmt --install arm
#   scripts/docker_run.sh scripts/build_luajit.sh
# scripts/docker_run.sh forwards SOLARUS_GPROF / SOLARUS_USE_LUAJIT from the
# calling shell into the container (and handles the /src mount + worktree .git):
SOLARUS_GPROF=1 SOLARUS_USE_LUAJIT=0 scripts/docker_run.sh scripts/build_engine.sh
```

Output: instrumented `build/armhf/solarus-run` + `build/armhf/libsolarus.so.1.6.5`.
The `build-engine-gprof.yml` CI does exactly this and uploads them as the
`solarus-run-gprof` artifact.

> gprof profiles the engine's C/C++ code; it cannot see LuaJIT-compiled Lua
> (that's JIT machine code, no `mcount`). `SOLARUS_USE_LUAJIT=0` (vanilla Lua
> 5.1) is fine for engine profiling and avoids the qemu LuaJIT cross-build; use
> `=1` only to match the shipped binary's C-API costs exactly.

### Capture on device

Deploy the instrumented binary in place of the normal one, then launch with
profiling capture enabled (`solarus_run.sh` redirects `gmon.out` to a writable
dir when `SOLARUS_GPROF=1`, since the squashfs root is read-only):

```bash
# on MiSTer, e.g. via the Scripts launcher or ssh:
SOLARUS_GPROF=1 /media/fat/games/Solarus/solarus_run.sh
# ...play the section you want to profile, then QUIT via the in-game menu
#    (not a kill -9) so gmon.out is flushed.
ls /media/fat/logs/Solarus/gmon.out.*    # one per pid
```

### Report

Copy `gmon.out.<pid>` back next to the instrumented binary and run:

```bash
scripts/gprof_report.sh build/armhf/solarus-run gmon.out.<pid>
# -> build/armhf/gprof-report.txt  (flat profile + call graph)
```

`gprof_report.sh` prefers `arm-linux-gnueabihf-gprof` (cross binutils) and falls
back to the host `gprof`.

## MiSTer Main ("the Linux environment")

### Build

```bash
# in Main_MiSTer/
source ./setup_default_toolchain.sh   # fetches + PATHs the arm-none-linux-gnueabihf gcc
make GPROF=1                          # -> bin/MiSTer (unstripped) + bin/MiSTer.elf
```

`build-gprof.yml` CI runs this and uploads the `MiSTer-gprof` artifact.

### Capture + report

Run the instrumented `MiSTer` on device, let it **exit cleanly** (it writes
`gmon.out` to its CWD), copy that back, then:

```bash
arm-none-linux-gnueabihf-gprof bin/MiSTer.elf gmon.out > gprof-report.txt
```

## Notes

- Instrumented binaries are **slower** (an `mcount` call per function entry) and
  larger. Never ship a `-pg` build as a release binary.
- Both CI workflows are `workflow_dispatch` + path-filtered `push`; they upload
  artifacts only and never deploy.
