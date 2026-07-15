#define SDL_MAIN_USE_CALLBACKS 1
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3_image/SDL_image.h>
#include <SDL3_mixer/SDL_mixer.h>

#ifdef __APPLE__
#include "PeonPadSDL3Window.h"
#endif

#include <cstdio>
#include <cstring>

namespace
{

struct SmokeState
{
	SDL_Window *Window = nullptr;
	SDL_Renderer *Renderer = nullptr;
	SDL_Surface *RenderSurface = nullptr;
	SDL_Texture *Texture = nullptr;
	MIX_Mixer *Mixer = nullptr;
	MIX_Audio *Audio = nullptr;
	MIX_Track *Track = nullptr;
	bool Headless = false;
};

SDL_AppResult Fail(const char *operation)
{
	std::fprintf(stderr, "%s failed: %s\n", operation, SDL_GetError());
	return SDL_APP_FAILURE;
}

bool HasArgument(int argc, char **argv, const char *wanted)
{
	for (int index = 1; index < argc; ++index) {
		if (std::strcmp(argv[index], wanted) == 0) {
			return true;
		}
	}
	return false;
}

} // namespace

SDL_AppResult SDL_AppInit(void **appstate, int argc, char **argv)
{
	if (SDL_GetVersion() != SDL_VERSION ||
	    IMG_Version() != SDL_IMAGE_VERSION ||
	    MIX_Version() != SDL_MIXER_VERSION) {
		return Fail("version lock");
	}
	if (!SDL_SetAppMetadata("PeonPad SDL3 Foundation", "0.1",
	                        "org.peonpad.sdl3-foundation")) {
		return Fail("SDL_SetAppMetadata");
	}

	auto *state = new SmokeState;
	*appstate = state;
	state->Headless = HasArgument(argc, argv, "--headless");

	if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO | SDL_INIT_GAMEPAD)) {
		return Fail("SDL_Init");
	}

	const char *basePath = SDL_GetBasePath();
	char *prefPath = SDL_GetPrefPath("PeonPad", "SDL3Foundation");
	if (!basePath || !prefPath) {
		SDL_free(prefPath);
		return Fail("SDL filesystem paths");
	}
	SDL_free(prefPath);

	if (!MIX_Init()) {
		return Fail("MIX_Init");
	}
	const SDL_AudioSpec audioSpec{SDL_AUDIO_F32, 2, 48000};
	state->Mixer = MIX_CreateMixer(&audioSpec);
	if (!state->Mixer) {
		return Fail("MIX_CreateMixer");
	}
	state->Audio = MIX_LoadAudio(state->Mixer, PEONPAD_SDL3_AUDIO_FIXTURE, true);
	state->Track = state->Audio ? MIX_CreateTrack(state->Mixer) : nullptr;
	if (!state->Track || !MIX_SetTrackAudio(state->Track, state->Audio) ||
	    !MIX_PlayTrack(state->Track, 0)) {
		return Fail("SDL_mixer decode/play");
	}
	float audioFrames[512]{};
	if (MIX_Generate(state->Mixer, audioFrames, sizeof(audioFrames)) <= 0) {
		return Fail("MIX_Generate");
	}

	SDL_Surface *image = IMG_Load(PEONPAD_SDL3_IMAGE_FIXTURE);
	if (!image || image->w <= 0 || image->h <= 0) {
		SDL_DestroySurface(image);
		return Fail("IMG_Load");
	}
	SDL_DestroySurface(image);

	if (state->Headless) {
		state->RenderSurface =
			SDL_CreateSurface(640, 480, SDL_PIXELFORMAT_ARGB8888);
		state->Renderer = state->RenderSurface
			? SDL_CreateSoftwareRenderer(state->RenderSurface)
			: nullptr;
	} else if (!SDL_CreateWindowAndRenderer(
		           "PeonPad SDL3 Foundation", 640, 480,
		           SDL_WINDOW_HIDDEN, &state->Window, &state->Renderer)) {
		return Fail("SDL_CreateWindowAndRenderer");
	}
	if (!state->Renderer) {
		return Fail("SDL renderer creation");
	}
	if (!SDL_SetRenderLogicalPresentation(
		    state->Renderer, 640, 480, SDL_LOGICAL_PRESENTATION_LETTERBOX)) {
		return Fail("SDL_SetRenderLogicalPresentation");
	}

	state->Texture = SDL_CreateTexture(
		state->Renderer, SDL_PIXELFORMAT_ARGB8888,
		SDL_TEXTUREACCESS_STREAMING, 2, 2);
	const Uint32 pixels[] = {
		0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff
	};
	if (!state->Texture ||
	    !SDL_UpdateTexture(state->Texture, nullptr, pixels, 2 * sizeof(Uint32)) ||
	    !SDL_SetRenderDrawColor(state->Renderer, 0, 0, 0, 255) ||
	    !SDL_RenderClear(state->Renderer) ||
	    !SDL_RenderTexture(state->Renderer, state->Texture, nullptr, nullptr) ||
	    !SDL_RenderPresent(state->Renderer)) {
		return Fail("SDL renderer/texture path");
	}

	if (state->Window) {
		int width = 0;
		int height = 0;
		if (!SDL_GetWindowSizeInPixels(state->Window, &width, &height) ||
		    width <= 0 || height <= 0 ||
		    !SDL_StartTextInput(state->Window) ||
		    !SDL_StopTextInput(state->Window)) {
			return Fail("SDL window/text path");
		}
#ifdef __APPLE__
		if (!PeonPadSDL3GetNativeWindow(state->Window)) {
			return Fail("SDL3 Apple window property");
		}
#endif
	}

	int gamepadCount = 0;
	SDL_JoystickID *gamepads = SDL_GetGamepads(&gamepadCount);
	if (!gamepads && gamepadCount != 0) {
		return Fail("SDL_GetGamepads");
	}
	for (int index = 0; index < gamepadCount; ++index) {
		if (SDL_Gamepad *gamepad = SDL_OpenGamepad(gamepads[index])) {
			SDL_CloseGamepad(gamepad);
		}
	}
	SDL_free(gamepads);

	std::printf("SDL3 foundation: core=%d image=%d mixer=%d renderer=%s\n",
	            SDL_GetVersion(), IMG_Version(), MIX_Version(),
	            SDL_GetRendererName(state->Renderer));
	return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppEvent(void *, SDL_Event *event)
{
	switch (event->type) {
		case SDL_EVENT_QUIT:
		case SDL_EVENT_TERMINATING:
			return SDL_APP_SUCCESS;
		case SDL_EVENT_WILL_ENTER_BACKGROUND:
		case SDL_EVENT_DID_ENTER_BACKGROUND:
			return SDL_APP_CONTINUE;
		default:
			return SDL_APP_CONTINUE;
	}
}

SDL_AppResult SDL_AppIterate(void *)
{
	return SDL_APP_SUCCESS;
}

void SDL_AppQuit(void *appstate, SDL_AppResult)
{
	auto *state = static_cast<SmokeState *>(appstate);
	if (!state) {
		return;
	}
	if (state->Track) {
		MIX_DestroyTrack(state->Track);
	}
	if (state->Audio) {
		MIX_DestroyAudio(state->Audio);
	}
	if (state->Mixer) {
		MIX_DestroyMixer(state->Mixer);
	}
	MIX_Quit();
	if (state->Texture) {
		SDL_DestroyTexture(state->Texture);
	}
	if (state->Renderer) {
		SDL_DestroyRenderer(state->Renderer);
	}
	if (state->RenderSurface) {
		SDL_DestroySurface(state->RenderSurface);
	}
	if (state->Window) {
		SDL_DestroyWindow(state->Window);
	}
	SDL_Quit();
	delete state;
}
