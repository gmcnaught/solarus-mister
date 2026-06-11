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

#include <al.h>
#include <alc.h>

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

#ifdef __cplusplus
}
#endif

#endif /* MISTER_NATIVE_AUDIO */

#endif /* MISTER_NATIVE_AUDIO_H */
