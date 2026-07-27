# Release testing recipe

How a release candidate is validated before it is published. Design rationale
lives in `docs/superpowers/specs/2026-07-26-release-testing-recipe-design.md`.
This doc describes the shipped `scripts/release_test.sh` as it actually
behaves — where an earlier draft of this recipe said something different, the
script wins and the difference is called out below.

Flow: **tag an RC from master → run three gates → publish the tested artifacts
with their run-ids pinned → verify what was published.**

```
scripts/release_test.sh gate1 <rc-tag>  [--zip PATH]
scripts/release_test.sh gate2 <rc-tag>  [--host IP] [--soak-min N]
scripts/release_test.sh gate4 <release-tag> --rc <rc-tag>
scripts/release_test.sh publish-cmd <rc-tag>
scripts/release_test.sh all <rc-tag>    [--host IP]        # see the warning in step 3
```

`--host` defaults to `192.168.20.81`. `--soak-min` defaults to `10` and must be
a positive integer (the script validates this up front and refuses a bad value
before anything device-side runs). Working state — the downloaded zip, the
extracted tree, and the running results table — lives in `_rc/<tag>/`
(gitignored); it is keyed by tag, so Gate 1 and Gate 2 for the same tag share
one results table, and re-running a gate for the same tag reuses that
directory.

## 0. Pre-tag

- [ ] `origin/master` is green and is the commit you intend to ship.
- [ ] `version.txt` names the RBF this release actually carries. Gate 1
      asserts this; fix it before tagging, not after.
- [ ] `build-rbf` and `build-engine-ship` have a successful run covering any
      change to their trigger paths (`fpga/**`; `patches/**` and the build
      scripts). If not, Gate 1 will fail with "rebuild needed" and name the
      files.
- [ ] `git fetch --tags` — Gate 1's provenance checks resolve the tag and walk
      history locally; a tag you haven't fetched reads as "not found".
- [ ] `gh auth status` succeeds — Gate 1 downloads the release asset with
      `gh release download`, and Gate 4 with `gh release view` /
      `gh release download`.

## 1. Tag the RC

```bash
git checkout master && git pull
git tag v1.1.0-rc1 && git push origin v1.1.0-rc1
```

The hyphen in the tag makes `release.yml` publish it as a pre-release
automatically. Wait for the Release workflow to finish.

## 2. Gate 1 — provenance + structure (host)

```bash
git fetch --tags
scripts/release_test.sh gate1 v1.1.0-rc1
```

Downloads the RC asset (or copies a local zip with `--zip PATH`, useful for
offline iteration), extracts it, and checks the manifest, provenance against
master, and the tree structure. Every check prints a row; any FAIL exits
non-zero. On success it records `rbf_run_id` and `engine_run_id` to
`_rc/<tag>/pins.env` — these are the pins Gate 2 needs and the publish step
uses.

**Most common failure:** `<artifact> is current — rebuild needed; changed: …`.
The named files changed after the artifact was built, so the zip does not
contain them. Re-run that build workflow on master, then re-dispatch
`release.yml` for the RC tag with the new run-id pinned. Do **not** relax the
check.

## 3. Gate 2 — install + boot + soak (device)

```bash
scripts/release_test.sh gate2 v1.1.0-rc1 --host 192.168.20.81
```

Requires Gate 1 to have already run for this tag (it checks for
`_rc/<tag>/rc.zip` and `_rc/<tag>/tree/BUILD-INFO.txt` before touching the
device — if either is missing it fails the first row and stops, it does not
guess).

**This wipes the Solarus install on the card** — `games/Solarus/`, every
`_Other/Solarus_*.rbf`, `Scripts/Solarus.sh`, and the stale
`config/Solarus.s0` + `Solarus_input.map`. Quests and `controls.cfg` are
preserved and restored. The wipe is the point: it is what makes a file missing
from the zip fail loudly instead of being masked by a leftover dev deploy, and
what collapses the multi-core ambiguity on the card. **The order is
deliberately safe:** the RC zip is uploaded to the device and its size is
verified, and the quest/`controls.cfg` backup is copied and verified, **before
the wipe runs**. If any of that verification fails, the gate stops and the
existing install is left untouched.

**If a prior run aborted mid-flight, Gate 2 refuses to run at all.** It checks
for a leftover `/media/fat/_rcsave` on the card — that directory is the
in-flight backup of the operator's `quests/*.sol` and `controls.cfg`, and if a
previous Gate 2 run died between "backup" and "restore" it is left behind as
the *only* surviving copy of those files. Gate 2 will not wipe anything while
it exists. To recover:

```bash
ssh root@192.168.20.81 'ls /media/fat/_rcsave'
# copy what's there back into /media/fat/games/Solarus/quests/ and
# /media/fat/games/Solarus/controls.cfg as appropriate, then:
ssh root@192.168.20.81 'rm -rf /media/fat/_rcsave'
```

Only then re-run Gate 2.

**Gate 2 stops Frontier's `Master_Daemon` and does not restart it.** This is
required so the daemon can't race the gate's own scripted launch into a second
engine (the documented host-wedge condition). It means OSD-driven auto-launch
is gone for the rest of the session: after Gate 2, running
`sh /media/fat/Scripts/Solarus.sh` on the device starts the Solarus daemon
(`solarus_daemon.sh`) fine, but `Master_Daemon` itself only comes back on a
**reboot** of the device. If you need Frontier's daemon back before then,
reboot; there is no soft restart path from this recipe.

What it does, in order: preflight (kill any running engine + the daemon
family, confirm none remain) → leftover-backup check → upload the zip and
verify its size on the device → back up quests + `controls.cfg` (verified) →
**wipe** → extract the zip → restore quests + `controls.cfg` (verified; if the
restore can't be verified it does **not** delete `_rcsave`, so the next run's
leftover-backup check catches it) → sha256-verify the installed RBF /
`solarus-run` / `libsolarus.so.1.6.5` against the manifest → confirm exactly
one RBF on the card → link probe (`solarus-run -help`) and confirm no
`libGL`/`GLEW`/`EGL` in `ldd` output → load the core and launch the engine
(known-safe recipe: `Solarus.s0` left empty, `S0_FILE` override, detached so
it survives SSH disconnect, logged to `/media/fat/logs/rc-<tag>.log`) →
confirm a single engine process → assert the log contains
`renderer active (DDR @`, `ring double-buffer ENABLED`, `tilemap channel
ENABLED` and none of `video-region map failed`, `reverting to SDL`,
`pass-through SDLRenderer` → **wait for fps to first reach the floor** (polls
the frame counter once a second, up to 90s, until two consecutive samples are
at or above 45fps — preload of a whole-quest atlas can legitimately take a
while, so this is not a fixed sleep) → **sample fps for 30s and take the
strict minimum**, must be ≥45 → soak for `--soak-min` (default 10) → confirm
still alive, confirm it's the **same pid** (catches a crash-then-relaunch that
a bare "something named solarus-run is running" would miss), confirm the
frame counter is still advancing.

Leaves the engine **running** for Gate 3.

## 4. Gate 3 — operator visual gate (your eyes)

Nothing here is scripted; visual correctness is not self-declared in this
project. Start the real user path first:

```bash
ssh root@192.168.20.81 'sh /media/fat/Scripts/Solarus.sh'
```

Then check, in order:

| # | Check | PASS/FAIL |
|---|---|---|
| 1 | Title screen renders clean — **garbage tiles here means the wrong RBF** | |
| 2 | OSD **Load Quest** boots each installed quest | |
| 3 | Loading bar advances during preload | |
| 4 | Overworld walk — no seams, flat frames, or garbage | |
| 5 | Dialog box renders and dismisses | |
| 6 | Save-file select and in-game menu render | |
| 7 | **Define buttons** once, then all buttons act per `controls.cfg` | |
| 8 | Quest switch and core reload without a wedge | |

Item 7 is required, not optional: the eight-name OSD rename invalidates any
prior `Solarus_input.map`, and Gate 2 deleted it. Item 1 is the pairing canary
— the engine and RBF are a matched pair with no version handshake, so a
mismatch shows up as garbage tiles rather than an error.

Any FAIL stops the release.

## 5. Publish the tested artifacts

```bash
scripts/release_test.sh publish-cmd v1.1.0-rc1
```

Reads the pins Gate 1 recorded for this RC tag and prints the exact command,
e.g.:

```bash
gh workflow run release.yml \
  -f tag=v1.1.0 \
  -f rbf_run_id=<pinned> \
  -f engine_run_id=<pinned>
```

If Gate 1 hasn't been run for this tag, or its manifest was missing a run-id,
`publish-cmd` refuses and tells you which gate to re-run rather than printing
a broken command.

**Never publish by pushing the release tag blind.** A tag push re-resolves
"latest successful on master", so if master moved you would ship binaries
nobody tested.

## 6. Gate 4 — post-publish identity (host)

```bash
scripts/release_test.sh gate4 v1.1.0 --rc v1.1.0-rc1
```

`--rc` is required — `gate4` compares the *published* tag's artifact against
the *RC* that passed Gates 1–3, so it needs both. It also refuses if the two
tags are equal (comparing the RC against itself proves nothing about what got
published). Downloads the published zip and asserts its commit, run-ids, and
payload sha256s are byte-identical to the RC's (`tag` and `built_utc` are
allowed to differ — they always do), that the tree structure is intact, that
the release is marked **Latest**, and that it is **not** a pre-release.

## 7. Record the sign-off

Copy `docs/superpowers/releases/TEMPLATE-rc-test.md` to
`docs/superpowers/releases/<tag>-rc-test.md`, paste the gate tables, fill in
the Gate 3 results and the measured fps, and commit it.

## Notes on `all`

`scripts/release_test.sh all <rc-tag>` runs Gate 1 then Gate 2 back to back
and prints one combined report at the end. **Be aware it does not stop between
them on a Gate 1 failure:** Gate 2 only checks that the RC zip and manifest
*exist* on disk (i.e. that Gate 1 got far enough to download and extract), not
that every Gate 1 row PASSed — so a Gate 1 provenance or structure FAIL (wrong
commit, extra RBF, bad ELF, etc.) does not by itself stop Gate 2's device wipe.
For that reason, prefer running `gate1` and `gate2` as separate steps (as
above) and reading the Gate 1 table before you let Gate 2 touch the device.
