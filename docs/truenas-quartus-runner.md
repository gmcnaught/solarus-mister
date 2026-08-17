# Quartus build runner on TrueNAS SCALE

Runs the Solarus RBF build on the NAS as a self-hosted GitHub Actions runner, so
`fpga/build_solarus.sh` no longer depends on the self-hosted Windows box or on
GitHub-hosted minutes — and so seed sweeps become cheap.

| Path | What it is |
| --- | --- |
| `fpga/docker/quartus-runner.df` | The image: Quartus 17.0 + Actions runner, one container |
| `fpga/docker/build-runner-image.sh` | Builds that image on the NAS |
| `.github/runners/truenas/quartus-runner.compose.yaml` | The Custom App definition — paste into TrueNAS |
| `.github/runners/truenas/runner.env.example` | Template for the PAT file (the real one never enters git) |
| `fpga/scripts/seed_sweep.sh` | Seed retry for timing closure, modeled on `jtutil seed` |
| `.github/workflows/build-rbf.yml` → `build-nas` | The CI side, dispatch-only for now |

Applies to **TrueNAS SCALE 24.10 (Electric Eel) and newer**, where Apps run on
native Docker + docker-compose. On 24.04 and earlier, Apps run on k3s — see
[Older SCALE](#older-scale-k3s).

---

## The reference model: jotego's JTFRAME

[jotego/jtcores](https://github.com/jotego/jtcores) compiles ~100 MiSTer cores
nightly and is the most battle-tested "Quartus in CI" setup in this ecosystem.
This design follows it. What they actually do:

| Thing | JTFRAME | Notes for us |
| --- | --- | --- |
| Runner | **`ubuntu-latest` only — no self-hosted runners at all** | They buy parallelism from GitHub; we buy it with hardware we already own |
| Fan-out | Matrix over cores, `fail-fast: false` | We have one core, so no matrix |
| Toolchain | Own images `jotego/jtcore13/17/20/24` | We build one, `solarus-quartus-runner:17.0` |
| Image base | **Ubuntu 24.04, Quartus `COPY`'d in** as a directory tree | The key idea — see below |
| Entry point | One script, `xjtcore.sh`, is the whole CI↔build contract | `build_solarus.sh` already plays this role |
| Timing closure | **`jtutil seed --max-trials 4`** on every build | Adopted as `seed_sweep.sh` |
| Disk | `rm -rf` the build dir after each target | Matters on a NAS too |
| Nightly | Scheduled build that **skips if the previous run succeeded on the same SHA** | Not adopted yet — see [Not adopted](#not-adopted-yet) |
| Host docker | Their devops installer sets up **rootless** Docker | Moot for us now; would have mattered a lot under the socket design |

Their Quartus versions are 13.1 (MiST), 20.1 (MiSTer/Pocket/SiDi) and 24.1std.
We stay on 17.0 — it is what this core's `.qsf` and the MiSTer framework target,
and there is no reason to move.

### The one idea that drives everything here

jotego's `jtcore-base.df` is **`FROM ubuntu:24.04`**, and each toolchain image
copies Quartus in as a plain directory tree:

```dockerfile
COPY --from=intelfpga_lite 20.1/quartus /opt/intelFPGA_lite/20.1/quartus
```

They do **not** build on top of whatever distro the toolchain shipped against.
Quartus is treated as a bag of files that runs on a current OS given a few shim
libraries — their base image installs `libglib2.0-0` with the comment *"Needed by
Quartus 17"* and pins an `en_US.UTF-8` locale, and that is essentially the whole
compatibility story. They do this for 17.1, 20.1 **and** 24.1std, nightly.

That matters because `raetro/quartus:17.0` — the image this repo's `build-linux`
leg uses — is **Debian 9, glibc 2.24**, and a current Actions runner cannot run
there at all: `node20`, which `actions/checkout@v4` and `upload-artifact@v4`
execute under, needs **glibc ≥ 2.28**. Installing the runner into that image
fails on the first step with

```
/__e/node20/bin/node: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.28' not found
```

There are two ways around that. The first version of this document took the
wrong one.

> **Correction.** The earlier design kept the runner and Quartus in separate
> containers, with the runner mounting `/var/run/docker.sock` to start Quartus
> as a sibling — and dismissed the single-image alternative as "a new
> unvalidated combination". That was wrong: it is precisely what JTFRAME runs in
> production across three Quartus versions. Lifting the Quartus tree onto a
> modern base is the validated path, and the socket-mount design was solving a
> problem that did not need to exist.

So: **one container**, `raetro/quartus:17.0` as a donor stage for `/opt/intelFPGA`
only, `myoung34/github-runner:ubuntu-noble` (Ubuntu 24.04) as the real base.
Their *pattern*, our *bits* — the Quartus binaries stay byte-identical to the
hosted `build-linux` leg, and nobody has to download 1.5 GB from Intel.

Three problems disappear with the socket:

- **No root-equivalent access to the NAS.** A mounted docker socket lets any job
  do anything to the host. Gone.
- **No workspace path aliasing.** Under the socket design, `$PWD` in the inner
  `docker run` was resolved by the *host* daemon, so the runner's workspace had
  to exist at the same absolute path inside and outside its container — get it
  wrong and Quartus silently mounts an empty directory and fails with
  `Solarus.qpf: No such file or directory`. That failure mode no longer exists.
- **Resource limits work.** Quartus is now a process in the app container, so
  `mem_limit`/`cpus` in the compose file actually bind the fitter. Under the
  socket design they would have constrained the runner's bookkeeping and left
  the memory-hungry process free.

The remaining cost is that the image must be built on the NAS rather than
pulled. That is one command and it is the right trade.

### Front-loading the compatibility risk

The genuinely uncertain part of the image is the shim library list — Quartus
17.0 is a 2017 toolchain and the exact set it wants on Ubuntu 24.04 can only be
settled by running it. So `quartus-runner.df` ends with:

```dockerfile
RUN quartus_sh --version && quartus_map --version && quartus_fit --version && quartus_sta --version
RUN quartus_sh --tcl_eval "puts [get_family_list]" | grep -qi "Cyclone V"
```

A missing library therefore fails `docker build` in seconds with a loader error
naming the `.so`, instead of failing an hour into the first real CI job. **A
broken image cannot be produced.** If it does fail, add the library to the apt
list; if it wants `libpng12` (which Ubuntu dropped and the donor image installs
from a xenial `.deb`), lift it from the donor stage — the Dockerfile has the
exact `COPY` line in a comment.

---

## Setup — start to finish from the TrueNAS shell

Every step below is SSH except step 7 (creating the app), which has to go through
the web UI — see the note there for why.

**Nothing gets installed on the NAS.** TrueNAS SCALE ships a **read-only root
filesystem with `apt` disabled**, deliberately, and the supported way to keep it
that way is to not need it. This process uses only `curl`, `docker` and `zfs`,
all present by default. If you find yourself reaching for `install-dev-tools` or
`disable-rootfs-protection`, stop — nothing here requires them.

### 0. Connect, and set your pool name

```bash
ssh root@<nas-ip>
# If your NAS logs you in as `admin` rather than root, become root first —
# docker and zfs both need it:
#   sudo -i

zpool list -o name,size,free
```

Pick the pool you want the build workspace on and set it once. **Every command
below uses `$POOL`**, so re-set it if the shell drops:

```bash
POOL=tank        # <-- change to your pool name
```

### 1. Check space

Two different datasets absorb the cost, and it's worth confirming both before a
40-minute build:

```bash
# Where the IMAGE lands (~16 GB) — the apps dataset, wherever apps are configured
zfs list -o name,used,avail "$POOL/ix-apps" 2>/dev/null || echo "apps pool is elsewhere — check Apps -> Settings"

# Where the BUILDS land
zfs list -o name,used,avail "$POOL"
```

Want **≥ 40 GB free** on the apps dataset for the image, and **≥ 20 GB** on the
build dataset. A seed sweep keeps every trial's output, so add a few GB per
trial beyond that.

### 2. Create the build dataset

```bash
zfs create -o atime=off -o compression=lz4 "$POOL/ci"
zfs create -o atime=off -o compression=lz4 "$POOL/ci/quartus-runner"
mkdir -p "/mnt/$POOL/ci/quartus-runner/work"

# Optional but recommended — this is pure scratch (every input is re-cloned from
# git, every output is a CI artifact), so losing acknowledged writes on power
# loss costs a re-run and nothing else.
zfs set sync=disabled "$POOL/ci/quartus-runner"

zfs list -r "$POOL/ci"
```

Datasets created from the CLI show up in the UI normally. **Go to Datasets in
the UI afterwards and make sure no periodic snapshot task covers `$POOL/ci`** —
Quartus's `db/` churns many GB per build with nothing recoverable in it.

### 3. Fetch the build inputs

No `git` needed. The Dockerfile is **context-free** — its only `COPY` is
`--from` a build stage, never from the build context — so that one file is the
entire build input.

```bash
BRANCH=claude/truenas-quartus-build-runner-6gyltd
RAW="https://raw.githubusercontent.com/gmcnaught/solarus-mister/$BRANCH"

mkdir -p "/mnt/$POOL/ci/quartus-runner/build"
cd "/mnt/$POOL/ci/quartus-runner/build"

curl -fsSL -o quartus-runner.df           "$RAW/fpga/docker/quartus-runner.df"
curl -fsSL -o quartus-runner.compose.yaml "$RAW/.github/runners/truenas/quartus-runner.compose.yaml"

ls -l
head -3 quartus-runner.df
```

Note the working directory is under `/mnt`, not `/root` — the root filesystem is
read-only.

### 4. Build the image

```bash
cd "/mnt/$POOL/ci/quartus-runner/build"
docker build --pull -f quartus-runner.df -t solarus-quartus-runner:17.0 .
```

**Expect 20–40 minutes**, mostly the two pulls (~6 GB donor, ~500 MB runner
base). The final image is ~16 GB. Run it under `tmux`/`screen` if your SSH
session is flaky.

The last two lines of the build are the gate:

```
Step N : RUN quartus_sh --version && quartus_map --version && ...
Step N+1 : RUN quartus_sh --tcl_eval "puts [get_family_list]" | grep -qi "Cyclone V"
```

If the build **succeeds**, the toolchain genuinely loads and knows about Cyclone
V. If it **fails at that step**, a shim library is missing — the loader error
names the `.so`. Add it to the `apt-get install` list in `quartus-runner.df` and
rebuild; the layer cache makes the retry fast. That is the gate working as
designed, not a setback.

Confirm independently:

```bash
docker run --rm --entrypoint quartus_sh solarus-quartus-runner:17.0 --version
docker image ls solarus-quartus-runner
```

### 5. Create the token file

First mint the PAT: **GitHub → Settings → Developer settings → Personal access
tokens → Fine-grained tokens**. Repository access: only
`gmcnaught/solarus-mister`. Repository permissions: **Administration → Read and
write** (that is what "manage self-hosted runners" maps to). Set an expiry.

Then write it without putting it in your shell history:

```bash
ENVF="/mnt/$POOL/ci/quartus-runner/runner.env"
umask 077
printf 'ACCESS_TOKEN=' > "$ENVF"
read -rs TOKEN && printf '%s\n' "$TOKEN" >> "$ENVF" && unset TOKEN
chown root:root "$ENVF"
chmod 600 "$ENVF"

# Verify shape and permissions WITHOUT printing the token:
ls -l "$ENVF"
cut -d= -f1 "$ENVF"        # should print exactly: ACCESS_TOKEN
```

`read -rs` reads silently — paste the token, press Enter, and it never appears
on screen or in `~/.bash_history`.

### 6. Smoke-test before creating the app

Worth the two minutes: prove registration works in the shell, where you can read
errors, rather than through the Apps UI where a failure is a red icon.

```bash
docker run --rm -it \
  --env-file "/mnt/$POOL/ci/quartus-runner/runner.env" \
  -e RUNNER_SCOPE=repo \
  -e REPO_URL=https://github.com/gmcnaught/solarus-mister \
  -e LABELS=quartus,nas \
  -e RUNNER_NAME=truenas-smoketest \
  -e EPHEMERAL=true \
  -e RUNNER_WORKDIR=/work \
  -v "/mnt/$POOL/ci/quartus-runner/work:/work" \
  solarus-quartus-runner:17.0
```

Look for `√ Connected to GitHub` and `Listening for Jobs`, and confirm
`truenas-smoketest` appears under **GitHub → Settings → Actions → Runners**.
Then **Ctrl-C** — being ephemeral, it deregisters on the way out.

The name deliberately differs from the app's `truenas-quartus`, so a leftover
smoke-test registration can never be confused with the real runner.

### 7. Create the app (web UI)

This is the one step that is not SSH. TrueNAS custom apps are created through
the middleware; running `docker compose up` by hand would work but leaves an
unmanaged container — no autostart on boot, invisible to the Apps page, and
wiped by app maintenance. Use the UI so TrueNAS owns its lifecycle.

Print the compose with your pool already substituted, and copy the output:

```bash
sed "s#/mnt/tank/#/mnt/$POOL/#g" \
    "/mnt/$POOL/ci/quartus-runner/build/quartus-runner.compose.yaml"
```

Then: **Apps → Discover Apps → (three-dot menu) → Install via YAML**, name it
`quartus-runner`, paste, and install.

If your pool *is* named `tank`, the `sed` is a no-op and you can paste the file
as-is.

### 8. Verify the app

```bash
docker ps --filter name=quartus-runner --format '{{.Names}}\t{{.Status}}'

CID=$(docker ps -qf name=quartus-runner)
docker logs "$CID" | tail -20                    # expect "Listening for Jobs"
docker exec "$CID" quartus_sh --version          # Quartus is in the runner
docker exec "$CID" sh -c 'touch /work/.probe && echo workspace writable'
```

**GitHub → Settings → Actions → Runners** should show `truenas-quartus` as
**Idle**, with labels `self-hosted, Linux, X64, quartus, nas`.

### 9. First build

**Actions → Build Solarus RBF → Run workflow → runner: `nas`**, leaving
`sdram_phase`, `seed` and `seed_trials` blank so it builds the committed
configuration once.

The job is dispatch-only, so your push-triggered Windows builds are unaffected
until you choose to promote it.

Watch it from the NAS if you like — with `EPHEMERAL`, a fresh container appears
per job:

```bash
watch -n5 'docker ps --filter name=quartus-runner --format "{{.Names}}\t{{.Status}}"'
```

**Grading the result.** Download `solarus-rbf-nas` and compare against a Windows
build of the same commit. Identical bytes are the ideal but are *not* required —
`build_solarus.sh` stamps `build_id.v` with the date, so a same-day build should
match and a cross-day one differs in that stamp alone. What must match is the
substance: same resource utilization and same worst-case setup/hold slack in
`quartus-reports-nas`. Those are deterministic for a given seed and source, so a
discrepancy means the toolchain differs.

### 10. Promote it (after it has proven itself)

In `build-rbf.yml`: add `|| github.event_name == 'push'` to `build-nas`'s `if:`,
drop it from `build-windows`'s, and repoint the fallback chain. Keep the Windows
leg dispatchable — when a build goes strange, running the identical script on a
completely different toolchain install is exactly the A/B this project keeps
reaching for.

### Rebuilding the image later

When `quartus-runner.df` changes:

```bash
cd "/mnt/$POOL/ci/quartus-runner/build"
curl -fsSL -o quartus-runner.df "$RAW/fpga/docker/quartus-runner.df"
docker build -f quartus-runner.df -t solarus-quartus-runner:17.0 .
```

Then **Apps → quartus-runner → Restart**. Drop `--pull` to keep the same donor
layers; add it to re-pull both bases.

### Sizing notes

**RAM.** Quartus fitting a Cyclone V wants ~8 GB and is happier with 16 — RAM
the NAS is not giving to ARC while a build runs, so expect ARC eviction. The
compose file sets `mem_limit: 16g` so a runaway build cannot push the box into
swap and stall storage duties. If the NAS has 32 GB or less, schedule builds for
quiet hours.

**CPU.** Analysis & Synthesis threads somewhat; the Fitter is largely
single-threaded, so single-core clock dominates. Expect noticeably longer than
the Windows box's ~13 min — budget 30–60 min and treat the first build as the
measurement. `seed_sweep.sh` prints per-trial wall time, which is the easiest way
to get that number.

---

## Seed sweeps

`jtutil seed --max-trials 4` runs on **every** JTFRAME core build. Seed retry is
routine there, not an escape hatch — the fitter's starting seed is a lottery, and
a core that misses timing on seed 0 often closes on seed 3 with no RTL change.

This repo already knows that: `build-rbf.yml` has a manual `seed` dispatch input
for "#34 sweeps", and `CLAUDE.md` records a **10-seed sweep run by hand** to
characterise the `pll_hdmi` timing regression. `fpga/scripts/seed_sweep.sh`
automates it.

```bash
fpga/scripts/seed_sweep.sh -n 6              # 6 seeds, stop as soon as timing closes
fpga/scripts/seed_sweep.sh -n 10 --no-stop   # survey the landscape, don't stop early
fpga/scripts/seed_sweep.sh -n 4 -l -0.5      # accept slack better than -0.5 ns
```

Or from CI: dispatch `build-nas` with **`seed_trials: 6`**.

Four behaviours are lifted from `jtutil seed` on purpose:

1. **The first trial uses the committed seed.** jotego's `--zero` starts at seed
   0 so the first attempt is reproducible and a sweep that succeeds immediately
   changes nothing.
2. **Keep the best, not the last.** Their `copy_if_best` only replaces the
   release RBF when a trial beats the incumbent's slack. A sweep that never
   closes timing still leaves you the least-bad bitstream.
3. **Stop as soon as timing is met.** No value in more lottery tickets after a
   win. `--no-stop` overrides when you want the distribution.
4. **An "acceptable" threshold.** Their `JTFRAME_EASY_STA` accepts slack better
   than −0.5 ns on cores known to tolerate it; that is `-l`, opt-in per
   invocation rather than a committed default.

Two details specific to this repo:

- **Slack is the minimum across clock domains.** Quartus prints one
  `Worst-case setup slack is` line per domain; taking the last or first would
  report one domain's margin as the core's. The parser reduces with `min`, the
  same way jotego reduces across every `*.sta.summary`.
- **The `report_timing` lines are deliberately excluded.** `build_solarus.sh`'s
  `rpt_timing.tcl` emits its own `Worst case slack is` lines per section,
  including the DQ read-capture path that `CLAUDE.md` documents as **not a valid
  cross-configuration comparator**. The parser matches only the hyphenated
  `Worst-case <kind> slack is` summary wording. There is a unit check for this:

```bash
fpga/scripts/seed_sweep.sh --self-test
```

`Solarus.qsf` is restored on every exit path, including Ctrl-C — a sweep that
left a random seed committed would silently change what every later build
produces. When a non-committed seed wins, the script prints the one-line `.qsf`
edit to make that result reproducible; committing it is a deliberate act.

---

## Security

**This repository is public**, which normally argues against self-hosted
runners: a fork PR can otherwise execute attacker-controlled code on your
hardware.

Three facts narrow the exposure, and they are worth knowing precisely:

1. **`build-rbf.yml` has no `pull_request` trigger.** It fires on `push` and
   `workflow_dispatch` only, both of which require write access. A fork PR
   cannot reach this workflow. This is the main protection, and it is what to
   re-check before ever adding `pull_request` to this file.
2. **`build-nas` is dispatch-gated.** It runs only when someone with write
   access explicitly selects `nas`.
3. **The runner is ephemeral.** One job per registration, then the container is
   replaced.

The single-image design also removes the worst part of the original: there is
**no docker socket mount**, so a job on this runner is confined to its container
rather than holding root-equivalent access to the NAS.

Still worth doing:

- **Settings → Actions → General → Fork pull request workflows**: set *"Require
  approval for all external contributors"* (the public-repo default is the
  weaker *first-time contributors*).
- Never add `pull_request_target` to a workflow that can land on this runner.
- The workspace dataset is not wiped between jobs — only `git clean -ffdx` runs.
  Treat it as scratch, not a secret store.

If you ever do reintroduce a docker socket mount, note that jotego's devops
installer sets up **rootless** Docker specifically so the socket is not
root-equivalent. That would be the mitigation to copy.

---

## Not adopted yet

Worth stealing later, in rough value order:

- **Nightly build with a skip-if-unchanged guard.** JTFRAME's `compile-all.yaml`
  runs on cron but first checks, via the Actions API, whether the previous run
  succeeded on the same `head_sha` — and skips if so. With free NAS capacity, a
  nightly `seed_trials: 4` build would catch timing regressions the day they
  land rather than at release time. This is the highest-value remaining idea.
- **`rm -rf` between trials.** `xjtcore.sh` deletes each target's build dir
  immediately after compiling ("recover hard disk space"). `seed_sweep.sh`
  currently keeps every trial's output for post-mortem; if disk gets tight,
  prune all but the best.
- **Parallel seed trials.** `jtutil seed --parallel n` runs several seeds at
  once. Ours is sequential, because parallel builds would need separate copies
  of `fpga/` to avoid colliding in `db/` and `output_files/`. Worth it only on a
  NAS with RAM to spare — the fitter's ~8 GB is the binding constraint, not
  cores.
- **`git config --global --add safe.directory`.** `xjtcore.sh` does this because
  the mounted workspace is owned by a different uid than the container user. We
  do not need it today (single container, consistent ownership), but it is the
  first thing to try if git starts refusing the workspace after a uid change.

---

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `docker build` fails at `quartus_sh --version` | A shim library is missing. The loader error names the `.so` — add it to the apt list in `quartus-runner.df`. This is the gate working as intended. |
| App won't deploy: `pull access denied` / `manifest unknown` for `solarus-quartus-runner:17.0` | `pull_policy: never` is missing from the compose. The image is local-only and TrueNAS tries to pull it from Docker Hub otherwise. |
| App deploys but `docker image ls` shows no `solarus-quartus-runner` | Step 4 was skipped or built under a different user's daemon. Rebuild, then Apps → quartus-runner → Restart. |
| YAML editor rejects `env_file` | Some builds validate paths. Fall back to putting `ACCESS_TOKEN` in `environment:` — but note the UI then shows it in plain text on the app's edit form, so rotate the PAT if you later move it back. |
| `zfs: command not found`, or `docker` permission denied | You are logged in as `admin`, not root. `sudo -i` first. |
| Want to `apt install` something | Don't. The read-only root is deliberate; nothing in this process needs a package. |
| `GLIBC_2.28' not found` | Something is running the Actions runner on the Debian 9 donor image. Only `/opt/intelFPGA` may come from that stage. |
| `get_family_list` grep fails at build | The donor image's Cyclone V device data did not come across. Check the `COPY --from=quartus` covered all of `/opt/intelFPGA`. |
| Runner Offline after every job | Expected with `EPHEMERAL: "true"` *if* it returns within seconds. If not, the PAT is wrong or expired — `docker logs`. |
| Fitter OOM-killed | `mem_limit` too low, or the NAS is out of RAM. Raise it, or cap ARC. |
| Sweep leaves a random seed in `Solarus.qsf` | Should be impossible — restore is on an `EXIT`/`INT`/`TERM` trap. If it happens, `git checkout fpga/Solarus.qsf` and file it. |
| Build passes but RBF is stale | Leftover `output_files/`. `actions/checkout` defaults to `clean: true`; confirm it was not disabled. |

---

## Older SCALE (k3s)

On 24.04 (Dragonfish) and earlier, Apps run on k3s and this compose file is not
installable. Options, best first:

1. **Upgrade to 24.10+.** The Docker migration is the supported path and makes
   this file work as written.
2. **Custom App form** (Apps → Discover → Custom App): translate by hand — image,
   env vars, one host-path volume. Much easier than it would have been under the
   socket design, since only a single ordinary bind mount remains.
3. **Skip Apps entirely** — run the container from a Systemd unit on the host.
   Least integrated with the TrueNAS UI, but it is plain `docker run`.
