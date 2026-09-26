# Deploy recipe (end-user SD-mirror, task 007)

Moved out of `CLAUDE.md` so it loads only when you are actually deploying.
The **device gotchas** stay in `CLAUDE.md` — they apply to any push to the
device, not just a full deploy.

The repo IS the MiSTer SD-mirror tree (extracts to `/media/fat/`), modeled on
MiSTer_OpenBOR. End-user model: Scripts → Solarus loads the core and starts
`games/Solarus/launch.sh` → pick a quest from the native OSD file browser → the launcher runs
`solarus_start.sh <quest>`.

Layout (committed parts in **bold**; the rest are gitignored ship artifacts):
- `_Other/Solarus_YYYYMMDD.rbf` — branded core (CONF_STR setname=Solarus, `SC0,SOL`
  Load-Quest slot). Built in CI; `gh run download <id> -n solarus-rbf`. NOT committed.
- `games/Solarus/solarus-run` + `libs/` — engine + .so closure. Refresh from
  `build/armhf/{solarus-run,libsolarus.so.1.6.5}`. NOT committed.
- **`mister-port.toml`** — rendered by `external/mister-hybrid-platform`
  (`tools/mister_platform.py render`) into `games/Solarus/launch.sh` +
  `platform/` (launch_lib.sh, profile map, mem_wc modules),
  `Scripts/Solarus{,_CoresMenu}.sh`, `linux/hybrid.d/Solarus.conf`,
  `_Other/Solarus.mgl`; plus the shared `linux/MiSTer_hybrid` hook binary.
  **`dist/scripts-extra.sh`** is rendered into `Scripts/Solarus.sh`: pre-platform
  clean-up. **`[Solarus] main=MiSTer_hybrid` is NOT supported**: under it the core's
  DDR3 path is dead (scanout vsync counter frozen, C_DONE stuck; .81 2026-09-26), and
  the fabric stays broken for later loads until a reboot.
- **`games/Solarus/solarus_start.sh`** — per-quest engine start (quest link,
  diag.env, engine selector, blitter flags, exec).
- `games/Solarus/quests/<name>.sol` — quests. NOT committed.
- **`docs/Solarus/README.md`**, **`version.txt`**, **`README.md`**.

Quest packaging: a `.sol` IS a `data.solarus` archive = a zip of the quest's
`data/` CONTENTS (quest files at the zip ROOT, NOT under a `data/` prefix; MiSTer
OSD filters the 3-char `SOL` extension). `scripts/package_quest.sh <quest_dir>
[out.sol]`. `solarus-run` needs a quest DIRECTORY, so `solarus_start.sh` indirects:
`ln -sf <picked.sol> /tmp/solarus_quest/data.solarus` then
`exec ./solarus-run -force-software-rendering /tmp/solarus_quest`.

Quest selection: the OSD writes the picked path to `/media/fat/config/Solarus.s0`
(may have trailing `\r`/junk — trim CR and cut at the first `.sol`).
The launcher (`[launch.select]` in `mister-port.toml`, platform OSD file-select
mode) waits for a write to it after it started (a stale `.s0` from a prior
session is NOT auto-loaded) and starts/switches the engine on a pick. **No
fallback** — the core idles until a quest is picked (PICO-8/OpenBOR/PSX
pattern). Lock, other-engine stop, FPGA-ready wait, mem_wc, CPU isolation,
fabric gate and core-change watchdog are the platform's `launch_lib.sh`. Logs:
`/media/fat/logs/Solarus/solarus.log` (launcher + engine), `launch.log`.

Launch env (`[launch.env]`): `SDL_VIDEODRIVER=dummy`,
`LD_LIBRARY_PATH=<gamedir>/libs:<gamedir>`, `HOME=/media/fat/saves/Solarus`;
flag `-force-software-rendering`.

`./deploy.py [--no-rbf] [--host IP]` pushes the tree over SSH (key-authed; plain
ssh/scp/tar, no paramiko). It renders the launcher tree with the platform and
needs the `MiSTer_hybrid` hook binary (`HOOK_BIN`, default
`external/mister-hybrid-platform/build/main-hook/MiSTer_hybrid`, built by the
platform's `device/main-hook/build-hps.sh` or its CI artifact).

## Controller mapping (2026-07-25)

The core's OSD button list changed from five quest-specific names
(`Sword, Action, Item 1, Item 2, Pause`) to eight quest-neutral ones
(`A, B, X, Y, L, R, Select, Start`). Per-quest meaning now lives in
`/media/fat/games/Solarus/controls.cfg`, which you can edit on the SD card — no
rebuild needed.

**One-time step after installing this core:** the rename invalidates any existing
`Solarus_input.map` in `/media/fat/config`. Open the OSD and re-run **Define buttons**
once. Until you do, buttons will appear mismapped.

`controls.cfg` is seeded from `controls.cfg.default` only if it does not already exist,
so your edits survive a redeploy. To start over, delete `controls.cfg` and redeploy.
