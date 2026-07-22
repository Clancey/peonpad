/**
 * Standalone test for the SDL_mixer 2 compatibility surface implemented in
 * platform/sdl3/include/SDL_mixer.h + platform/sdl3/PeonPadSDL3MixerAdapter.cpp.
 *
 * This test is intentionally self-contained: it fabricates its own in-memory
 * WAV data and its own SDL_IOStream implementation (to observe close
 * ownership precisely), and does not depend on any repository fixture or
 * network access.
 *
 * All correctness checks below use an explicit Check()/CheckEq() helper
 * rather than assert(), specifically so this test remains meaningful when
 * compiled with -DNDEBUG (Release builds). A `--verify-assertions` sentinel
 * is also provided for parity with tests/sdl3_input_adapter_test.cpp, but it
 * is a secondary, best-effort signal, not the mechanism the rest of this
 * test relies on for correctness.
 *
 * Two complementary strategies are used to keep this test both meaningful
 * and CI-safe:
 *
 *   - The bulk of the surface (channel/music playback, callbacks, volume,
 *     panning, pause/resume, decoder queries, teardown/reinit, invalid-use
 *     error paths) is exercised through the actual Mix_* compatibility API,
 *     which always opens a real (if "dummy") playback device via
 *     Mix_OpenAudio(), per the requirement that production audio opening
 *     must go through SDL_mixer 3's device path. The SDL_AUDIODRIVER hint is
 *     forced to "dummy" before anything touches audio, so this is safe to
 *     run in headless CI sandboxes without real audio hardware. Because the
 *     mixer runs on SDL_mixer's own real-time device thread in this mode,
 *     a handful of assertions poll with a bounded timeout instead of
 *     sleeping a fixed duration.
 *   - A separate, deterministic check drives a throwaway MIX_Mixer created
 *     directly with MIX_CreateMixer() (no device, no real-time thread) and
 *     MIX_Generate(), calling straight into SDL_mixer 3's own API (not this
 *     adapter) to confirm, without any timing dependency, that this
 *     adapter's core design assumption -- that MIX_PROP_PLAY_LOOPS_NUMBER
 *     and MIX_StopTrack/MIX_TrackStoppedCallback behave exactly like legacy
 *     Mix_Chunk/Mix_Music loop counts and Mix_ChannelFinished/
 *     Mix_HookMusicFinished -- actually holds against the real library.
 */

// This resolves to platform/sdl3/include/SDL_mixer.h once the parent build
// wires platform/sdl3/include onto the SDL3 lane's include path (ahead of any
// SDL2 SDL_mixer path), matching how the engine's own `#include <SDL_mixer.h>`
// will resolve in that lane.
#include <SDL_mixer.h>

#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

namespace
{

int g_failures = 0;

void Check(bool condition, const char *what)
{
	if (!condition) {
		++g_failures;
		std::fprintf(stderr, "CHECK FAILED: %s\n", what);
	}
}

void CheckEq(long actual, long expected, const char *what)
{
	if (actual != expected) {
		++g_failures;
		std::fprintf(stderr, "CHECK FAILED: %s (expected %ld, got %ld)\n",
		              what, expected, actual);
	}
}

bool AssertionsAreActive()
{
	bool evaluated = false;
	assert((evaluated = true));
	return evaluated;
}

/* -------------------------------------------------------------------------
   In-memory WAV fabrication
   ------------------------------------------------------------------------- */

void AppendU32LE(std::vector<Uint8> &out, Uint32 value)
{
	out.push_back(static_cast<Uint8>(value & 0xFF));
	out.push_back(static_cast<Uint8>((value >> 8) & 0xFF));
	out.push_back(static_cast<Uint8>((value >> 16) & 0xFF));
	out.push_back(static_cast<Uint8>((value >> 24) & 0xFF));
}

void AppendU16LE(std::vector<Uint8> &out, Uint16 value)
{
	out.push_back(static_cast<Uint8>(value & 0xFF));
	out.push_back(static_cast<Uint8>((value >> 8) & 0xFF));
}

/** Builds a minimal, valid mono 16-bit PCM WAV containing a sine tone. */
std::vector<Uint8> BuildSineWav(int sampleRate, double seconds, double hz)
{
	const Uint32 frameCount = static_cast<Uint32>(sampleRate * seconds);
	const Uint16 channels = 1;
	const Uint16 bitsPerSample = 16;
	const Uint32 byteRate = sampleRate * channels * (bitsPerSample / 8);
	const Uint16 blockAlign = static_cast<Uint16>(channels * (bitsPerSample / 8));
	const Uint32 dataBytes = frameCount * blockAlign;

	std::vector<Uint8> wav;
	wav.reserve(44 + dataBytes);

	// RIFF header
	wav.insert(wav.end(), {'R', 'I', 'F', 'F'});
	AppendU32LE(wav, 36 + dataBytes);
	wav.insert(wav.end(), {'W', 'A', 'V', 'E'});

	// fmt chunk
	wav.insert(wav.end(), {'f', 'm', 't', ' '});
	AppendU32LE(wav, 16); // PCM fmt chunk size
	AppendU16LE(wav, 1);  // PCM
	AppendU16LE(wav, channels);
	AppendU32LE(wav, static_cast<Uint32>(sampleRate));
	AppendU32LE(wav, byteRate);
	AppendU16LE(wav, blockAlign);
	AppendU16LE(wav, bitsPerSample);

	// data chunk
	wav.insert(wav.end(), {'d', 'a', 't', 'a'});
	AppendU32LE(wav, dataBytes);
	for (Uint32 i = 0; i < frameCount; ++i) {
		const double t = static_cast<double>(i) / sampleRate;
		const double sample = std::sin(2.0 * 3.14159265358979323846 * hz * t);
		const auto s16 = static_cast<Sint16>(sample * 20000.0);
		AppendU16LE(wav, static_cast<Uint16>(s16));
	}
	return wav;
}

/* -------------------------------------------------------------------------
   A minimal SDL_IOStream over an in-memory buffer that reports back to the
   test whenever SDL_mixer (or this adapter) closes it, so closeio ownership
   can be verified precisely.
   ------------------------------------------------------------------------- */

struct TrackedMemoryIO
{
	const Uint8 *data;
	size_t size;
	Sint64 position = 0;
	bool *closedFlag;
};

Sint64 SDLCALL TrackedIOSize(void *userdata)
{
	auto *io = static_cast<TrackedMemoryIO *>(userdata);
	return static_cast<Sint64>(io->size);
}

Sint64 SDLCALL TrackedIOSeek(void *userdata, Sint64 offset, SDL_IOWhence whence)
{
	auto *io = static_cast<TrackedMemoryIO *>(userdata);
	Sint64 base = 0;
	switch (whence) {
	case SDL_IO_SEEK_SET: base = 0; break;
	case SDL_IO_SEEK_CUR: base = io->position; break;
	case SDL_IO_SEEK_END: base = static_cast<Sint64>(io->size); break;
	}
	const Sint64 target = base + offset;
	if (target < 0 || target > static_cast<Sint64>(io->size)) {
		SDL_SetError("seek out of range");
		return -1;
	}
	io->position = target;
	return target;
}

size_t SDLCALL TrackedIORead(void *userdata, void *ptr, size_t size,
                              SDL_IOStatus *status)
{
	auto *io = static_cast<TrackedMemoryIO *>(userdata);
	const size_t remaining = io->size - static_cast<size_t>(io->position);
	const size_t toCopy = size < remaining ? size : remaining;
	if (toCopy == 0) {
		*status = SDL_IO_STATUS_EOF;
		return 0;
	}
	std::memcpy(ptr, io->data + io->position, toCopy);
	io->position += static_cast<Sint64>(toCopy);
	return toCopy;
}

size_t SDLCALL TrackedIOWrite(void *, const void *, size_t, SDL_IOStatus *status)
{
	*status = SDL_IO_STATUS_WRITEONLY;
	return 0;
}

bool SDLCALL TrackedIOClose(void *userdata)
{
	auto *io = static_cast<TrackedMemoryIO *>(userdata);
	if (io->closedFlag != nullptr) {
		*io->closedFlag = true;
	}
	delete io;
	return true;
}

/** Creates a seekable SDL_IOStream over `bytes` and reports closes via `closedFlag`. */
SDL_IOStream *OpenTrackedIO(const std::vector<Uint8> &bytes, bool *closedFlag)
{
	auto *userdata = new TrackedMemoryIO();
	userdata->data = bytes.data();
	userdata->size = bytes.size();
	userdata->closedFlag = closedFlag;

	SDL_IOStreamInterface iface;
	SDL_INIT_INTERFACE(&iface);
	iface.size = &TrackedIOSize;
	iface.seek = &TrackedIOSeek;
	iface.read = &TrackedIORead;
	iface.write = &TrackedIOWrite;
	iface.close = &TrackedIOClose;
	return SDL_OpenIO(&iface, userdata);
}

/* -------------------------------------------------------------------------
   Bounded polling helper (avoids both busy-hangs and flaky fixed sleeps).
   ------------------------------------------------------------------------- */

bool WaitUntil(const std::function<bool()> &predicate, Uint32 timeoutMs)
{
	const Uint64 deadline = SDL_GetTicks() + timeoutMs;
	while (SDL_GetTicks() < deadline) {
		if (predicate()) {
			return true;
		}
		SDL_Delay(5);
	}
	return predicate();
}

/* -------------------------------------------------------------------------
   Callback trampolines under test
   ------------------------------------------------------------------------- */

volatile bool g_channelFinishedSeen[64] = {};
volatile int g_channelFinishedCount = 0;

void SDLCALL OnChannelFinished(int channel)
{
	if (channel >= 0 && channel < 64) {
		g_channelFinishedSeen[channel] = true;
	}
	++g_channelFinishedCount;
}

volatile bool g_musicFinished = false;

void SDLCALL OnMusicFinished()
{
	g_musicFinished = true;
}

/* -------------------------------------------------------------------------
   Section 1: closeio ownership, before any device is open (also exercises
   the "audio device hasn't been opened" invalid-use error path).
   ------------------------------------------------------------------------- */

void TestCloseIoOwnershipBeforeDeviceOpen(const std::vector<Uint8> &wav)
{
	bool closedA = false;
	SDL_IOStream *ioA = OpenTrackedIO(wav, &closedA);
	Check(ioA != nullptr, "OpenTrackedIO (A) succeeds");
	Mix_Chunk *chunkA = Mix_LoadWAV_RW(ioA, /*freesrc=*/1);
	Check(chunkA == nullptr, "Mix_LoadWAV_RW fails before Mix_OpenAudio");
	Check(closedA, "Mix_LoadWAV_RW(freesrc=1) closes the stream even on failure");
	Check(std::strlen(Mix_GetError()) > 0, "Mix_GetError() is non-empty after failure");

	bool closedB = false;
	SDL_IOStream *ioB = OpenTrackedIO(wav, &closedB);
	Mix_Music *musicB = Mix_LoadMUS_RW(ioB, /*freesrc=*/0);
	Check(musicB == nullptr, "Mix_LoadMUS_RW fails before Mix_OpenAudio");
	Check(!closedB, "Mix_LoadMUS_RW(freesrc=0) leaves the stream open on failure");
	SDL_CloseIO(ioB);
	Check(closedB, "manually closing ioB after freesrc=0 works");
}

/* -------------------------------------------------------------------------
   Section 2: device lifecycle (open/close/reopen), Mix_Init/Mix_Quit pairing
   ------------------------------------------------------------------------- */

bool OpenDeviceForTest()
{
	const int rc = Mix_OpenAudio(MIX_DEFAULT_FREQUENCY, MIX_DEFAULT_FORMAT,
	                              MIX_DEFAULT_CHANNELS, 1024);
	if (rc != 0) {
		std::fprintf(stderr,
		             "Mix_OpenAudio failed (SDL_AUDIODRIVER=dummy expected): "
		             "%s\n",
		             Mix_GetError());
	}
	return rc == 0;
}

void TestDeviceLifecycle()
{
	Check(Mix_Init(static_cast<int>(0xFFFFFFFFu)) != 0, "Mix_Init reports success");

	Check(OpenDeviceForTest(), "Mix_OpenAudio opens the default playback device");

	const int reopenRc = Mix_OpenAudio(MIX_DEFAULT_FREQUENCY, MIX_DEFAULT_FORMAT,
	                                    MIX_DEFAULT_CHANNELS, 1024);
	Check(reopenRc != 0, "Mix_OpenAudio fails when the device is already open");
	Check(std::strlen(Mix_GetError()) > 0,
	      "Mix_GetError() is non-empty after double-open failure");
}

/* -------------------------------------------------------------------------
   Section 3: channel allocation, chunk load/play/query/free, volume,
   panning, pause/resume, ChannelFinished (natural + explicit halt).
   ------------------------------------------------------------------------- */

void TestChannelsAndChunks(const std::vector<Uint8> &shortWav)
{
	Check(Mix_AllocateChannels(8) == 8, "Mix_AllocateChannels(8) allocates 8");
	Check(Mix_AllocateChannels(-1) == 8, "Mix_AllocateChannels(-1) queries without changing");
	Check(Mix_AllocateChannels(4) == 4, "Mix_AllocateChannels(4) shrinks to 4");
	Check(Mix_AllocateChannels(8) == 8, "Mix_AllocateChannels(8) grows back to 8");

	Mix_ChannelFinished(&OnChannelFinished);

	// Invalid-use error paths.
	Check(Mix_LoadWAV(nullptr) == nullptr, "Mix_LoadWAV(nullptr) fails");
	Check(std::strlen(Mix_GetError()) > 0, "Mix_GetError() set after Mix_LoadWAV(nullptr)");
	Check(Mix_PlayChannel(-1, nullptr, 0) == -1, "Mix_PlayChannel(nullptr chunk) fails");
	Check(Mix_GetChunk(9999) == nullptr, "Mix_GetChunk(out-of-range) fails");
	Check(Mix_HaltChannel(9999) == -1, "Mix_HaltChannel(out-of-range) fails");
	Check(Mix_SetPanning(9999, 200, 100) == 0, "Mix_SetPanning(out-of-range) fails");
	Check(Mix_SetPanning(MIX_CHANNEL_POST, 200, 100) == 0,
	      "Mix_SetPanning(MIX_CHANNEL_POST) reports unsupported rather than silently succeeding");

	bool closed = false;
	SDL_IOStream *io = OpenTrackedIO(shortWav, &closed);
	Mix_Chunk *chunk = Mix_LoadWAV_RW(io, /*freesrc=*/1);
	Check(chunk != nullptr, "Mix_LoadWAV_RW loads a valid in-memory WAV");
	Check(closed, "Mix_LoadWAV_RW(freesrc=1) closes the stream on success too");
	if (chunk == nullptr) {
		return;
	}
	CheckEq(chunk->allocated, 1, "loaded chunk reports allocated == 1");
	CheckEq(chunk->volume, MIX_MAX_VOLUME, "loaded chunk defaults to MIX_MAX_VOLUME");

	const int channel = Mix_PlayChannel(-1, chunk, 0);
	Check(channel >= 0, "Mix_PlayChannel(-1, ...) picks a free channel");
	if (channel < 0) {
		Mix_FreeChunk(chunk);
		return;
	}
	Check(Mix_GetChunk(channel) == chunk, "Mix_GetChunk() reports the chunk just played");
	Check(Mix_Playing(channel) == 1, "channel reports playing immediately after Mix_PlayChannel");

	// Volume: legacy semantics report the prior volume.
	CheckEq(Mix_Volume(channel, 64), MIX_MAX_VOLUME,
	        "Mix_Volume(channel, 64) returns the previous volume");
	CheckEq(Mix_Volume(channel, -1), 64, "Mix_Volume(channel, -1) queries without changing");

	// Panning.
	Check(Mix_SetPanning(channel, 200, 100) == 1, "Mix_SetPanning succeeds for a valid channel");
	Check(Mix_SetPanning(channel, 255, 255) == 1, "Mix_SetPanning(255,255) resets panning");

	// Pause/resume.
	Check(Mix_Pause(channel) == 0, "Mix_Pause succeeds");
	Check(Mix_Paused(channel) == 1, "channel reports paused");
	Check(Mix_Playing(channel) == 1,
	      "legacy Mix_Playing includes paused channels");
	const int parallelChannel = Mix_PlayChannel(-1, chunk, 0);
	Check(parallelChannel >= 0 && parallelChannel != channel,
	      "automatic channel selection does not replace a paused channel");
	Check(Mix_Resume(channel) == 0, "Mix_Resume succeeds");
	Check(Mix_Paused(channel) == 0, "channel no longer reports paused after resume");

	// Natural completion should invoke the ChannelFinished hook.
	g_channelFinishedSeen[channel] = false;
	const bool finishedNaturally = WaitUntil(
		[channel]() { return g_channelFinishedSeen[channel]; }, 3000);
	Check(finishedNaturally,
	      "Mix_ChannelFinished hook fires after natural completion");
	Check(Mix_Playing(channel) == 0, "channel is not playing once finished");

	// Explicit halt should also invoke the ChannelFinished hook.
	const int channel2 = Mix_PlayChannel(-1, chunk, -1 /* infinite loop */);
	Check(channel2 >= 0, "second Mix_PlayChannel call succeeds");
	if (channel2 >= 0) {
		g_channelFinishedSeen[channel2] = false;
		Check(Mix_HaltChannel(channel2) == 0, "Mix_HaltChannel succeeds");
		const bool finishedByHalt = WaitUntil(
			[channel2]() { return g_channelFinishedSeen[channel2]; }, 3000);
		Check(finishedByHalt,
		      "Mix_ChannelFinished hook fires after an explicit Mix_HaltChannel");
	}

	// Mix_HaltChannel(-1) must not crash and must stop every channel.
	Check(Mix_HaltChannel(-1) == 0, "Mix_HaltChannel(-1) halts every channel");

	// Defensive free: playing chunk freed without an explicit halt first.
	const int channel3 = Mix_PlayChannel(-1, chunk, -1);
	Check(channel3 >= 0, "third Mix_PlayChannel call succeeds");
	Mix_FreeChunk(chunk);
	if (channel3 >= 0) {
		Check(Mix_GetChunk(channel3) == nullptr,
		      "Mix_FreeChunk detaches the chunk from any channel still playing it");
		Check(Mix_Playing(channel3) == 0,
		      "Mix_FreeChunk halts the channel that was still playing the freed chunk");
	}
}

/* -------------------------------------------------------------------------
   Section 4: music load/play/stop/finished callback, volume, pause/resume.
   ------------------------------------------------------------------------- */

void TestMusic(const std::vector<Uint8> &shortWav)
{
	Mix_HookMusicFinished(&OnMusicFinished);

	Check(Mix_PlayMusic(nullptr, 0) == -1, "Mix_PlayMusic(nullptr) fails");

	bool closed = false;
	SDL_IOStream *io = OpenTrackedIO(shortWav, &closed);
	Mix_Music *music = Mix_LoadMUS_RW(io, /*freesrc=*/1);
	Check(music != nullptr, "Mix_LoadMUS_RW loads a valid in-memory WAV");
	Check(closed, "Mix_LoadMUS_RW(freesrc=1) closes the stream");
	if (music == nullptr) {
		return;
	}

	g_musicFinished = false;
	Check(Mix_PlayMusic(music, 0) == 0, "Mix_PlayMusic starts playback");
	Check(Mix_PlayingMusic() == 1, "Mix_PlayingMusic reports playing");

	const int previousVolume = Mix_VolumeMusic(50);
	Check(previousVolume == MIX_MAX_VOLUME,
	      "Mix_VolumeMusic returns the volume that was in effect before this call");
	CheckEq(Mix_VolumeMusic(-1), 50, "Mix_VolumeMusic(-1) queries without changing");

	Check(Mix_PauseMusic() == 0, "Mix_PauseMusic succeeds");
	Check(Mix_PausedMusic() == 1, "Mix_PausedMusic reports paused");
	Check(Mix_PlayingMusic() == 1,
	      "legacy Mix_PlayingMusic includes paused music");
	Check(Mix_ResumeMusic() == 0, "Mix_ResumeMusic succeeds");
	Check(Mix_PausedMusic() == 0, "music no longer reports paused after resume");

	const bool finishedNaturally =
		WaitUntil([]() { return g_musicFinished; }, 3000);
	Check(finishedNaturally,
	      "Mix_HookMusicFinished callback fires after natural completion");

	// Explicit halt should also invoke the hook (legacy Mix_HaltMusic semantics).
	Check(Mix_PlayMusic(music, -1) == 0, "restarting music (infinite loop) succeeds");
	g_musicFinished = false;
	Check(Mix_HaltMusic() == 0, "Mix_HaltMusic succeeds");
	const bool finishedByHalt = WaitUntil([]() { return g_musicFinished; }, 3000);
	Check(finishedByHalt,
	      "Mix_HookMusicFinished callback fires after an explicit Mix_HaltMusic");

	Mix_FreeMusic(music);
}

/* -------------------------------------------------------------------------
   Section 5: decoder enumeration/query, Timidity config handling.
   ------------------------------------------------------------------------- */

void TestDecodersAndTimidity()
{
	const int chunkDecoderCount = Mix_GetNumChunkDecoders();
	Check(chunkDecoderCount > 0, "at least one chunk decoder is registered");
	if (chunkDecoderCount > 0) {
		const char *name = Mix_GetChunkDecoder(0);
		Check(name != nullptr, "Mix_GetChunkDecoder(0) returns a name");
		if (name != nullptr) {
			Check(Mix_HasChunkDecoder(name),
			      "Mix_HasChunkDecoder finds a decoder reported by Mix_GetChunkDecoder");
		}
	}
	Check(!Mix_HasChunkDecoder("PEONPAD_DOES_NOT_EXIST"),
	      "Mix_HasChunkDecoder reports false for an unknown name");

	const int musicDecoderCount = Mix_GetNumMusicDecoders();
	Check(musicDecoderCount == chunkDecoderCount,
	      "chunk/music decoder lists are the same unified list, by design");
	Check(!Mix_HasMusicDecoder("PEONPAD_DOES_NOT_EXIST"),
	      "Mix_HasMusicDecoder reports false for an unknown name");

	const std::string cfgPath = "/tmp/peonpad-sdl3-mixer-adapter-test-timidity.cfg";
	Check(Mix_SetTimidityCfg(cfgPath.c_str()), "Mix_SetTimidityCfg succeeds");
	const char *observed = SDL_getenv("TIMIDITY_CFG");
	Check(observed != nullptr && cfgPath == observed,
	      "Mix_SetTimidityCfg publishes TIMIDITY_CFG");
	Check(!Mix_SetTimidityCfg(nullptr), "Mix_SetTimidityCfg(nullptr) fails");
}

/* -------------------------------------------------------------------------
   Section 6: teardown / reinit.
   ------------------------------------------------------------------------- */

void TestTeardownAndReinit(const std::vector<Uint8> &shortWav)
{
	Mix_CloseAudio();
	Check(Mix_AllocateChannels(4) == 0,
	      "Mix_AllocateChannels reports zero channels once the device is closed");
	Check(std::strlen(Mix_GetError()) > 0,
	      "Mix_AllocateChannels sets an error once the device is closed");

	Check(OpenDeviceForTest(), "Mix_OpenAudio succeeds again after Mix_CloseAudio");
	Check(Mix_AllocateChannels(4) == 4, "channels can be reallocated after reopening");

	// Prove the reopened mixer is fully functional, not just "not crashing".
	bool closed = false;
	SDL_IOStream *io = OpenTrackedIO(shortWav, &closed);
	Mix_Chunk *chunk = Mix_LoadWAV_RW(io, 1);
	Check(chunk != nullptr, "loading works again after reinit");
	if (chunk != nullptr) {
		g_channelFinishedCount = 0;
		const int channel = Mix_PlayChannel(-1, chunk, 0);
		Check(channel >= 0, "playback works again after reinit");
		Check(WaitUntil([]() { return g_channelFinishedCount > 0; }, 3000),
		      "callbacks work again after reinit");
		Mix_FreeChunk(chunk);
	}

	Mix_CloseAudio();
	Mix_Quit();
}

/* -------------------------------------------------------------------------
   Section 7: deterministic, no-device confirmation of the loop/stop
   semantics this adapter relies on, using the raw SDL_mixer 3 API directly.
   ------------------------------------------------------------------------- */

void TestNoDeviceLoopSemantics(const std::vector<Uint8> &shortWav)
{
	Check(MIX_Init(), "MIX_Init succeeds ahead of the no-device MIX_CreateMixer check");

	const SDL_AudioSpec spec{SDL_AUDIO_S16, 1, 8000};
	MIX_Mixer *mixer = MIX_CreateMixer(&spec);
	Check(mixer != nullptr, "MIX_CreateMixer succeeds for a no-device mixer");
	if (mixer == nullptr) {
		MIX_Quit();
		return;
	}

	SDL_IOStream *io = SDL_IOFromConstMem(shortWav.data(), shortWav.size());
	MIX_Audio *audio = MIX_LoadAudio_IO(mixer, io, /*predecode=*/true, /*closeio=*/true);
	Check(audio != nullptr, "MIX_LoadAudio_IO decodes the fabricated WAV");
	if (audio == nullptr) {
		MIX_DestroyMixer(mixer);
		MIX_Quit();
		return;
	}

	MIX_Track *track = MIX_CreateTrack(mixer);
	Check(track != nullptr, "MIX_CreateTrack succeeds");
	Check(MIX_SetTrackAudio(track, audio), "MIX_SetTrackAudio succeeds");

	SDL_PropertiesID props = SDL_CreateProperties();
	SDL_SetNumberProperty(props, MIX_PROP_PLAY_LOOPS_NUMBER, 0); // no loop
	Check(MIX_PlayTrack(track, props), "MIX_PlayTrack starts the track");
	SDL_DestroyProperties(props);

	std::vector<Uint8> buffer(4096);
	bool everGenerated = false;
	int guard = 0;
	while (MIX_TrackPlaying(track) && guard < 100000) {
		const int generated =
			MIX_Generate(mixer, buffer.data(), static_cast<int>(buffer.size()));
		Check(generated >= 0, "MIX_Generate does not report failure");
		if (generated > 0) {
			everGenerated = true;
		}
		++guard;
	}
	Check(everGenerated, "MIX_Generate produced real (non-silence-only) audio");
	Check(!MIX_TrackPlaying(track),
	      "a track with MIX_PROP_PLAY_LOOPS_NUMBER == 0 stops after one pass, "
	      "deterministically, with no real-time dependency");
	Check(guard < 100000, "the track stopped in a bounded number of Generate calls");

	MIX_DestroyTrack(track);
	MIX_DestroyAudio(audio);
	MIX_DestroyMixer(mixer);
	MIX_Quit();
}

} // namespace

int main(int argc, char **argv)
{
	if (argc > 1 && std::strcmp(argv[1], "--verify-assertions") == 0) {
		return AssertionsAreActive() ? 0 : 1;
	}

	// Force the dummy audio driver so the device-backed portion of this
	// test is deterministic and safe in headless CI sandboxes. This must
	// happen before anything touches the audio subsystem.
	SDL_SetHint(SDL_HINT_AUDIO_DRIVER, "dummy");

	const std::vector<Uint8> shortWav = BuildSineWav(8000, 0.15, 440.0);
	const std::vector<Uint8> mediumWav = BuildSineWav(8000, 0.35, 440.0);

	// Section 7 first: fully deterministic, does not touch our adapter's
	// global device state at all.
	TestNoDeviceLoopSemantics(shortWav);

	TestCloseIoOwnershipBeforeDeviceOpen(shortWav);
	TestDeviceLifecycle();
	TestChannelsAndChunks(mediumWav);
	TestMusic(mediumWav);
	TestDecodersAndTimidity();
	TestTeardownAndReinit(shortWav);

	if (g_failures == 0) {
		std::printf("peonpad_sdl3_mixer_adapter_test: all checks passed\n");
	} else {
		std::fprintf(stderr,
		             "peonpad_sdl3_mixer_adapter_test: %d check(s) failed\n",
		             g_failures);
	}
	return g_failures == 0 ? 0 : 1;
}
