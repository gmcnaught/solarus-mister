# Quartus build runner on TrueNAS SCALE

Runs the Solarus RBF build on the NAS as a self-hosted GitHub Actions runner,
so `fpga/build_solarus.sh` no longer depends on the self-hosted Windows box or
on GitHub-hosted minutes.

Artifacts in this repo:

| Path | What it is |
| --- | --- |
| `.github/runners/truenas/quartus-runner.compose.yaml` | The Custom App definition — paste into TrueNAS |
| `.github/runners/truenas/runner.env.example` | Template for the PAT file (the real one never enters git) |
| `.github/workflows/build-rbf.yml` → `build-nas` job | The CI side, dispatch-only for now |

Applies to **TrueNAS SCALE 24.10 (Electric Eel) and newer**, where Apps run on
native Docker + docker-compose. On 24.04 and earlier, Apps run on k3s and a
compose file is not installable — see [Older SCALE](#older-scale-k3s) at the end.

---

## The one design decision worth understanding

**The runner container does not contain Quartus, and that is not an oversight.**

`raetro/quartus:17.0` — the image CI already uses, and the toolchain we want
parity with — is built on **Debian 9, glibc 2.24**. A current GitHub Actions
runner cannot run there: `node20`, which every modern action
(`actions/checkout@v4`, `actions/upload-artifact@v4`) executes under, requires
**glibc ≥ 2.28**. Installing the runner into that image gets you

```
/__e/node20/bin/node: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.28' not found
```

on the very first step. The `ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION=true`
workaround forced node16, but node16 has since been removed from the runner
package outright, so it is a dead end rather than a fallback.

So the split is:

```
TrueNAS host docker daemon
├── quartus-runner        (Ubuntu 24.04 + Actions runner)   <- the Custom App
│      │  mounts /var/run/docker.sock
│      └──> docker run raetro/quartus:17.0 ...              <- SIBLING container
└──         (Debian 9 + Quartus 17.0, one per job, --rm)
```

The runner shells out to the host daemon to start Quartus as a *sibling*
container. The command it issues is **byte-identical** to the one the existing
`build-linux` job already runs on `ubuntu-latest`:

```bash
docker run --rm -v "$PWD:/build" raetro/quartus:17.0 \
  bash -c "cd /build/fpga && bash build_solarus.sh ../_Other"
```

which is the point — the NAS leg is a true toolchain match for the hosted Linux
leg, not a re-derivation of it.

### The consequence that bites: path aliasing

`$PWD` in that command is resolved by the **host** daemon, not by the runner
container. If the runner's workspace lives at `/actions-runner/_work` inside its
container and nowhere on the host, the host cheerfully creates an empty
directory, mounts *that* at `/build`, and the build fails with
`Solarus.qpf: No such file or directory` — with no hint that a mount was the
cause.

The fix is the whole reason `RUNNER_WORKDIR` and the second bind mount in the
compose file are the same string:

```yaml
    environment:
      RUNNER_WORKDIR: /mnt/tank/ci/quartus-runner/work
    volumes:
      - /mnt/tank/ci/quartus-runner/work:/mnt/tank/ci/quartus-runner/work
```

Change one, change both.

### Two more consequences of the sibling model

- **Resource limits on the runner do not constrain Quartus.** The fitter runs in
  a container the host daemon owns; it is not a child of the runner and inherits
  none of its cgroup limits. A `mem_limit` on the runner would throttle the
  bookkeeping and leave the memory-hungry process free — which is why the
  compose file deliberately sets none. To cap Quartus, add `--memory`/`--cpus`
  to the `docker run` in the `build-nas` job.
- **Build output comes back owned by root.** The Quartus container writes
  `fpga/db/`, `fpga/output_files/` and `_Other/` into the shared workspace as
  root. The next run's `actions/checkout` does `git clean -ffdx` and must be able
  to remove them, which is why the runner container runs as `user: root`. Drop
  that and you need an explicit `chown` step instead.

---

## Setup

### 1. Dataset

Create a dedicated dataset — not a directory on an existing share, so the
Quartus scratch I/O can be tuned and snapshotted (or not) independently.

```bash
# Replace `tank` with your pool name throughout.
zfs create -o atime=off -o compression=lz4 tank/ci
zfs create -o atime=off -o compression=lz4 tank/ci/quartus-runner
mkdir -p /mnt/tank/ci/quartus-runner/work
```

- `atime=off` — Quartus touches a very large number of small files in `db/`;
  atime updates are pure write amplification here.
- `compression=lz4` — Quartus reports and netlist databases compress well.
- Consider `sync=disabled` on this dataset. It is *pure scratch* — every input
  is re-cloned from git and every output is uploaded as a CI artifact — so the
  usual objection to `sync=disabled` (losing acknowledged writes on power loss)
  costs you a re-run and nothing else.
- **Exclude it from snapshot/replication tasks.** A periodic snapshot task that
  catches `db/` will accumulate many GB of churn per build for no recoverable
  value.

**Sizing.** `raetro/quartus:17.0` is ~6 GB compressed and ~12 GB extracted in the
host's Docker storage (that lives under `ix-apps`, not this dataset). This
dataset holds the checkout plus Quartus's `db/`, `incremental_db/` and
`output_files/`. Provision **≥ 60 GB** free across the two and you have room for
a phase/seed sweep without pruning between runs.

**RAM.** Quartus 17.0 fitting a Cyclone V wants ~8 GB and is happier with 16 GB.
That is 16 GB the NAS is not giving to ARC while a build runs — on a box that is
also serving storage, expect ARC eviction during builds. If the NAS has 32 GB or
less, plan builds for quiet hours.

**CPU.** Analysis & Synthesis parallelizes somewhat; the Fitter is largely
single-threaded. Single-core clock dominates, so a NAS Xeon/Atom will run
noticeably longer than the Windows box's ~13 min. Budget 30–60 min and treat the
first real build as the measurement.

### 2. Token

```bash
cp runner.env.example /mnt/tank/ci/quartus-runner/runner.env   # then edit
chown root:root /mnt/tank/ci/quartus-runner/runner.env
chmod 600       /mnt/tank/ci/quartus-runner/runner.env
```

Fine-grained PAT scoped to `gmcnaught/solarus-mister` with **Administration:
Read and write** is preferred over a classic `repo` PAT — same capability for
runner registration, far less blast radius. The container exchanges it for a
short-lived registration token on every start, which is what lets an ephemeral
runner come back unattended after each job.

It goes in `env_file:` rather than `environment:` because TrueNAS renders
`environment:` values as plain text on the app's edit form.

### 3. Install the app

1. **Apps → Discover Apps → (three-dot menu) → Install via YAML**
   (on some 24.10 builds this is **Custom App → Install via YAML**).
2. Name it `quartus-runner`.
3. Paste `.github/runners/truenas/quartus-runner.compose.yaml`, with `tank`
   replaced by your pool name in all three places.
4. Deploy. First start pulls ~500 MB for the runner image; the 6 GB Quartus pull
   happens on the first *build*, not now.

### 4. Verify, in order

Each step isolates one failure mode — do not skip ahead.

```bash
# a. Runner registered and idle?
#    Also: GitHub -> Settings -> Actions -> Runners should show `truenas-quartus`
#    as Idle with labels self-hosted, Linux, X64, quartus, nas.
docker logs $(docker ps -qf name=quartus-runner) | tail -20

# b. Can it reach the host daemon? (the DooD mount)
docker exec $(docker ps -qf name=quartus-runner) docker ps

# c. THE PATH-ALIASING CHECK — the one that catches the silent failure.
#    Both must print the same path, and it must exist on the host.
docker exec $(docker ps -qf name=quartus-runner) sh -c 'echo $RUNNER_WORKDIR; ls -d $RUNNER_WORKDIR'
ls -d /mnt/tank/ci/quartus-runner/work

# d. Quartus actually runs (pulls the 6 GB image; do this before a real build)
docker run --rm raetro/quartus:17.0 quartus_sh --version
```

### 5. First build

**Actions → Build Solarus RBF → Run workflow → runner: `nas`**, leaving
`sdram_phase` and `seed` blank so it builds the committed configuration.

The job is dispatch-only, so nothing about your existing push-triggered Windows
builds changes until you decide to flip it.

**Grading the result.** Download `solarus-rbf-nas` and compare against a Windows
build of the same commit. Identical bytes are the ideal but are *not* required —
Quartus embeds a build date via `build_id.v`, so a same-day build should match
and a cross-day one will differ in that stamp alone. What must match is the
substance: same resource utilization and same worst-case setup/hold slack in
`quartus-reports-nas`. Those numbers are deterministic for a given
seed + source, so a discrepancy means the toolchain differs, not the weather.

### 6. Promote it (optional, after it has proven itself)

To make the NAS the default for pushes, in `build-rbf.yml`:

- add `|| github.event_name == 'push'` to `build-nas`'s `if:`,
- drop `github.event_name == 'push'` from `build-windows`'s `if:`,
- point the `needs:`/fallback chain at `build-nas` instead of `build-windows`.

Keeping the Windows leg dispatchable is worth it — when a build goes strange,
being able to run the identical script on a completely different toolchain
install is exactly the A/B this project keeps reaching for.

---

## Security

**This repository is public**, and that changes the calculus for a self-hosted
runner. GitHub's own guidance is not to use self-hosted runners on public repos,
because a pull request from a fork can otherwise execute attacker-controlled
code on your hardware — and here that hardware is your NAS, with a mounted
docker socket, which is root-equivalent to the host.

Three facts make the actual exposure narrow, and they are worth knowing
precisely rather than vaguely:

1. **`build-rbf.yml` has no `pull_request` trigger.** It fires on `push` and
   `workflow_dispatch` only. Both require write access to the repo — a fork PR
   cannot reach this workflow at all. This is the main thing protecting you, and
   it is the thing to re-check before ever adding `pull_request` to this file.
2. **`build-nas` is dispatch-gated.** It runs only when someone with write access
   explicitly selects `nas`.
3. **The runner is ephemeral.** One job per registration, then the container is
   replaced — so nothing persists between jobs in the runner itself.

Worth doing anyway:

- **Settings → Actions → General → Fork pull request workflows**: set
  *"Require approval for all external contributors"* (the public-repo default is
  the weaker *first-time contributors*).
- Do not add `pull_request_target` to any workflow that can land on this runner.
- Note that the workspace dataset is *not* wiped between jobs (only
  `git clean -ffdx` runs), so it is a scratch dataset, not a secret store.
- The docker socket mount means a job on this runner can do anything to the NAS.
  That is inherent to the sibling-container design, not incidental to it. The
  alternative — installing Quartus directly into a modern-glibc runner image via
  `COPY --from=raetro/quartus:17.0 /opt/intelFPGA /opt/intelFPGA` plus the
  `libpng12`/i386 shims Quartus 17.0 needs — removes the socket but puts a 2017
  toolchain on a 2024 glibc, which is a new unvalidated combination and loses the
  byte-for-byte parity with the hosted Linux leg. Only worth it if the socket is
  genuinely unacceptable.

---

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `Solarus.qpf: No such file or directory` from Quartus | Path aliasing. `RUNNER_WORKDIR` ≠ the host bind-mount path. Run verification step (c). |
| `GLIBC_2.28' not found` | Something is trying to run the Actions runner *inside* `raetro/quartus:17.0`. It cannot work; see the design note above. |
| `git clean -ffdx: Permission denied` on the 2nd build | Runner is not running as root; root-owned Quartus output from build 1 can't be removed. |
| Runner shows Offline after every job | Expected with `EPHEMERAL: "true"` *if* it comes back within seconds. If it does not, the PAT is wrong or expired — check `docker logs`. |
| `Cannot connect to the Docker daemon` | `/var/run/docker.sock` not mounted, or TrueNAS's daemon socket is elsewhere on your version. |
| Fitter OOM-killed | The NAS ran out of RAM (ARC + Quartus). Add `--memory=12g` to the `docker run` and/or cap ARC. |
| Build passes but RBF is stale | `output_files/` left over from a previous run. `actions/checkout` with default `clean: true` should prevent it — confirm it wasn't disabled. |

---

## Older SCALE (k3s)

On 24.04 (Dragonfish) and earlier, Apps run on k3s and this compose file is not
installable. Options, best first:

1. **Upgrade to 24.10+.** The Docker migration is the supported path and makes
   this file work as written.
2. **Custom App form** (Apps → Discover → Custom App): translate the compose
   file by hand — image, env vars, and two *host path* volumes
   (`/var/run/docker.sock` and the workspace at its identical path). Workable,
   but hostPath mounts plus a docker socket under k3s are fiddly and the
   path-aliasing requirement is easy to lose in the translation.
3. **Skip Apps entirely** — run the container from a Systemd unit or a startup
   script on the host. Least integrated with the TrueNAS UI, but it is plain
   `docker run` and the semantics above hold exactly.
