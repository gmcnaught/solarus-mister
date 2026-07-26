# Deploy recipe (end-user SD-mirror, task 007)

Moved out of `CLAUDE.md` so it loads only when you are actually deploying.
The **device gotchas** stay in `CLAUDE.md` — they apply to any push to the
device, not just a full deploy.

The repo IS the MiSTer SD-mirror tree (extracts to `/media/fat/`), modeled on
MiSTer_OpenBOR. End-user model: load the **Solarus** core from the MiSTer OSD →
Master_Daemon (Frontier) routes by CORENAME → runs `games/Solarus/_handler.sh` →
engine auto-launches; pick a quest from the native OSD file browser.

Layout (committed parts in **bold**; the rest are gitignored ship artifacts):
- `_Other/Solarus_YYYYMMDD.rbf` — branded core (CONF_STR setname=Solarus, `SC0,SOL`
  Load-Quest slot). Built in CI; `gh run download <id> -n solarus-rbf`. NOT committed.
- `games/Solarus/solarus-run` + `libs/` — engine + .so closure. Refresh from
  `build/armhf/{solarus-run,libsolarus.so.1.6.5}`. NOT committed.
- **`games/Solarus/_handler.sh`** — Master_Daemon auto-launch dispatcher.
- **`games/Solarus/solarus_run.sh`** — shared launch logic (env + quest resolve +
  exec), called by BOTH the handler and the Scripts launcher.
- `games/Solarus/quests/<name>.sol` — quests. NOT committed.
- **`scripts/Solarus.sh`** → deploys to `/media/fat/Scripts/Solarus.sh` (manual
  launcher: load_core + run shared logic).
- **`docs/Solarus/README.md`**, **`version.txt`**, **`README.md`**.

Quest packaging: a `.sol` IS a `data.solarus` archive = a zip of the quest's
`data/` CONTENTS (quest files at the zip ROOT, NOT under a `data/` prefix; MiSTer
OSD filters the 3-char `SOL` extension). `scripts/package_quest.sh <quest_dir>
[out.sol]`. `solarus-run` needs a quest DIRECTORY, so the handler indirects:
`ln -sf <picked.sol> /tmp/solarus_quest/data.solarus` then
`exec ./solarus-run -force-software-rendering /tmp/solarus_quest`.

Quest selection: the OSD writes the picked path to `/media/fat/config/Solarus.s0`
(may have trailing `\r`/junk — trim CR and cut at the first `.sol`).
`quest_manager.sh` polls it by mtime (a stale `.s0` from a prior session is NOT
auto-loaded) and launches/switches the engine on a pick. **No fallback** — the
core idles until a quest is picked (PICO-8/OpenBOR/PSX pattern). Auto-launch
comes from `solarus_daemon.sh` (Frontier-independent core-load watcher,
self-registers into `user-startup.sh`; defers to Frontier's Master_Daemon if
that is running).

Launch env: `SDL_VIDEODRIVER=dummy`, `LD_LIBRARY_PATH=<gamedir>/libs:<gamedir>`,
flag `-force-software-rendering`.

`./deploy.py [--no-rbf] [--host IP]` pushes the tree over SSH (key-authed; plain
ssh/scp/tar, no paramiko).

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
