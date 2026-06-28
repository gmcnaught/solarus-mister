# Audio mix on a dedicated A9 core-1 thread (SOLARUS_AUDIO_THREAD)

Date: 2026-06-27
Status: implemented, env-gated, default OFF (OFF == today's behaviour).

## Problem

HW profiling of a heavy area: the A9 frame is ~52 ms (~17 fps), fully A9-bound.
The single biggest cost inside the engine UPDATE tick is AUDIO:
`[blitter engcpp] sound=~9 ms` per displayed frame. Audio runs on the render
thread and, because of the `MainLoop` catch-up loop, the `System::update()`
->`Sound::update()` path runs ~5.2x per displayed frame. The dominant cost is the
**software mix**: `alcRenderSamplesSOFT()` (OpenAL-soft loopback render) inside
`mister_audio_pump()`. The mix cost scales with wall-time elapsed (a slow frame
=> more samples to render => an even slower frame — a positive-feedback stall).
Core 1 of the dual-core Cortex-A9 is essentially idle.

Goal: take the mix off the render critical path by running it on a dedicated
thread pinned to A9 core 1, paced by the FPGA audio ring drain (the real 48 kHz
clock) instead of wall-time delta. Gate on `SOLARUS_AUDIO_THREAD`, default OFF.

## Background — current audio path (unchanged when OFF)

`patches/mister/`:
- `native_audio_writer.{c,h}` — lock-free SPSC ring writer to DDR
  `0x3A0D0000` (64 KiB = 16384 stereo S16 frames). `Submit()` advances the ARM
  write pointer; the FPGA advances the read pointer as it drains at 48 kHz.
  `FreeFrames()` = ring free space in frames.
- `mister_native_audio.cpp` — OpenAL-soft **loopback** device. `render_and_submit(n)`
  calls `alcRenderSamplesSOFT(loopback_device, scratch, n)` (THE software mix) then
  `NativeAudioWriter_Submit(scratch, n)`. `mister_audio_pump()` renders the number
  of frames real wall-time has advanced since the last call (wall-time pacing),
  with a one-time `PRIME_FRAMES` (4800 ~ 100 ms) cushion.

Render-thread call chain (engine, injected by `scripts/build_engine.sh`):
`MainLoop::step()` -> `System::update()` -> `Sound::update()` which does
`update_device_connection()` + per-source `update_playing()` cleanup +
`mister_audio_pump(device)` (INJECTED) + `Music::update()`.

## Design

### What moves, and what deliberately does NOT

ONLY the **mix** (`render_and_submit` = `alcRenderSamplesSOFT` + `Submit`) moves to
the dedicated thread. Everything else in `Sound::update()` —
`update_device_connection()`, the `update_playing()` finished-source cleanup, and
`Music::update()` — **stays on the main (render) thread**.

This is a deliberate, documented narrowing of the originally-sketched design
("thread does render+submit + Music::update + finished-source cleanup"). Reasons:

1. **`Music::update()` can call Lua.** On music end it runs
   `callback_ref.call("music callback")` (see `src/audio/Music.cpp` `Music::update`),
   which executes a Lua function — i.e. arbitrary game logic — on the calling
   thread. The Lua VM and game state are owned by the main thread and are NOT
   thread-safe. Running `Music::update()` on the audio thread would execute Lua
   off-thread = data race / crash. So music streaming stays on the main thread.

2. **Main-thread music refill is more than fast enough.** Music streams through 8
   buffers of 4096 samples (`Music::nb_buffers`/`buffer_size`) = ~682 ms of audio
   queued. `Music::update()` runs every `System::update()` (>= once per displayed
   frame, ~17-60 Hz). Worst case it tops the music buffers up every ~60 ms against
   a ~682 ms cushion — no underrun. So keeping music refill on the main thread
   costs nothing audible while avoiding the Lua hazard.

3. **No engine-container sharing.** With only the mix on the audio thread, the
   audio thread touches: the OpenAL context (via `alcRenderSamplesSOFT`), the
   `loopback_device` handle, the DDR ring, and `local_wr_ptr` (ring writer state).
   It NEVER touches the engine's `current_sounds`/`all_sounds`/per-`Sound::sources`
   containers or any `Music` C++ member — those remain single-threaded (main).
   This removes the need to lock every `Sound::play()` / `Music::play()` call site
   (dozens of them across entities/hero/Lua) and keeps the main thread off any
   lock on the hot path.

The ~9 ms cost being removed from the render path is the **mix**; the remaining
on-main-thread work (one ogg buffer decode per few frames + trivial source
cleanup) is small and is exactly what the design intends to leave behind.

### Threading model

- `mister_audio_thread_start()` is called from `Sound::initialize()` after
  `Music::initialize()`. It starts the audio thread only when ALL hold:
  - `SOLARUS_AUDIO_THREAD=1` (env; default unset => OFF),
  - the loopback ring is active (`mister_audio_active()`),
  - `sysconf(_SC_NPROCESSORS_ONLN) >= 2` (else inline fallback = today).
  On success it pins the new thread to **core 1** and the main thread to **core 0**
  (`pthread_setaffinity_np`, Linux-only; no-op elsewhere).
- The thread loop is **ring-driven** (the FPGA drain is the real-time clock):
  ```
  while (running):
    lock(audio_mutex)
    if (active):
      used = Capacity - FreeFrames           # frames currently queued in the ring
      if (used < TARGET_FILL):               # TARGET_FILL = PRIME_FRAMES (~100 ms)
        render_and_submit(TARGET_FILL - used)# bounded by MAX_FRAMES & FreeFrames
        did_work = true
    unlock(audio_mutex)
    if (!did_work): nanosleep(1 ms)
  ```
  It maintains a ~100 ms cushion (same latency as the old prime): as the FPGA
  drains the ring, `used` falls below `TARGET_FILL` and the thread tops it back up.
  Because it always refills *to* a fixed level, the long-run render rate equals the
  drain rate = 48 kHz real time => correct pitch, no drift, self-priming on the
  first iterations. It never spins (1 ms idle sleep when topped up) and never
  blocks (render is bounded by `FreeFrames`).
- When threaded, `Sound::update()` skips `mister_audio_pump()`
  (`if (!mister_audio_thread_active()) mister_audio_pump(device);`). When OFF,
  `mister_audio_thread_active()` is false and `mister_audio_pump()` runs inline
  exactly as today.

### Synchronization

A single non-recursive `audio_mutex` guards the **device/context lifetime vs the
mix**. It is held by the audio thread around `render_and_submit` and by
`mister_audio_close()` while it tears the ring down and clears `active` /
`loopback_device`.

What the mutex protects: `alcRenderSamplesSOFT()` dereferences `loopback_device`
and the current OpenAL context. The mix must not be in flight when the device is
closed / context destroyed. The mutex ensures `render_and_submit` and the
close-time teardown are mutually exclusive.

What does NOT need the mutex (and why it is correct without it):
- **Main-thread source ops vs the mix.** `Sound::play()`/`start()`/`set_paused()`
  and `Music::update_playing()` call `alGenSources`/`alSourcePlay`/`alSourcei`/
  `alGetSourcei`/`alSource*QueueBuffers`. OpenAL-soft is internally thread-safe:
  this is exactly its normal model (app issues source ops from its thread while
  the mixer runs on another). With the loopback device the mixer work is our
  `alcRenderSamplesSOFT` call; OpenAL-soft's internal source locks still apply.
  So these are safe concurrent with the audio-thread mix without our mutex.
- **Engine containers.** Single-threaded (main) — see "No engine-container
  sharing" above.
- **The DDR ring.** Single-producer (the audio thread, in threaded mode; the main
  thread in inline mode — never both) writes `local_wr_ptr`; the FPGA writes
  `rd_ptr`. `Submit`/`FreeFrames` are called only from the producer. SPSC, with a
  full `__sync_synchronize()` fence before publishing `wr_ptr` (unchanged).

### Shutdown ordering (no use-after-free)

`mister_audio_thread_stop()` is injected at the TOP of `Sound::quit()`, BEFORE
`Music::quit()` and before the OpenAL context/device teardown. It sets
`running=false` and `pthread_join`s the thread, so no mix can be in flight when
the music decoders, OpenAL context, or device are destroyed. `mister_audio_close()`
also calls `thread_stop()` defensively (idempotent) and clears `active`/device
under the mutex.

### Deadlock / underrun / drift analysis

- **Deadlock:** one mutex, non-recursive, never nested. The audio thread's locked
  region (`render_and_submit`) calls no engine code that re-locks. The main thread
  never blocks on `audio_mutex` on the hot path (it only takes it in
  `mister_audio_close()` at shutdown, after the thread is joined => uncontended).
  `thread_stop()` does not hold the mutex while joining. No lock-order cycle.
- **Underrun:** the thread keeps the ring at ~`TARGET_FILL` (100 ms). It refills
  whenever `used` drops below target, bounded only by `FreeFrames`. Music has a
  ~682 ms buffer cushion refilled by the main thread every <=60 ms. Startup
  self-primes to `TARGET_FILL` before the engine produces sound.
- **Drift/pitch:** average render rate == drain rate == 48 kHz (refill-to-fixed-
  level). The loopback renders exactly the frames requested, advancing OpenAL's
  clock by that amount, so pitch is exact.

## Files changed (engine-side only)

- `patches/mister/native_audio_writer.{c,h}` — add
  `NativeAudioWriter_CapacityFrames()` (ring capacity in frames; same accounting
  as `FreeFrames`).
- `patches/mister/mister_native_audio.{cpp,h}` — add the audio thread
  (`mister_audio_thread_start/stop/active`), core pinning, the ring-driven mix
  loop, `audio_mutex`; `mister_audio_close()` stops the thread first.
- `scripts/build_engine.sh` — injections into `src/audio/Sound.cpp`:
  - `Sound::initialize()`: call `mister_audio_thread_start()` after
    `Music::initialize()`.
  - `Sound::quit()`: call `mister_audio_thread_stop()` before `Music::quit()`.
  - `Sound::update()`: guard the pump with `if (!mister_audio_thread_active())`.
  All idempotent; fresh-clone and already-patched-clone safe.

## Validation

- Host syntax check (cannot build armhf / run HW from here):
  ```
  g++ -std=c++17 -fsyntax-only -DMISTER_NATIVE_AUDIO \
    -I patches/mister -I/opt/homebrew/opt/openal-soft/include/AL \
    patches/mister/mister_native_audio.cpp
  cc -std=c11 -fsyntax-only -I patches/mister \
    patches/mister/native_audio_writer.c
  ```
- OFF path is behaviourally identical: `mister_audio_thread_active()` is false, so
  `Sound::update()` calls `mister_audio_pump()` inline and no thread is created.

## HW A/B recipe

Build + deploy the engine (refresh `deploy/libs/libsolarus.so.1.6.5` from
`build/armhf/` first — see memory `fpga-deploy-refresh-from-build-armhf`). Launch
via the daemon/OSD (NOT an ssh-launched run — it dies on disconnect; memory
`solarus-ssh-launch-dies-on-disconnect`). Read-only ssh (devmem/screenshots/log)
is fine.

A (baseline): launch with `SOLARUS_AUDIO_THREAD` unset (or `=0`).
B (threaded): set `SOLARUS_AUDIO_THREAD=1` in `$GAMEDIR/diag.env` (sourced with
`set -a`).

For each, drive into the heavy area (input-inject recipe in memory
`solarus-joypad-inject-hw`) and compare:
- **fps / frame time** — expect B materially faster in the heavy area (the ~9 ms
  mix off the render path). Use `SOLARUS_BLITTER_DIAG=1` per-60-frame counters
  and/or `[MiSTer loop] fps=` if that instrumentation is present in the build.
- **CPU distribution** — `top -H` (or `/proc` per-thread): in B a second thread
  should show load pinned to core 1; the main thread on core 0.
- **Audio quality** — listen under heavy load: no crackle, no dropout, no pitch
  change between A and B. Watch the ring not starving: `busybox devmem
  0x3A000030` (wr) and `0x3A000038` (rd) should both keep advancing/wrapping with
  a steady gap (~`TARGET_FILL`).
- **Stability** — quit the quest / swap core: clean shutdown (thread joined before
  teardown), no hang.

Acceptance: B audio is clean (== A) AND heavy-area fps is up AND no shutdown hang.
