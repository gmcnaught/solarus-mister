//
//  MiSTer native audio glue for Solarus — see mister_native_audio.h.
//
//  OpenAL-soft loopback device -> mixed 48kHz/stereo/S16 PCM -> DDR3 ring.
//  The loopback device renders EXACTLY the number of sample-frames requested,
//  advancing OpenAL's internal clock by that amount. To keep correct pitch we
//  therefore render at the real output rate on average: each pump renders the
//  number of frames that real time has advanced since the last pump. A one-time
//  startup prime adds a small latency cushion so a slow engine frame does not
//  underrun the FPGA drain.
//

#ifdef MISTER_NATIVE_AUDIO

// Must precede every system header so glibc exposes cpu_set_t /
// pthread_setaffinity_np (used to pin the mix thread to A9 core 1).
#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include "mister_native_audio.h"
#include "native_audio_writer.h"

#if defined(__has_include) && !__has_include(<alext.h>)
#  include <AL/alext.h>  // alcLoopbackOpenDeviceSOFT, alcRenderSamplesSOFT, ALC_*_SOFT
#else
#  include <alext.h>     // alcLoopbackOpenDeviceSOFT, alcRenderSamplesSOFT, ALC_*_SOFT
#endif

#include <cstdint>
#include <cstdio>
#include <cstdlib>   // getenv
#include <ctime>

#include <pthread.h>
#include <unistd.h>  // sysconf, _SC_NPROCESSORS_ONLN
#if defined(__linux__)
#include <sched.h>   // cpu_set_t, CPU_SET (pthread_setaffinity_np)
#endif

namespace {

// Loopback functions resolved at runtime (robust if the link-time library does
// not export them as undefined symbols). NULL => loopback unavailable.
LPALCLOOPBACKOPENDEVICESOFT  p_alcLoopbackOpenDeviceSOFT  = nullptr;
LPALCRENDERSAMPLESSOFT       p_alcRenderSamplesSOFT       = nullptr;
LPALCISRENDERFORMATSUPPORTEDSOFT p_alcIsRenderFormatSupportedSOFT = nullptr;

ALCdevice* loopback_device = nullptr;
bool       active          = false;

// Pacing state.
bool      primed   = false;
uint64_t  last_ns  = 0;       // monotonic clock of last pump
uint64_t  frac_num = 0;       // carried sub-frame remainder (numerator over 1e9)

// 48000 Hz stereo S16.
const int      SR             = NA_SAMPLE_RATE;   // 48000
const int      CH             = NA_CHANNELS;      // 2
const uint64_t PRIME_FRAMES   = 4800;             // ~100 ms latency cushion
const uint64_t MAX_FRAMES     = 4096;             // per-pump render cap (16 KiB)

uint64_t now_ns() {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

// Render `frames` sample-frames from the loopback device into the DDR ring.
void render_and_submit(uint64_t frames) {
  if (frames == 0) return;

  // Bound by the ring's free space so we never block; bound by our scratch
  // buffer so the stack stays small.
  uint64_t freef = (uint64_t)NativeAudioWriter_FreeFrames();
  if (frames > freef)      frames = freef;
  if (frames > MAX_FRAMES) frames = MAX_FRAMES;
  if (frames == 0) return;

  static int16_t scratch[MAX_FRAMES * NA_CHANNELS];
  p_alcRenderSamplesSOFT(loopback_device, scratch, (ALCsizei)frames);
  NativeAudioWriter_Submit(scratch, (size_t)frames);
}

// ----------------------------------------------------------------------------
// Dedicated audio mix thread (SOLARUS_AUDIO_THREAD).
//
// When enabled, the software mix (alcRenderSamplesSOFT, the ~9 ms/displayed-frame
// cost) runs here on A9 core 1 instead of on the render thread, paced by the FPGA
// audio ring drain (the real 48 kHz clock). The render thread no longer calls
// mister_audio_pump(). See docs/superpowers/specs/2026-06-27-audio-core1-thread-
// design.md for the full design + synchronization argument.
//
// audio_mutex guards device/context lifetime vs the mix: it is held around
// render_and_submit (audio thread) and around the teardown in mister_audio_close.
// Engine containers + Music streaming stay on the main thread (Music end runs a
// Lua callback that must not execute off-thread); OpenAL-soft's own internal
// locks make main-thread source ops safe concurrent with the mix.
// ----------------------------------------------------------------------------

pthread_mutex_t audio_mutex   = PTHREAD_MUTEX_INITIALIZER;
pthread_t       audio_tid;
volatile bool   thread_running = false;   // loop keep-going flag (set false to stop)
bool            thread_started = false;   // a thread has been created and not joined

// Maintain ~PRIME_FRAMES (100 ms) of audio queued in the ring: refill to this
// fixed level so the long-run render rate == the FPGA drain rate (correct pitch,
// bounded latency, self-priming).
const uint64_t TARGET_FILL_FRAMES = PRIME_FRAMES;
const long     IDLE_SLEEP_NS      = 1000000L;   // 1 ms when the ring is topped up

void pin_thread_to_cpu(pthread_t th, int cpu) {
#if defined(__linux__)
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  pthread_setaffinity_np(th, sizeof(set), &set);
#else
  (void)th;
  (void)cpu;
#endif
}

void* audio_thread_main(void*) {
  pin_thread_to_cpu(pthread_self(), 1);   // A9 core 1
  while (thread_running) {
    bool did_work = false;

    pthread_mutex_lock(&audio_mutex);
    if (active) {
      uint64_t cap   = (uint64_t)NativeAudioWriter_CapacityFrames();
      uint64_t freef = (uint64_t)NativeAudioWriter_FreeFrames();
      uint64_t used  = (cap >= freef) ? (cap - freef) : 0;
      if (used < TARGET_FILL_FRAMES) {
        render_and_submit(TARGET_FILL_FRAMES - used);  // bounded by MAX_FRAMES & free
        did_work = true;
      }
    }
    pthread_mutex_unlock(&audio_mutex);

    if (!did_work) {
      struct timespec ts;
      ts.tv_sec  = 0;
      ts.tv_nsec = IDLE_SLEEP_NS;
      nanosleep(&ts, nullptr);
    }
  }
  return nullptr;
}

} // namespace

extern "C" ALCdevice* mister_audio_loopback_open(void) {
  if (loopback_device) return loopback_device;

  // Resolve the loopback extension entry points.
  p_alcLoopbackOpenDeviceSOFT =
      (LPALCLOOPBACKOPENDEVICESOFT)alcGetProcAddress(nullptr, "alcLoopbackOpenDeviceSOFT");
  p_alcRenderSamplesSOFT =
      (LPALCRENDERSAMPLESSOFT)alcGetProcAddress(nullptr, "alcRenderSamplesSOFT");
  p_alcIsRenderFormatSupportedSOFT =
      (LPALCISRENDERFORMATSUPPORTEDSOFT)alcGetProcAddress(nullptr, "alcIsRenderFormatSupportedSOFT");

  if (!p_alcLoopbackOpenDeviceSOFT || !p_alcRenderSamplesSOFT) {
    fprintf(stderr,
        "mister_audio: OpenAL loopback extension (ALC_SOFT_loopback) not "
        "available — falling back to default device\n");
    return nullptr;
  }

  loopback_device = p_alcLoopbackOpenDeviceSOFT(nullptr);
  if (!loopback_device) {
    fprintf(stderr, "mister_audio: alcLoopbackOpenDeviceSOFT failed\n");
    return nullptr;
  }

  if (p_alcIsRenderFormatSupportedSOFT &&
      p_alcIsRenderFormatSupportedSOFT(loopback_device, SR,
                                       ALC_STEREO_SOFT, ALC_SHORT_SOFT) == ALC_FALSE) {
    fprintf(stderr, "mister_audio: 48kHz/stereo/S16 not supported by loopback\n");
    alcCloseDevice(loopback_device);
    loopback_device = nullptr;
    return nullptr;
  }

  if (!NativeAudioWriter_Init()) {
    fprintf(stderr, "mister_audio: NativeAudioWriter_Init failed (no /dev/mem?)\n");
    alcCloseDevice(loopback_device);
    loopback_device = nullptr;
    return nullptr;
  }

  active = true;
  primed = false;
  fprintf(stderr, "mister_audio: loopback @ %d Hz stereo S16 -> DDR3 ring\n", SR);
  return loopback_device;
}

extern "C" ALCcontext* mister_audio_loopback_create_context(ALCdevice* device) {
  if (!device) return nullptr;
  const ALCint attrs[] = {
    ALC_FORMAT_CHANNELS_SOFT, ALC_STEREO_SOFT,
    ALC_FORMAT_TYPE_SOFT,     ALC_SHORT_SOFT,
    ALC_FREQUENCY,            SR,
    0
  };
  return alcCreateContext(device, attrs);
}

extern "C" void mister_audio_pump(ALCdevice* device) {
  if (!active || device != loopback_device) return;

  uint64_t t = now_ns();
  if (!primed) {
    // Prime a latency cushion of real audio, then start the clock.
    render_and_submit(PRIME_FRAMES);
    last_ns = t;
    frac_num = 0;
    primed = true;
    return;
  }

  uint64_t dt = (t >= last_ns) ? (t - last_ns) : 0;
  last_ns = t;

  // frames = dt(ns) * SR / 1e9, carrying the remainder so we don't drift.
  uint64_t num = dt * (uint64_t)SR + frac_num;
  uint64_t frames = num / 1000000000ull;
  frac_num = num % 1000000000ull;

  render_and_submit(frames);
}

extern "C" void mister_audio_close(void) {
  // Ensure no mix is in flight before we tear the ring/device handle down.
  mister_audio_thread_stop();

  pthread_mutex_lock(&audio_mutex);
  if (active) {
    NativeAudioWriter_Shutdown();
    active = false;
  }
  // The ALC device/context lifetime is owned by Sound::quit().
  loopback_device = nullptr;
  primed = false;
  pthread_mutex_unlock(&audio_mutex);
}

extern "C" bool mister_audio_active(void) {
  return active;
}

extern "C" bool mister_audio_thread_start(void) {
  if (thread_started) {
    return true;
  }

  // [HW-validated default ON] core-1 audio thread ships enabled; an explicit
  // SOLARUS_AUDIO_THREAD=0 opts back to inline mixing. Unset or non-"0" -> ON.
  const char* env = getenv("SOLARUS_AUDIO_THREAD");
  if (env != nullptr && env[0] == '0') {
    return false;   // opt-out: inline audio (pre-PR#55 behaviour)
  }
  if (!active) {
    // No loopback ring (e.g. fell back to a normal device): nothing to thread.
    return false;
  }

  long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
  if (ncpu < 2) {
    fprintf(stderr,
        "mister_audio: SOLARUS_AUDIO_THREAD=1 but only %ld CPU(s); "
        "staying inline\n", ncpu);
    return false;
  }

  thread_running = true;
  if (pthread_create(&audio_tid, nullptr, audio_thread_main, nullptr) != 0) {
    thread_running = false;
    fprintf(stderr, "mister_audio: pthread_create failed; staying inline\n");
    return false;
  }
  thread_started = true;

  // Keep the render thread on core 0 so the mix (core 1) runs truly in parallel.
  pin_thread_to_cpu(pthread_self(), 0);

  fprintf(stderr,
      "mister_audio: dedicated mix thread on core 1 (ring-driven, ~%llu-frame "
      "cushion)\n", (unsigned long long)TARGET_FILL_FRAMES);
  return true;
}

extern "C" void mister_audio_thread_stop(void) {
  if (!thread_started) {
    return;
  }
  thread_running = false;
  pthread_join(audio_tid, nullptr);
  thread_started = false;
}

extern "C" bool mister_audio_thread_active(void) {
  return thread_started && thread_running;
}

#endif /* MISTER_NATIVE_AUDIO */
