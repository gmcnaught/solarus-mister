//
//  MiSTer native audio glue for Solarus — DDR3 ring sink via OpenAL loopback
//
//  Replaces the ALSA/OpenAL playback device (which fails on MiSTer:
//  "snd_pcm_hw_params ... Invalid argument") with OpenAL-soft's loopback
//  device. Solarus mixes all sound + music into the loopback device; each
//  Sound::update() we pull the mixed 48kHz/stereo/S16 PCM with
//  alcRenderSamplesSOFT and push it into the FPGA DDR3 audio ring
//  (0x3A000030 wr-ptr / 0x3A000038 rd-ptr, ring @ 0x3A0D0000). No ALSA.
//
//  Mirrors the OpenBOR MiSTer audio path (native_audio_writer.{c,h}).
//
//  All entry points are no-ops unless built with -DMISTER_NATIVE_AUDIO.
//

#ifndef MISTER_NATIVE_AUDIO_H
#define MISTER_NATIVE_AUDIO_H

#ifdef MISTER_NATIVE_AUDIO

#if defined(__has_include) && !__has_include(<al.h>)
#  include <AL/al.h>
#  include <AL/alc.h>
#else
#  include <al.h>
#  include <alc.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

/// Open an OpenAL-soft loopback device (48kHz / stereo / S16) and initialize
/// the DDR3 audio writer. Returns nullptr if the loopback extension or the DDR
/// mapping is unavailable (caller should then fall back to a normal device).
ALCdevice* mister_audio_loopback_open(void);

/// Create an OpenAL context on a loopback device opened above, with the
/// loopback render attributes (channels=stereo, type=int16, freq=48000).
/// Returns nullptr on failure.
ALCcontext* mister_audio_loopback_create_context(ALCdevice* device);

/// Render the audio that has accumulated since the last call (paced to the
/// real 48kHz output clock) and submit it to the DDR3 ring. Call once per
/// Sound::update(). Safe to call when inactive (no-op).
void mister_audio_pump(ALCdevice* device);

/// Tear down: stop submitting and release the DDR3 mapping. Does not close the
/// ALC device/context (Sound::quit() owns those).
void mister_audio_close(void);

/// True once a loopback device + DDR writer are active.
bool mister_audio_active(void);

/// Start the dedicated audio mix thread (SOLARUS_AUDIO_THREAD opt-in).
///
/// Call once from Sound::initialize() after the loopback device is open and
/// Music is initialized. Starts the thread (pinned to A9 core 1, with the main
/// thread pinned to core 0) ONLY when ALL of:
///   - env SOLARUS_AUDIO_THREAD == "1"   (default unset => OFF == today),
///   - the loopback ring is active (mister_audio_active()),
///   - sysconf(_SC_NPROCESSORS_ONLN) >= 2 (else inline fallback = today).
/// Returns true if the thread was started; false means inline (unthreaded) audio.
bool mister_audio_thread_start(void);

/// Stop and join the dedicated audio mix thread. Idempotent. MUST be called
/// before tearing down the OpenAL context/device or the music decoders (so no
/// mix is in flight). Injected at the top of Sound::quit().
void mister_audio_thread_stop(void);

/// True while the dedicated audio mix thread is running and owns the mix. When
/// true, Sound::update() must NOT call mister_audio_pump() (the thread does it);
/// when false, behaviour is exactly the inline path.
bool mister_audio_thread_active(void);

#ifdef __cplusplus
}
#endif

#endif /* MISTER_NATIVE_AUDIO */

#endif /* MISTER_NATIVE_AUDIO_H */
