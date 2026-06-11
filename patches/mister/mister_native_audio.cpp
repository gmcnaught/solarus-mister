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

#include "mister_native_audio.h"
#include "native_audio_writer.h"

#include <alext.h>   // alcLoopbackOpenDeviceSOFT, alcRenderSamplesSOFT, ALC_*_SOFT

#include <cstdint>
#include <cstdio>
#include <ctime>

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
  if (active) {
    NativeAudioWriter_Shutdown();
    active = false;
  }
  // The ALC device/context lifetime is owned by Sound::quit().
  loopback_device = nullptr;
  primed = false;
}

extern "C" bool mister_audio_active(void) {
  return active;
}

#endif /* MISTER_NATIVE_AUDIO */
