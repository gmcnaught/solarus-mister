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
scripts/release_test.sh all <rc-tag>    [--host IP]        # DESTRUCTIVE: wipes the device install (Gate 2); aborts before the wipe if Gate 1 recorded any FAIL — see "Notes on `all`"
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
non-zero. At the end of `gate1()` it validates `rbf_run_id` and
`engine_run_id` from the manifest — each must be a non-empty, plain-digit
string, since `pins.env` is later `.`-sourced by `publish-cmd` and a
manifest value that isn't plain digits (e.g. a stray `$(...)` in a corrupted
or malicious `BUILD-INFO.txt`) must never execute on the operator's host —
and only then writes `_rc/<tag>/pins.env`; a run that FAILed that validation,
or any earlier download/unzip failure, leaves no `pins.env` at all. `pins.env`
is read solely by `publish-cmd` — **Gate 2 never reads it** (Gate 2's only
Gate-1 dependency is `rc.zip` + `tree/BUILD-INFO.txt` existing on disk).
`publish-cmd` also refuses outright if `_rc/<tag>/results.tsv` contains any
`FAIL` row, so it cannot print a publish command for an RC that failed
provenance, structure, or any other Gate 1 (or Gate 2) check even though
`pins.env` itself is present and well-formed.

**Most common failure:** CHECK `rbf is current` (or `engine is current`),
DETAIL `rebuild needed; changed: …`. The named files changed after the
artifact was built, so the zip does not contain them. Re-run that build
workflow on master, then re-dispatch `release.yml` for the RC tag with the
new run-id pinned. Do **not** relax the check.

## 3. Gate 2 — install + boot + soak (device)

**Before running:** the device must already have at least one quest `.sol` in
`/media/fat/games/Solarus/quests/`. The release zip carries **no quests** —
the only source of `.sol` files Gate 2 knows about is its own `_rcsave`
restore of whatever was already installed. On a freshly-flashed card with no
prior Solarus install, Gate 2 will wipe, install, and sha256-verify — then
hard-stop at "quest available" *before it ever loads the core*, leaving a
quest-less install, no running engine, and `Master_Daemon` already dead, with
no chance to back out first.

```bash
scripts/release_test.sh gate2 v1.1.0-rc1 --host 192.168.20.81
```

Requires Gate 1 to have already run for this tag (it checks for
`_rc/<tag>/rc.zip` and `_rc/<tag>/tree/BUILD-INFO.txt` before touching the
device — if either is missing it fails the first row and stops, it does not
guess).

**Wall time:** Gate 2 blocks for **12+ minutes minimum** — up to a 90s
fps-ready poll, a 30s fps sample, `--soak-min` (default 10, i.e. 600s) of
soak, plus assorted fixed sleeps around the launch/wipe steps. It is easy to
mistake this for a hang. Use `--soak-min N` with a small `N` to shorten the
soak for local rehearsal — but a real release sign-off should use the
default (or larger).

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

**Savegames are unaffected by the wipe.** `games/Solarus/solarus_run.sh` sets
`HOME=/media/fat/saves/Solarus`, so Solarus writes savegames there, outside
the `games/Solarus` tree the wipe deletes. An operator authorizing the wipe
is not risking player save data.

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

Only then re-run Gate 2. The bare `gate2` subcommand drops its own prior rows
(matched by the GATE field, `gate2`) from `results.tsv` before appending the
retry's rows — Gate 1's rows for the same tag are untouched — so the aborted
run's `FAIL … no leftover backup` row does not linger and does not cause a
clean retry to still report a stale failure.

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
(known-safe recipe: the wipe above **deleted** `config/Solarus.s0` and it is
never recreated — the launch uses an `S0_FILE=/tmp/rc_s0` override instead,
so the card is left with no `Solarus.s0` all the way into Gate 3 — detached
so it survives SSH disconnect, logged to `/media/fat/logs/rc-<tag>.log`) →
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

Gate 2 leaves an engine running, so this looks like it risks two concurrent
`solarus-run` processes (the documented host-wedge condition) — it does not.
`scripts/Solarus.sh` stops the running engine itself before it loads
anything: it kills any `quest_manager.sh` via a ps-grep loop, then `kill -9`s
any `solarus-run` PIDs (guarded against the empty-PID case), sleeps, ensures
`solarus_daemon.sh` is running, and only then loads the core. It is safe to
run as-is while Gate 2's engine is still up.

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

**Items 2 and 8 depend on `solarus_daemon.sh` / `quest_manager.sh`**, which
Gate 2's preflight killed along with `Master_Daemon`. Running
`Scripts/Solarus.sh` above restarts `solarus_daemon.sh` — Solarus's own
Frontier-independent core-load watcher, which is what actually drives OSD
Load Quest and quest-switch/core-reload for this core — so items 2 and 8, as
scored here, **do** exercise the genuine end-user path and a FAIL is a real
defect, not a side effect of the gate. What is *not* restored is Frontier's
`Master_Daemon` itself (down until a reboot); if your real deployment relies
on Frontier rather than `solarus_daemon.sh`, re-check items 2 and 8 again
after a reboot.

Any FAIL stops the release.

## 5. Publish the tested artifacts

```bash
scripts/release_test.sh publish-cmd v1.1.0-rc1
```

Reads the pins Gate 1 recorded for this RC tag and prints the exact command,
e.g.:

```bash
gh workflow run release.yml \
  --ref v1.1.0-rc1 \
  -f tag=v1.1.0 \
  -f rbf_run_id=<pinned> \
  -f engine_run_id=<pinned>
```

**`--ref <rc-tag>` is required, not decorative.** `release.yml`'s "Assemble
SD-mirror tree" step copies ten repo-sourced files straight from this run's
checkout — the six `games/Solarus/*.sh` launch scripts, `controls.cfg.default`,
`Scripts/Solarus.sh`, `docs/Solarus/README.md`, and the quests placeholder —
into the zip alongside the pinned RBF/engine artifacts. A `workflow_dispatch`
with no `--ref` checks out whatever is on the default branch at dispatch time,
which is not necessarily what Gates 1-3 tested; a commit landing on master
during Gate 2's 12-minute soak would ship untested launch scripts under the
RC's own tested name. `--ref` pins the dispatch (and therefore the checkout,
and therefore those ten files, and `github.sha`) to the exact RC tag commit.
`release.yml`'s publish step also passes that same `github.sha` as `--target`
to `gh release create`, so the *git tag* it creates for the new release
(`v1.1.0` here) points at that commit too — without `--target`, `gh release
create` would tag the repository's default-branch HEAD instead, which can
silently drift from the tested commit between Gate 1 and publish.

**The release tag (`tag=` above) is derived, not chosen:** `publish-cmd`
strips a trailing `-rcN` from the RC tag (`sed 's/-rc[0-9]*$//'`) to get it.
Name your RC tags `<release-tag>-rcN` (e.g. `v1.1.0-rc1` → `v1.1.0`) so this
comes out right; an RC tag that doesn't end in `-rcN` publishes under the RC
tag name itself, unchanged.

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

**Local prerequisite:** Gate 4 reads `_rc/<rc-tag>/tree/BUILD-INFO.txt` from
disk — it does not re-download the RC. Run it on the same machine (and before
cleaning `_rc/`) that ran Gate 1 for `<rc-tag>`, or you'll need to re-run
Gate 1 for that tag first.

## 7. Record the sign-off

Copy `docs/superpowers/releases/TEMPLATE-rc-test.md` to
`docs/superpowers/releases/<tag>-rc-test.md`, paste the gate tables, fill in
the Gate 3 results and the measured fps, and commit it.

## Notes on `all`

`scripts/release_test.sh all <rc-tag>` runs Gate 1, and **stops before
touching the device if Gate 1 recorded any `FAIL` row** — it greps
`results.tsv` for `^FAIL` after `gate1` returns and, if it finds one, prints
the report and exits 1 without running Gate 2 at all. This matters because
`gate1()` itself always `return 0`s, even on a FAIL (every failure branch is
an explicit `return 0` so the row still gets rendered) — so a plain `gate1 &&
gate2` would not have stopped anything; the `all` arm gates on the results
file instead, deliberately, for exactly this reason.

Only if Gate 1 is clean does `all` proceed to Gate 2's device wipe, then
prints the combined report and, on success, the publish command.

Prefer running `gate1` and `gate2` as separate steps (as above) when you want
to read the Gate 1 table yourself before anything touches the device; use
`all` for the common case where you're happy to let a clean Gate 1 proceed
straight into Gate 2 unattended.
