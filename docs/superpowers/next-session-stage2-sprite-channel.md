# Next session: Retained-scene Stage 2 — Sprite channel

Copy the block below as the opening prompt for a fresh session.

---

Stage 2 of the retained-scene compositor for the Solarus MiSTer port. Start from `master`
(Stage 1 merged as PR #125, commit `1a4a355`).

**Read first:** `docs/superpowers/specs/2026-07-17-retained-scene-compositor-design.md` — §2
(SpriteChannel), §4 (host↔fabric contract), §6 (fallback boundary), §7 (staging), §8 (open items).

**Goal (design §7, Stage 2):** replace the `alias_target` blit replay with an ordered
**SpriteChannel** + `sprite_unit` — a compact per-frame list of *every* camera-surface blit
(entities, custom `on_draw`, Lua world draws), Z-correct by emission order, with a bounded cap
and a logged drop count. Gate flag `SOLARUS_SPRITECH` (see the default-OFF rule below).

**Before assuming any RTL is needed, check whether the fabric already expresses this.** Stage 1
was specified with a new `overlay_unit` and turned out to need **zero RTL** — the exact command
was already shipping in the bgplane path, and because the DDR3 command ring executes strictly in
order, "composited last" was just "emitted last". Do the same check here: the ring already carries
ordered per-blit commands, so the real Stage 2 question is whether a *sprite list* buys anything
over the ordered stream that already exists, and if so, what. Answer that before planning.

**Two of §8's open items are Stage 2's to resolve, and both want a census, not a guess:**
- Sprite cap value. A measured data point from Stage 1 HW: a busy MoSDX gameplay scene ran
  `alias_blits=27039` per 60-frame window ≈ **450 camera-surface blits/frame**. Census the
  worst-case official quest before picking a cap.
- Scratch SDRAM arena size for dynamic-source world blits (§6 keeps exactly one dynamic-upload
  path, bounded and logged).

## Ground rules learned the hard way (all cost real time in the Stage 1 session)

- **Build runs INSIDE the container:** `bash scripts/docker_run.sh bash scripts/build_engine.sh`.
  Running `build_engine.sh` on the host writes a host-path `CMakeCache.txt` that then blocks the
  container build, and vice versa. A background task's "exit code 0" reflects the last command in
  your wrapper (often a `tail`), **not** the build — always grep `BUILD_EXIT` and check artifact
  timestamps.
- **Deploy ships from `deploy/libs/`**, not `deploy/` root. `deploy.py` can print `Done` and exit 0
  having moved only `solarus-run` while the library stayed a day old. **Always sha1-verify on device.**
- **Launching:** leave `/media/fat/config/Solarus.s0` EMPTY (else `quest_manager` auto-launches and
  you get two engines on the fabric — that made the host mostly unresponsive), load the core, wait
  for `CORENAME=Solarus`, then launch with a private pick file:
  `S0_FILE=/tmp/x SOLARUS_ALLOW_DIAG_ENV=1 setsid sh solarus_run.sh > /media/fat/logs/Solarus/x.log 2>&1 </dev/null &`
  Log to `/media/fat/logs/Solarus/`, never `/tmp` (a restart wipes it). Note the lua-console path
  `exec`s with its own redirect to `Solarus.diag.log`, so engine output lands there, not in your log.
- **Never blind-inject joypad input.** Hammering confirm walked a menu into quit, then navigated the
  MiSTer OSD into loading an unrelated core.
- **Host tests gate CI only via `patches/mister/build_host_tests.sh`.** `tests/run_tests.sh` is
  referenced by no workflow — a test added there gates nothing.
- **New gates ship default OFF** until HW-validated, then flip in a separate commit
  (`mister_flag_default_on`, which is reserved for already-validated defaults). Note the trap:
  a plain `getenv(...) != nullptr` flag is *presence-based*, so `FLAG=0` still ENABLES it.
- **Never self-declare visual correctness.** Counters prove a path executes, not that pixels are
  right. Stage 1's overlay reported a perfectly healthy `draws/composites/dropped=0` while
  visibly under-dimming menus. The operator's eyes or a bit-exact test are the only verdicts.
- `patches/mister/*` whole-file copies are edited DIRECTLY (not in the patch series) but must stay
  byte-identical to their `work/solarus/` counterparts. Engine files under `work/solarus/` ARE in
  the series → commit there, then `scripts/export_patches.sh`.

## Open items inherited (not Stage 2's job, but don't regress them)

- **#124** — overlay under-dims translucent menus; the pre-overlay path over-dims. Shipped
  deliberately as least-bad. Decisive experiment is one rebuild: bypass the un-premultiply behind
  a temp env gate and A/B the same menu; if unchanged, try round-to-nearest alpha packing
  (`(a+8)>>4` clamped) instead of the current truncating `(a>>4)`.
- **#122 / #123** — scroll-transition artifacts. The design predicted Stage 1 would structurally
  delete both; that was never verified. If Stage 2 touches the transition path, check them.

Use the brainstorming skill first, then writing-plans, then subagent-driven-development — the
Stage 1 arc (`docs/superpowers/plans/2026-07-18-retained-scene-stage1-overlay-channel.md` and
`docs/superpowers/2026-07-18-stage1-overlay-hw-validation.md`) is the worked precedent for shape,
task granularity, and what the HW gate should demand.
