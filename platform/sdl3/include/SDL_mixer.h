/**
 * PeonPad SDL_mixer 2 compatibility surface, implemented directly on top of
 * SDL_mixer 3's MIX_Mixer/MIX_Audio/MIX_Track object model.
 *
 * This header exists so that the staged upstream Stratagus sources (which
 * still call the legacy `Mix_*` API from src/sound/sound_server.cpp and
 * src/include/sound.h / sound_server.h) can be compiled and linked in the
 * direct SDL3 build lane (PEONPAD_ENABLE_SDL3) without any sdl2-compat shim,
 * without stub/no-op implementations, and without unsafe reinterpretation of
 * unrelated object layouts.
 *
 * Build wiring (owned by the parent target, NOT this file):
 *   - Add `platform/sdl3/include` to the include directories of any target
 *     that must resolve `#include <SDL_mixer.h>` to this header, and make
 *     sure that directory is searched *before* any SDL2 SDL_mixer include
 *     path. This header is only appropriate for the direct SDL3 lane.
 *   - Compile platform/sdl3/PeonPadSDL3MixerAdapter.cpp into that same
 *     target and link it against SDL3::SDL3 and SDL3_mixer::SDL3_mixer.
 *
 * Design notes (see the sprint progress docs and the handoff report for the
 * full rationale):
 *   - Mix_Chunk keeps the exact four public fields Stratagus reads/writes
 *     (allocated, abuf, alen, volume) so the DYNAMIC_LOAD deferred-load
 *     trick in sound_server.cpp (which stashes a filename in `abuf` and
 *     later std::swap()s a placeholder chunk with a fully loaded one)
 *     continues to compile and behave correctly. An extra, PeonPad-owned
 *     field carries the underlying MIX_Audio* and is populated only by
 *     this adapter's own loaders.
 *   - Because Stratagus's DYNAMIC_LOAD path allocates its placeholder chunk
 *     with SDL_calloc() and frees it with SDL_free() directly (bypassing
 *     Mix_FreeChunk for that specific case) *and* std::swap()s it with a
 *     chunk this adapter allocated, this adapter allocates and frees every
 *     Mix_Chunk with SDL_calloc()/SDL_free() as well, so a swapped chunk is
 *     always released with an allocator that matches how it was obtained,
 *     regardless of which side of the swap it ends up on.
 *   - Mix_Music stays fully opaque (only forward-declared here); nothing in
 *     the inventoried engine sources dereferences its fields.
 *   - Loop counts (the `loops` parameter of Mix_PlayChannel/Mix_PlayMusic)
 *     are passed straight through to MIX_PROP_PLAY_LOOPS_NUMBER: SDL_mixer 3
 *     documents -1 as "loop forever", 0 as "do not loop", and N as "loop N
 *     additional times", which is bit-for-bit identical to SDL_mixer 2
 *     semantics, so no conversion is performed.
 *   - Mix_ChannelFinished / Mix_HookMusicFinished are implemented with
 *     MIX_SetTrackStoppedCallback on reusable per-channel and per-music
 *     MIX_Track objects. MIX_TrackStoppedCallback fires for both natural
 *     completion *and* an explicit halt (MIX_StopTrack), matching legacy
 *     Mix_ChannelFinished/Mix_HookMusicFinished behavior on
 *     Mix_HaltChannel/Mix_HaltMusic. It never fires for a destroyed track,
 *     which keeps teardown deterministic.
 */

#ifndef PEONPAD_SDL3_COMPAT_SDL_MIXER_H
#define PEONPAD_SDL3_COMPAT_SDL_MIXER_H

#include <SDL3/SDL.h>
#include <SDL3_mixer/SDL_mixer.h>

#ifdef __cplusplus
extern "C" {
#endif

/* -------------------------------------------------------------------------
   Legacy defaults (values chosen by the caller, not by SDL_mixer 3 itself).
   ------------------------------------------------------------------------- */

#define MIX_DEFAULT_FREQUENCY 44100
#define MIX_DEFAULT_FORMAT    SDL_AUDIO_S16
#define MIX_DEFAULT_CHANNELS  2

/** Legacy 0-128 volume scale (SDL_mixer 2's MIX_MAX_VOLUME). */
#define MIX_MAX_VOLUME 128

/**
 * Legacy "post-mix" pseudo channel. This compatibility layer does not
 * implement post-mix effects/panning, so any function that would accept
 * this constant reports an explicit error via SDL_SetError() rather than
 * silently doing nothing.
 */
#define MIX_CHANNEL_POST (-2)

/* -------------------------------------------------------------------------
   Types
   ------------------------------------------------------------------------- */

/**
 * Legacy sample chunk. `allocated`, `abuf`, `alen`, and `volume` are the
 * exact fields Stratagus reads/writes (including the DYNAMIC_LOAD deferred
 * load trick in sound_server.cpp). `PeonPadMixAudio` is a PeonPad-specific
 * addition that carries the SDL_mixer 3 MIX_Audio backing this chunk; it is
 * only ever populated by Mix_LoadWAV()/Mix_LoadWAV_RW() in this adapter.
 */
typedef struct Mix_Chunk
{
	int allocated;
	Uint8 *abuf;
	Uint32 alen;
	Uint8 volume;
	MIX_Audio *PeonPadMixAudio;
} Mix_Chunk;

/** Legacy music handle. Intentionally opaque; nothing dereferences it. */
typedef struct Mix_Music Mix_Music;

/* -------------------------------------------------------------------------
   Errors
   ------------------------------------------------------------------------- */

#define Mix_GetError() SDL_GetError()
#define Mix_SetError SDL_SetError

/* -------------------------------------------------------------------------
   Library init/quit
   ------------------------------------------------------------------------- */

/**
 * Legacy Mix_Init() no longer selects individual decoders (SDL_mixer 3's
 * MIX_Init() brings up every decoder it was built with); `flags` is
 * accepted for source compatibility and echoed back on success.
 */
int Mix_Init(int flags);
void Mix_Quit(void);

/* -------------------------------------------------------------------------
   Device
   ------------------------------------------------------------------------- */

/**
 * Opens the default playback device via MIX_CreateMixerDevice(). `chunksize`
 * is accepted for source compatibility but is not forwarded anywhere:
 * SDL_mixer 3 manages its own internal buffering and does not expose a
 * matching knob.
 */
int Mix_OpenAudio(int frequency, Uint16 format, int channels, int chunksize);
void Mix_CloseAudio(void);

/** Returns the number of channels actually allocated. */
int Mix_AllocateChannels(int numchans);

/* -------------------------------------------------------------------------
   Decoders
   ------------------------------------------------------------------------- */

/**
 * SDL_mixer 3 exposes a single, unified decoder list (MIX_GetAudioDecoder)
 * instead of separate chunk/music lists. Both legacy accessors below report
 * that same unified list; this is a deliberate compatibility decision, not
 * an oversight (see the handoff report for details).
 */
int Mix_GetNumChunkDecoders(void);
const char *Mix_GetChunkDecoder(int index);
bool Mix_HasChunkDecoder(const char *name);
int Mix_GetNumMusicDecoders(void);
const char *Mix_GetMusicDecoder(int index);
bool Mix_HasMusicDecoder(const char *name);

/* -------------------------------------------------------------------------
   Chunks (sound effects)
   ------------------------------------------------------------------------- */

Mix_Chunk *Mix_LoadWAV(const char *file);
Mix_Chunk *Mix_LoadWAV_RW(SDL_IOStream *src, int freesrc);
void Mix_FreeChunk(Mix_Chunk *chunk);

/* -------------------------------------------------------------------------
   Music (streaming)
   ------------------------------------------------------------------------- */

Mix_Music *Mix_LoadMUS(const char *file);
Mix_Music *Mix_LoadMUS_RW(SDL_IOStream *src, int freesrc);
void Mix_FreeMusic(Mix_Music *music);

/* -------------------------------------------------------------------------
   Channel (sound effect) playback
   ------------------------------------------------------------------------- */

int Mix_PlayChannel(int channel, Mix_Chunk *chunk, int loops);
int Mix_HaltChannel(int channel);
int Mix_Pause(int channel);
int Mix_Resume(int channel);
int Mix_Paused(int channel);
int Mix_Playing(int channel);
int Mix_Volume(int channel, int volume);
int Mix_SetPanning(int channel, Uint8 left, Uint8 right);
Mix_Chunk *Mix_GetChunk(int channel);
void Mix_ChannelFinished(void (SDLCALL *channel_finished)(int channel));

/* -------------------------------------------------------------------------
   Music playback
   ------------------------------------------------------------------------- */

int Mix_PlayMusic(Mix_Music *music, int loops);
int Mix_HaltMusic(void);
int Mix_PauseMusic(void);
int Mix_ResumeMusic(void);
int Mix_PausedMusic(void);
int Mix_PlayingMusic(void);
int Mix_VolumeMusic(int volume);
void Mix_HookMusicFinished(void (SDLCALL *music_finished)(void));

/* -------------------------------------------------------------------------
   Timidity configuration
   ------------------------------------------------------------------------- */

/**
 * This pinned SDL_mixer 3 build has MIDI decoding disabled entirely
 * (SDLMIXER_MIDI=OFF in cmake/PeonPadSDL3.cmake), so there is no built-in
 * Timidity synth for this to configure. Rather than silently no-op, this
 * still performs the one real, observable side effect the legacy API
 * offered: it publishes the path through the TIMIDITY_CFG environment
 * variable, which is what a Timidity-capable decoder (built-in or external)
 * would read. See the handoff report for the open follow-up this implies.
 */
bool Mix_SetTimidityCfg(const char *path);

#ifdef __cplusplus
}
#endif

#endif /* PEONPAD_SDL3_COMPAT_SDL_MIXER_H */
