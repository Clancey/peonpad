/**
 * Implementation of the platform/sdl3/include/SDL_mixer.h legacy
 * compatibility surface, built directly on SDL_mixer 3's
 * MIX_Mixer/MIX_Audio/MIX_Track object model.
 *
 * See platform/sdl3/include/SDL_mixer.h for the documented design
 * decisions this file implements. A short summary of the runtime model:
 *
 *   - One MIX_Mixer, created with MIX_CreateMixerDevice() when Mix_OpenAudio
 *     is called, backs everything. There is no headless/no-device code path
 *     here; that is intentionally reserved for tests, which may create
 *     their own throwaway MIX_Mixer via MIX_CreateMixer() directly against
 *     the real SDL_mixer 3 API.
 *   - A fixed set of reusable MIX_Track objects (one per legacy channel,
 *     resized by Mix_AllocateChannels) plus one reusable MIX_Track for
 *     music. Reusing tracks instead of creating one per Mix_PlayChannel/
 *     Mix_PlayMusic call matches legacy channel semantics (a channel index
 *     is a stable slot, not a per-call handle).
 *   - MIX_TrackStoppedCallback is installed once per track, at creation
 *     time, and never removed until the track itself is destroyed. The
 *     legacy Mix_ChannelFinished()/Mix_HookMusicFinished() hooks only ever
 *     change *which* app-level function pointer that installed callback
 *     forwards to, so re-registering a hook can never race with a track's
 *     lifetime.
 *   - Every access to the adapter's shared bookkeeping (the channel track
 *     table, the last-known chunk per channel, and the two hook function
 *     pointers) is made while holding MIX_LockMixer()/MIX_UnlockMixer().
 *     This matters because MIX_TrackStoppedCallback is invoked from
 *     SDL_mixer's own mixer thread when the mixer is backed by a real
 *     device; MIX_LockMixer() is the mechanism SDL_mixer's own
 *     documentation recommends for exactly this situation ("The app has
 *     provided a callback that the mixing thread might call, and there is
 *     some app state that needs to be protected against race conditions").
 */

#include "include/SDL_mixer.h"

#include <algorithm>
#include <string>
#include <vector>

namespace
{

int ClampLegacyVolume(int volume)
{
	if (volume < 0) {
		return 0;
	}
	if (volume > MIX_MAX_VOLUME) {
		return MIX_MAX_VOLUME;
	}
	return volume;
}

float LegacyVolumeToGain(int volume)
{
	return static_cast<float>(ClampLegacyVolume(volume))
	       / static_cast<float>(MIX_MAX_VOLUME);
}

/**
 * All adapter state that can be touched by both the app thread (through the
 * Mix_* entry points below) and SDL_mixer's own mixer thread (through the
 * MIX_TrackStoppedCallback trampolines). Every read or write of a
 * MixerState field must happen while the owning MIX_Mixer is locked via
 * MixerLock, except for `mixer` itself, which is only ever touched from the
 * app thread (Mix_OpenAudio/Mix_CloseAudio) and never from a callback.
 */
struct MixerState
{
	MIX_Mixer *mixer = nullptr;

	std::vector<MIX_Track *> channelTracks;
	std::vector<Mix_Chunk *> channelChunk;
	std::vector<int> channelVolume;

	MIX_Track *musicTrack = nullptr;
	int musicVolume = MIX_MAX_VOLUME;

	void (SDLCALL *channelFinishedHook)(int channel) = nullptr;
	void (SDLCALL *musicFinishedHook)(void) = nullptr;
};

MixerState g_state;

// `g_state` is default-constructed using only trivial member initializers
// (nullptr / integer constants / empty std::vector), so this global's
// dynamic initialization never calls into SDL, SDL_mixer, or any audio
// device. No `Mix_*`/`MIX_*` symbol is touched until a caller explicitly
// invokes `Mix_Init`/`Mix_OpenAudio`. This is required for targets (e.g. a
// visionOS/xrsimulator build) that must be able to *compile and link*
// this translation unit, and construct any process-wide globals in it,
// without an active/available playback device -- audio device access only
// ever happens lazily, inside `Mix_OpenAudio()`.

/** RAII guard around MIX_LockMixer()/MIX_UnlockMixer(). Recursive-safe. */
class MixerLock
{
public:
	explicit MixerLock(MIX_Mixer *mixer) : mixer_(mixer)
	{
		MIX_LockMixer(mixer_);
	}
	~MixerLock()
	{
		MIX_UnlockMixer(mixer_);
	}
	MixerLock(const MixerLock &) = delete;
	MixerLock &operator=(const MixerLock &) = delete;

private:
	MIX_Mixer *mixer_;
};

bool ChannelInRange(int channel)
{
	return channel >= 0
	       && static_cast<size_t>(channel) < g_state.channelTracks.size();
}

void SDLCALL ChannelTrackStoppedTrampoline(void *userdata, MIX_Track *track)
{
	(void) userdata;
	// SDL_mixer already holds the mixer lock while invoking this callback
	// (see MIX_LockMixer's documentation: "the SDL audio device thread ...
	// also locks the mixer while actual mixing is in progress"); the lock
	// is documented as safely recursive, so re-acquiring it here is both
	// correct and cheap, and keeps this function safe to reason about in
	// isolation.
	MixerLock lock(g_state.mixer);
	for (size_t i = 0; i < g_state.channelTracks.size(); ++i) {
		if (g_state.channelTracks[i] == track) {
			if (g_state.channelFinishedHook != nullptr) {
				g_state.channelFinishedHook(static_cast<int>(i));
			}
			return;
		}
	}
}

void SDLCALL MusicTrackStoppedTrampoline(void *userdata, MIX_Track *track)
{
	(void) userdata;
	(void) track;
	MixerLock lock(g_state.mixer);
	if (g_state.musicFinishedHook != nullptr) {
		g_state.musicFinishedHook();
	}
}

/** Applies the combined channel/chunk gain to a channel's track. */
bool ApplyChannelGain(int channel)
{
	const float channelGain = LegacyVolumeToGain(g_state.channelVolume[channel]);
	const Mix_Chunk *chunk = g_state.channelChunk[channel];
	const float chunkGain =
		chunk != nullptr ? LegacyVolumeToGain(chunk->volume) : 1.0f;
	return MIX_SetTrackGain(
		g_state.channelTracks[channel], channelGain * chunkGain);
}

bool TrackActive(MIX_Track *track)
{
	return MIX_TrackPlaying(track) || MIX_TrackPaused(track);
}

int FindFreeChannel()
{
	for (size_t i = 0; i < g_state.channelTracks.size(); ++i) {
		if (!TrackActive(g_state.channelTracks[i])) {
			return static_cast<int>(i);
		}
	}
	return -1;
}

bool HasDecoderNamed(const char *name)
{
	if (name == nullptr) {
		return false;
	}
	const int count = MIX_GetNumAudioDecoders();
	for (int i = 0; i < count; ++i) {
		const char *decoderName = MIX_GetAudioDecoder(i);
		if (decoderName != nullptr && SDL_strcasecmp(decoderName, name) == 0) {
			return true;
		}
	}
	return false;
}

/**
 * Detaches `chunk` from any channel currently pointing at it (halting
 * playback first) so Mix_FreeChunk() can safely destroy the underlying
 * MIX_Audio even if the caller forgot to stop playback first.
 */
bool DetachChunkFromChannels(Mix_Chunk *chunk)
{
	if (g_state.mixer == nullptr) {
		return true;
	}
	MixerLock lock(g_state.mixer);
	for (size_t i = 0; i < g_state.channelTracks.size(); ++i) {
		if (g_state.channelChunk[i] == chunk) {
			if (TrackActive(g_state.channelTracks[i])
			    && !MIX_StopTrack(g_state.channelTracks[i], 0)) {
				return false;
			}
			if (!MIX_SetTrackAudio(g_state.channelTracks[i], nullptr)) {
				return false;
			}
			g_state.channelChunk[i] = nullptr;
		}
	}
	return true;
}

} // namespace

/* ===========================================================================
   Library init/quit
   =========================================================================== */

int Mix_Init(int flags)
{
	return MIX_Init() ? flags : 0;
}

void Mix_Quit(void)
{
	MIX_Quit();
}

/* ===========================================================================
   Device
   =========================================================================== */

int Mix_OpenAudio(int frequency, Uint16 format, int channels, int chunksize)
{
	(void) chunksize;

	if (g_state.mixer != nullptr) {
		SDL_SetError("Audio device is already open");
		return -1;
	}

	// Mix_OpenAudio always pairs this MIX_Init() with a MIX_Quit() in
	// Mix_CloseAudio(), regardless of whether the caller separately called
	// the legacy Mix_Init()/Mix_Quit() around it. SDL_mixer 3 ref-counts
	// MIX_Init()/MIX_Quit() pairs internally, so any number of matched
	// pairs compose correctly no matter how they are interleaved.
	if (!MIX_Init()) {
		return -1;
	}

	SDL_AudioSpec spec{};
	spec.format = static_cast<SDL_AudioFormat>(format);
	spec.channels = channels;
	spec.freq = frequency;

	MIX_Mixer *mixer =
		MIX_CreateMixerDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec);
	if (mixer == nullptr) {
		MIX_Quit();
		return -1;
	}

	MIX_Track *musicTrack = MIX_CreateTrack(mixer);
	if (musicTrack == nullptr) {
		MIX_DestroyMixer(mixer);
		MIX_Quit();
		return -1;
	}
	if (!MIX_SetTrackStoppedCallback(
		    musicTrack, &MusicTrackStoppedTrampoline, nullptr)) {
		MIX_DestroyTrack(musicTrack);
		MIX_DestroyMixer(mixer);
		MIX_Quit();
		return -1;
	}

	g_state.mixer = mixer;
	g_state.musicTrack = musicTrack;
	g_state.musicVolume = MIX_MAX_VOLUME;
	return 0;
}

void Mix_CloseAudio(void)
{
	if (g_state.mixer == nullptr) {
		return;
	}

	// MIX_DestroyMixer() destroys every MIX_Track created on this mixer
	// (channel tracks and the music track alike), and blocks until any
	// in-progress mixing on another thread has finished, so there is no
	// risk of a trampoline running against a destroyed mixer afterwards,
	// and no risk of a trampoline being "in flight" concurrently with the
	// state resets below.
	MIX_DestroyMixer(g_state.mixer);
	MIX_Quit();

	// Deterministic, complete reset of every piece of *device-scoped*
	// state: no channel/chunk/volume bookkeeping, query function, or
	// callback trampoline can report a stale "still open"/"still
	// playing"/"still paused" success after this point (Mix_Playing(),
	// Mix_Paused(), Mix_GetChunk(), Mix_AllocateChannels(), etc. all check
	// `g_state.mixer == nullptr` first and fail/zero out explicitly). A
	// subsequent Mix_OpenAudio() starts from this exact same clean slate
	// every time, so close/reopen cycles are fully repeatable.
	g_state.mixer = nullptr;
	g_state.musicTrack = nullptr;
	g_state.channelTracks.clear();
	g_state.channelChunk.clear();
	g_state.channelVolume.clear();
	g_state.musicVolume = MIX_MAX_VOLUME;

	// g_state.channelFinishedHook / g_state.musicFinishedHook are
	// deliberately left untouched: in SDL_mixer 2 these hooks are
	// independent of the audio device's open/closed lifecycle, and an app
	// that re-opens audio should not have to re-install them. This is
	// safe with respect to "no stale callbacks left behind": the hooks
	// are plain function pointers into the app's own code, never bound to
	// a specific (now-destroyed) MIX_Track, so they cannot dangle, and
	// they are physically incapable of firing while the mixer is closed
	// (there is no track left for SDL_mixer to invoke a stopped-callback
	// on). The very next Mix_OpenAudio() re-creates fresh tracks and
	// re-installs the trampolines, which simply forward to whatever hook
	// is current at the time they fire.
}

int Mix_AllocateChannels(int numchans)
{
	if (g_state.mixer == nullptr) {
		SDL_SetError("Audio device hasn't been opened");
		return static_cast<int>(g_state.channelTracks.size());
	}
	if (numchans < 0) {
		return static_cast<int>(g_state.channelTracks.size());
	}

	MixerLock lock(g_state.mixer);
	const size_t want = static_cast<size_t>(numchans);

	while (g_state.channelTracks.size() > want) {
		MIX_Track *track = g_state.channelTracks.back();
		if (TrackActive(track) && !MIX_StopTrack(track, 0)) {
			break;
		}
		MIX_DestroyTrack(track);
		g_state.channelTracks.pop_back();
		g_state.channelChunk.pop_back();
		g_state.channelVolume.pop_back();
	}

	while (g_state.channelTracks.size() < want) {
		MIX_Track *track = MIX_CreateTrack(g_state.mixer);
		if (track == nullptr) {
			// SDL_mixer has already called SDL_SetError(); stop growing
			// and report how many channels actually exist.
			break;
		}
		if (!MIX_SetTrackStoppedCallback(
			    track, &ChannelTrackStoppedTrampoline, nullptr)) {
			MIX_DestroyTrack(track);
			break;
		}
		g_state.channelTracks.push_back(track);
		g_state.channelChunk.push_back(nullptr);
		g_state.channelVolume.push_back(MIX_MAX_VOLUME);
	}

	return static_cast<int>(g_state.channelTracks.size());
}

/* ===========================================================================
   Decoders
   =========================================================================== */

int Mix_GetNumChunkDecoders(void)
{
	return MIX_GetNumAudioDecoders();
}

const char *Mix_GetChunkDecoder(int index)
{
	return MIX_GetAudioDecoder(index);
}

bool Mix_HasChunkDecoder(const char *name)
{
	return HasDecoderNamed(name);
}

int Mix_GetNumMusicDecoders(void)
{
	return MIX_GetNumAudioDecoders();
}

const char *Mix_GetMusicDecoder(int index)
{
	return MIX_GetAudioDecoder(index);
}

bool Mix_HasMusicDecoder(const char *name)
{
	return HasDecoderNamed(name);
}

/* ===========================================================================
   Chunks (sound effects)
   =========================================================================== */

Mix_Chunk *Mix_LoadWAV(const char *file)
{
	if (file == nullptr) {
		SDL_InvalidParamError("file");
		return nullptr;
	}
	if (g_state.mixer == nullptr) {
		SDL_SetError("Audio device hasn't been opened");
		return nullptr;
	}

	MIX_Audio *audio = MIX_LoadAudio(g_state.mixer, file, /*predecode=*/true);
	if (audio == nullptr) {
		return nullptr;
	}

	// SDL_calloc()/SDL_free() (not new/delete) so that Stratagus's
	// DYNAMIC_LOAD std::swap() trick (sound_server.cpp) always frees a
	// Mix_Chunk with an allocator matching how it was actually allocated,
	// no matter which side of the swap it ends up on. See the header
	// comment in platform/sdl3/include/SDL_mixer.h for the full rationale.
	Mix_Chunk *chunk =
		static_cast<Mix_Chunk *>(SDL_calloc(1, sizeof(Mix_Chunk)));
	if (chunk == nullptr) {
		MIX_DestroyAudio(audio);
		return nullptr;
	}
	chunk->allocated = 1;
	chunk->volume = MIX_MAX_VOLUME;
	chunk->PeonPadMixAudio = audio;
	return chunk;
}

Mix_Chunk *Mix_LoadWAV_RW(SDL_IOStream *src, int freesrc)
{
	if (src == nullptr) {
		SDL_InvalidParamError("src");
		return nullptr;
	}
	if (g_state.mixer == nullptr) {
		SDL_SetError("Audio device hasn't been opened");
		if (freesrc != 0) {
			SDL_CloseIO(src);
		}
		return nullptr;
	}

	MIX_Audio *audio = MIX_LoadAudio_IO(g_state.mixer, src, /*predecode=*/true,
	                                     freesrc != 0);
	if (audio == nullptr) {
		// MIX_LoadAudio_IO() already closed src (if requested) and set
		// the error string.
		return nullptr;
	}

	Mix_Chunk *chunk =
		static_cast<Mix_Chunk *>(SDL_calloc(1, sizeof(Mix_Chunk)));
	if (chunk == nullptr) {
		MIX_DestroyAudio(audio);
		return nullptr;
	}
	chunk->allocated = 1;
	chunk->volume = MIX_MAX_VOLUME;
	chunk->PeonPadMixAudio = audio;
	return chunk;
}

void Mix_FreeChunk(Mix_Chunk *chunk)
{
	if (chunk == nullptr) {
		return;
	}
	if (!DetachChunkFromChannels(chunk)) {
		return;
	}
	if (chunk->PeonPadMixAudio != nullptr) {
		MIX_DestroyAudio(chunk->PeonPadMixAudio);
	}
	SDL_free(chunk);
}

/* ===========================================================================
   Music (streaming)
   =========================================================================== */

struct Mix_Music
{
	MIX_Audio *audio;
};

Mix_Music *Mix_LoadMUS(const char *file)
{
	if (file == nullptr) {
		SDL_InvalidParamError("file");
		return nullptr;
	}
	if (g_state.mixer == nullptr) {
		SDL_SetError("Audio device hasn't been opened");
		return nullptr;
	}

	// predecode=false: music is expected to stream from disk rather than
	// fully decode up front, matching legacy Mix_Music behavior for
	// typically-long background tracks.
	MIX_Audio *audio = MIX_LoadAudio(g_state.mixer, file, /*predecode=*/false);
	if (audio == nullptr) {
		return nullptr;
	}

	auto *music = static_cast<Mix_Music *>(SDL_calloc(1, sizeof(Mix_Music)));
	if (music == nullptr) {
		MIX_DestroyAudio(audio);
		return nullptr;
	}
	music->audio = audio;
	return music;
}

Mix_Music *Mix_LoadMUS_RW(SDL_IOStream *src, int freesrc)
{
	if (src == nullptr) {
		SDL_InvalidParamError("src");
		return nullptr;
	}
	if (g_state.mixer == nullptr) {
		SDL_SetError("Audio device hasn't been opened");
		if (freesrc != 0) {
			SDL_CloseIO(src);
		}
		return nullptr;
	}

	MIX_Audio *audio = MIX_LoadAudio_IO(g_state.mixer, src, /*predecode=*/false,
	                                     freesrc != 0);
	if (audio == nullptr) {
		return nullptr;
	}

	auto *music = static_cast<Mix_Music *>(SDL_calloc(1, sizeof(Mix_Music)));
	if (music == nullptr) {
		MIX_DestroyAudio(audio);
		return nullptr;
	}
	music->audio = audio;
	return music;
}

void Mix_FreeMusic(Mix_Music *music)
{
	if (music == nullptr) {
		return;
	}
	if (g_state.mixer != nullptr && g_state.musicTrack != nullptr) {
		MixerLock lock(g_state.mixer);
		if (MIX_GetTrackAudio(g_state.musicTrack) == music->audio) {
			if (TrackActive(g_state.musicTrack)
			    && !MIX_StopTrack(g_state.musicTrack, 0)) {
				return;
			}
			if (!MIX_SetTrackAudio(g_state.musicTrack, nullptr)) {
				return;
			}
		}
	}
	if (music->audio != nullptr) {
		MIX_DestroyAudio(music->audio);
	}
	SDL_free(music);
}

/* ===========================================================================
   Channel (sound effect) playback
   =========================================================================== */

int Mix_PlayChannel(int channel, Mix_Chunk *chunk, int loops)
{
	if (g_state.mixer == nullptr) {
		SDL_SetError("Audio device hasn't been opened");
		return -1;
	}
	if (chunk == nullptr || chunk->PeonPadMixAudio == nullptr) {
		SDL_InvalidParamError("chunk");
		return -1;
	}

	MixerLock lock(g_state.mixer);

	int target = channel;
	if (target == -1) {
		target = FindFreeChannel();
		if (target < 0) {
			SDL_SetError("No free channels available");
			return -1;
		}
	} else if (!ChannelInRange(target)) {
		SDL_SetError("Channel %d is out of range", target);
		return -1;
	}

	MIX_Track *track = g_state.channelTracks[target];

	// Build the play-properties (loop count) before mutating any track or
	// bookkeeping state, so a failure here (e.g. out of memory) leaves
	// everything untouched instead of silently playing with the wrong
	// (ignored) loop count.
	SDL_PropertiesID props = SDL_CreateProperties();
	if (props == 0) {
		return -1;
	}
	if (!SDL_SetNumberProperty(props, MIX_PROP_PLAY_LOOPS_NUMBER, loops)) {
		SDL_DestroyProperties(props);
		return -1;
	}

	if (TrackActive(track) && !MIX_StopTrack(track, 0)) {
		SDL_DestroyProperties(props);
		return -1;
	}

	if (!MIX_SetTrackAudio(track, chunk->PeonPadMixAudio)) {
		SDL_DestroyProperties(props);
		return -1;
	}
	g_state.channelChunk[target] = chunk;
	if (!ApplyChannelGain(target)) {
		g_state.channelChunk[target] = nullptr;
		MIX_SetTrackAudio(track, nullptr);
		SDL_DestroyProperties(props);
		return -1;
	}

	const bool started = MIX_PlayTrack(track, props);
	SDL_DestroyProperties(props);
	if (!started) {
		g_state.channelChunk[target] = nullptr;
		MIX_SetTrackAudio(track, nullptr);
		return -1;
	}
	return target;
}

int Mix_HaltChannel(int channel)
{
	if (g_state.mixer == nullptr) {
		SDL_SetError("Audio device hasn't been opened");
		return -1;
	}

	MixerLock lock(g_state.mixer);
	if (channel == -1) {
		for (MIX_Track *track : g_state.channelTracks) {
			if (TrackActive(track) && !MIX_StopTrack(track, 0)) {
				return -1;
			}
		}
		return 0;
	}
	if (!ChannelInRange(channel)) {
		SDL_SetError("Channel %d is out of range", channel);
		return -1;
	}
	MIX_Track *track = g_state.channelTracks[channel];
	return !TrackActive(track) || MIX_StopTrack(track, 0) ? 0 : -1;
}

int Mix_Pause(int channel)
{
	if (g_state.mixer == nullptr) {
		SDL_SetError("Audio device hasn't been opened");
		return -1;
	}

	MixerLock lock(g_state.mixer);
	if (channel == -1) {
		for (MIX_Track *track : g_state.channelTracks) {
			if (MIX_TrackPlaying(track) && !MIX_PauseTrack(track)) {
				return -1;
			}
		}
		return 0;
	}
	if (!ChannelInRange(channel)) {
		SDL_SetError("Channel %d is out of range", channel);
		return -1;
	}
	MIX_Track *track = g_state.channelTracks[channel];
	return !MIX_TrackPlaying(track) || MIX_PauseTrack(track) ? 0 : -1;
}

int Mix_Resume(int channel)
{
	if (g_state.mixer == nullptr) {
		SDL_SetError("Audio device hasn't been opened");
		return -1;
	}

	MixerLock lock(g_state.mixer);
	if (channel == -1) {
		for (MIX_Track *track : g_state.channelTracks) {
			if (MIX_TrackPaused(track) && !MIX_ResumeTrack(track)) {
				return -1;
			}
		}
		return 0;
	}
	if (!ChannelInRange(channel)) {
		SDL_SetError("Channel %d is out of range", channel);
		return -1;
	}
	MIX_Track *track = g_state.channelTracks[channel];
	return !MIX_TrackPaused(track) || MIX_ResumeTrack(track) ? 0 : -1;
}

int Mix_Paused(int channel)
{
	if (g_state.mixer == nullptr) {
		return 0;
	}

	MixerLock lock(g_state.mixer);
	if (channel == -1) {
		int count = 0;
		for (MIX_Track *track : g_state.channelTracks) {
			count += MIX_TrackPaused(track) ? 1 : 0;
		}
		return count;
	}
	if (!ChannelInRange(channel)) {
		return 0;
	}
	return MIX_TrackPaused(g_state.channelTracks[channel]) ? 1 : 0;
}

int Mix_Playing(int channel)
{
	if (g_state.mixer == nullptr) {
		return 0;
	}

	MixerLock lock(g_state.mixer);
	if (channel == -1) {
		int count = 0;
		for (MIX_Track *track : g_state.channelTracks) {
			count += TrackActive(track) ? 1 : 0;
		}
		return count;
	}
	if (!ChannelInRange(channel)) {
		return 0;
	}
	return TrackActive(g_state.channelTracks[channel]) ? 1 : 0;
}

int Mix_Volume(int channel, int volume)
{
	if (g_state.mixer == nullptr) {
		SDL_SetError("Audio device hasn't been opened");
		return -1;
	}

	MixerLock lock(g_state.mixer);
	if (channel == -1) {
		long previousSum = 0;
		for (int current : g_state.channelVolume) {
			previousSum += current;
		}
		if (volume >= 0) {
			const int clamped = ClampLegacyVolume(volume);
			for (size_t i = 0; i < g_state.channelTracks.size(); ++i) {
				const Mix_Chunk *chunk = g_state.channelChunk[i];
				const float chunkGain =
					chunk != nullptr
						? LegacyVolumeToGain(chunk->volume)
						: 1.0f;
				if (!MIX_SetTrackGain(
					    g_state.channelTracks[i],
					    LegacyVolumeToGain(clamped) * chunkGain)) {
					for (size_t rollback = 0; rollback < i; ++rollback) {
						ApplyChannelGain(static_cast<int>(rollback));
					}
					return -1;
				}
			}
			std::fill(g_state.channelVolume.begin(),
			          g_state.channelVolume.end(), clamped);
		}
		if (g_state.channelVolume.empty()) {
			return 0;
		}
		return static_cast<int>(
			previousSum / static_cast<long>(g_state.channelVolume.size()));
	}
	if (!ChannelInRange(channel)) {
		SDL_SetError("Channel %d is out of range", channel);
		return -1;
	}
	const int previous = g_state.channelVolume[channel];
	if (volume >= 0) {
		g_state.channelVolume[channel] = ClampLegacyVolume(volume);
		if (!ApplyChannelGain(channel)) {
			g_state.channelVolume[channel] = previous;
			return -1;
		}
	}
	return previous;
}

int Mix_SetPanning(int channel, Uint8 left, Uint8 right)
{
	if (g_state.mixer == nullptr) {
		SDL_SetError("Audio device hasn't been opened");
		return 0;
	}
	if (channel == MIX_CHANNEL_POST) {
		SDL_SetError(
			"Post-mix panning (MIX_CHANNEL_POST) is not supported by the "
			"SDL_mixer 3 compatibility layer");
		return 0;
	}

	MixerLock lock(g_state.mixer);
	if (!ChannelInRange(channel)) {
		SDL_SetError("Channel %d is out of range", channel);
		return 0;
	}

	MIX_Track *track = g_state.channelTracks[channel];
	if (left == 255 && right == 255) {
		// Legacy convention for "no panning": restore normal spatialization.
		return MIX_SetTrackStereo(track, nullptr) ? 1 : 0;
	}
	const MIX_StereoGains gains{static_cast<float>(left) / 255.0f,
	                             static_cast<float>(right) / 255.0f};
	return MIX_SetTrackStereo(track, &gains) ? 1 : 0;
}

Mix_Chunk *Mix_GetChunk(int channel)
{
	if (g_state.mixer == nullptr) {
		SDL_SetError("Audio device hasn't been opened");
		return nullptr;
	}

	MixerLock lock(g_state.mixer);
	if (!ChannelInRange(channel)) {
		SDL_SetError("Channel %d is out of range", channel);
		return nullptr;
	}
	return g_state.channelChunk[channel];
}

void Mix_ChannelFinished(void (SDLCALL *channel_finished)(int channel))
{
	// The assignment is a single pointer-sized store either way; the lock
	// is only needed to synchronize with a concurrently-running mixer
	// thread, which can only exist while a mixer is open.
	if (g_state.mixer != nullptr) {
		MixerLock lock(g_state.mixer);
		g_state.channelFinishedHook = channel_finished;
		return;
	}
	g_state.channelFinishedHook = channel_finished;
}

/* ===========================================================================
   Music playback
   =========================================================================== */

int Mix_PlayMusic(Mix_Music *music, int loops)
{
	if (g_state.mixer == nullptr || g_state.musicTrack == nullptr) {
		SDL_SetError("Audio device hasn't been opened");
		return -1;
	}
	if (music == nullptr || music->audio == nullptr) {
		SDL_InvalidParamError("music");
		return -1;
	}

	MixerLock lock(g_state.mixer);

	// Same ordering rationale as Mix_PlayChannel: build properties before
	// mutating any track state, so a failure here cannot silently start
	// playback with the wrong (ignored) loop count.
	SDL_PropertiesID props = SDL_CreateProperties();
	if (props == 0) {
		return -1;
	}
	if (!SDL_SetNumberProperty(props, MIX_PROP_PLAY_LOOPS_NUMBER, loops)) {
		SDL_DestroyProperties(props);
		return -1;
	}

	if (TrackActive(g_state.musicTrack)
	    && !MIX_StopTrack(g_state.musicTrack, 0)) {
		SDL_DestroyProperties(props);
		return -1;
	}

	if (!MIX_SetTrackAudio(g_state.musicTrack, music->audio)) {
		SDL_DestroyProperties(props);
		return -1;
	}
	if (!MIX_SetTrackGain(
		    g_state.musicTrack, LegacyVolumeToGain(g_state.musicVolume))) {
		MIX_SetTrackAudio(g_state.musicTrack, nullptr);
		SDL_DestroyProperties(props);
		return -1;
	}

	const bool started = MIX_PlayTrack(g_state.musicTrack, props);
	SDL_DestroyProperties(props);
	if (!started) {
		MIX_SetTrackAudio(g_state.musicTrack, nullptr);
	}
	return started ? 0 : -1;
}

int Mix_HaltMusic(void)
{
	if (g_state.mixer == nullptr || g_state.musicTrack == nullptr) {
		return 0;
	}
	MixerLock lock(g_state.mixer);
	return !TrackActive(g_state.musicTrack)
		       || MIX_StopTrack(g_state.musicTrack, 0)
	           ? 0
	           : -1;
}

int Mix_PauseMusic(void)
{
	if (g_state.mixer == nullptr || g_state.musicTrack == nullptr) {
		return 0;
	}
	MixerLock lock(g_state.mixer);
	return !MIX_TrackPlaying(g_state.musicTrack)
		       || MIX_PauseTrack(g_state.musicTrack)
	           ? 0
	           : -1;
}

int Mix_ResumeMusic(void)
{
	if (g_state.mixer == nullptr || g_state.musicTrack == nullptr) {
		return 0;
	}
	MixerLock lock(g_state.mixer);
	return !MIX_TrackPaused(g_state.musicTrack)
		       || MIX_ResumeTrack(g_state.musicTrack)
	           ? 0
	           : -1;
}

int Mix_PausedMusic(void)
{
	if (g_state.mixer == nullptr || g_state.musicTrack == nullptr) {
		return 0;
	}
	MixerLock lock(g_state.mixer);
	return MIX_TrackPaused(g_state.musicTrack) ? 1 : 0;
}

int Mix_PlayingMusic(void)
{
	if (g_state.mixer == nullptr || g_state.musicTrack == nullptr) {
		return 0;
	}
	MixerLock lock(g_state.mixer);
	return TrackActive(g_state.musicTrack) ? 1 : 0;
}

int Mix_VolumeMusic(int volume)
{
	if (g_state.mixer == nullptr || g_state.musicTrack == nullptr) {
		SDL_SetError("Audio device hasn't been opened");
		return 0;
	}
	MixerLock lock(g_state.mixer);
	const int previous = g_state.musicVolume;
	if (volume >= 0) {
		g_state.musicVolume = ClampLegacyVolume(volume);
		if (!MIX_SetTrackGain(
			    g_state.musicTrack,
			    LegacyVolumeToGain(g_state.musicVolume))) {
			g_state.musicVolume = previous;
			return -1;
		}
	}
	return previous;
}

void Mix_HookMusicFinished(void (SDLCALL *music_finished)(void))
{
	if (g_state.mixer != nullptr) {
		MixerLock lock(g_state.mixer);
		g_state.musicFinishedHook = music_finished;
		return;
	}
	g_state.musicFinishedHook = music_finished;
}

/* ===========================================================================
   Timidity configuration
   =========================================================================== */

bool Mix_SetTimidityCfg(const char *path)
{
	if (path == nullptr) {
		SDL_InvalidParamError("path");
		return false;
	}
	return SDL_setenv_unsafe("TIMIDITY_CFG", path, 1) == 0;
}
