#define SDL_MAIN_USE_CALLBACKS 1
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3_image/SDL_image.h>
#include <SDL3_mixer/SDL_mixer.h>

#ifdef __APPLE__
#include "PeonPadSDL3Window.h"
#endif
#ifdef PEONPAD_VISIONOS
#include "PeonPadVisionOSShell.h"
#endif

#include <cstdio>
#include <cstring>
#include <string>

namespace
{

struct SmokeState
{
	SDL_Window *Window = nullptr;
	SDL_Renderer *Renderer = nullptr;
	SDL_Surface *RenderSurface = nullptr;
	SDL_Texture *Texture = nullptr;
	SDL_Texture *Canvas = nullptr;
	MIX_Mixer *Mixer = nullptr;
	MIX_Audio *Audio = nullptr;
	MIX_Track *Track = nullptr;
	PeonPadViewportState Viewport{};
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

#ifdef PEONPAD_VISIONOS
std::string BundleFixturePath(const char *basePath, const char *name)
{
	std::string path = basePath ? basePath : "";
	if (!path.empty() && path.back() != '/') {
		path.push_back('/');
	}
	path += name;
	return path;
}

bool DrawVisionShellCanvas(SmokeState &state)
{
	const SDL_FRect sampleRect{48.0f, 64.0f, 128.0f, 128.0f};
	const SDL_FRect panelRect{208.0f, 64.0f, 384.0f, 128.0f};
	const SDL_FRect footerRect{48.0f, 224.0f, 544.0f, 208.0f};
	bool result = SDL_SetRenderTarget(state.Renderer, state.Canvas);
	result = result
	    && SDL_SetRenderDrawColor(state.Renderer, 13, 23, 38, 255)
	    && SDL_RenderClear(state.Renderer)
	    && SDL_RenderTexture(
		    state.Renderer, state.Texture, nullptr, &sampleRect)
	    && SDL_SetRenderDrawColor(state.Renderer, 24, 52, 72, 255)
	    && SDL_RenderFillRect(state.Renderer, &panelRect)
	    && SDL_SetRenderDrawColor(state.Renderer, 18, 34, 49, 255)
	    && SDL_RenderFillRect(state.Renderer, &footerRect)
	    && SDL_SetRenderDrawColor(state.Renderer, 106, 211, 176, 255)
	    && SDL_RenderRect(state.Renderer, &sampleRect)
	    && SDL_RenderRect(state.Renderer, &panelRect)
	    && SDL_RenderRect(state.Renderer, &footerRect)
	    && SDL_SetRenderScale(state.Renderer, 2.0f, 2.0f)
	    && SDL_SetRenderDrawColor(state.Renderer, 235, 245, 238, 255)
	    && SDL_RenderDebugText(state.Renderer, 116.0f, 44.0f,
	                           "PEONPAD VISIONOS")
	    && SDL_SetRenderDrawColor(state.Renderer, 106, 211, 176, 255)
	    && SDL_RenderDebugText(state.Renderer, 116.0f, 62.0f,
	                           "NATIVE SDL3 + METAL")
	    && SDL_SetRenderDrawColor(state.Renderer, 235, 245, 238, 255)
	    && SDL_RenderDebugText(state.Renderer, 36.0f, 128.0f,
	                           "RESIZABLE 4:3 ASPECT FIT")
	    && SDL_SetRenderDrawColor(state.Renderer, 255, 190, 92, 255)
	    && SDL_RenderDebugText(state.Renderer, 42.0f, 166.0f,
	                           "SMOKE SHELL - NO GAMEPLAY")
	    && SDL_SetRenderScale(state.Renderer, 1.0f, 1.0f);
	const bool reset = SDL_SetRenderTarget(state.Renderer, nullptr);
	return result && reset;
}

bool RefreshVisionViewport(SmokeState &state)
{
	int pointWidth = 0;
	int pointHeight = 0;
	int outputWidth = 0;
	int outputHeight = 0;
	SDL_Rect safeArea{};
	if (!SDL_GetWindowSize(state.Window, &pointWidth, &pointHeight)
	    || !SDL_GetWindowSizeInPixels(
		    state.Window, &outputWidth, &outputHeight)
	    || !SDL_GetWindowSafeArea(state.Window, &safeArea)
	    || !PeonPadRefreshViewportState(
		    pointWidth, pointHeight, outputWidth, outputHeight,
		    {safeArea.x, safeArea.y, safeArea.w, safeArea.h},
		    640, 480, state.Viewport)) {
		return false;
	}
	return true;
}

bool EnsureVisionViewportCurrent(SmokeState &state)
{
	return !state.Viewport.geometryDirty
	    ? state.Viewport.valid
	    : RefreshVisionViewport(state);
}

bool RenderVisionShell(SmokeState &state)
{
	if (!EnsureVisionViewportCurrent(state)) {
		return false;
	}

	const SDL_FRect destination{
		static_cast<float>(state.Viewport.viewport.x),
		static_cast<float>(state.Viewport.viewport.y),
		static_cast<float>(state.Viewport.viewport.width),
		static_cast<float>(state.Viewport.viewport.height),
	};
	if (!SDL_SetRenderDrawColor(state.Renderer, 0, 0, 0, 255)
	    || !SDL_RenderClear(state.Renderer)
	    || !SDL_RenderTexture(
		    state.Renderer, state.Canvas, nullptr, &destination)
	    || !SDL_RenderPresent(state.Renderer)) {
		return false;
	}
	PeonPadMarkViewportRendered(state.Viewport);
	return true;
}
#endif

} // namespace

SDL_AppResult SDL_AppInit(void **appstate, int argc, char **argv)
{
	if (SDL_GetVersion() != SDL_VERSION ||
	    IMG_Version() != SDL_IMAGE_VERSION ||
	    MIX_Version() != SDL_MIXER_VERSION) {
		return Fail("version lock");
	}
#ifdef PEONPAD_VISIONOS
	if (!SDL_SetAppMetadata("PeonPad Vision Shell", "0.1",
	                        PEONPAD_VISIONOS_BUNDLE_IDENTIFIER)) {
#else
	if (!SDL_SetAppMetadata("PeonPad SDL3 Foundation", "0.1",
	                        "org.peonpad.sdl3-foundation")) {
#endif
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
#ifdef PEONPAD_SDL3_BUNDLED_FIXTURES
	const std::string audioPath =
		BundleFixturePath(basePath, PEONPAD_SDL3_AUDIO_FIXTURE);
	const std::string imagePath =
		BundleFixturePath(basePath, PEONPAD_SDL3_IMAGE_FIXTURE);
	state->Audio = MIX_LoadAudio(state->Mixer, audioPath.c_str(), true);
#else
	state->Audio = MIX_LoadAudio(
		state->Mixer, PEONPAD_SDL3_AUDIO_FIXTURE, true);
#endif
	state->Track = state->Audio ? MIX_CreateTrack(state->Mixer) : nullptr;
	if (!state->Track || !MIX_SetTrackAudio(state->Track, state->Audio) ||
	    !MIX_PlayTrack(state->Track, 0)) {
		return Fail("SDL_mixer decode/play");
	}
	float audioFrames[512]{};
	if (MIX_Generate(state->Mixer, audioFrames, sizeof(audioFrames)) <= 0) {
		return Fail("MIX_Generate");
	}

#ifdef PEONPAD_SDL3_BUNDLED_FIXTURES
	SDL_Surface *image = IMG_Load(imagePath.c_str());
#else
	SDL_Surface *image = IMG_Load(PEONPAD_SDL3_IMAGE_FIXTURE);
#endif
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
	}
#ifdef PEONPAD_VISIONOS
	else {
		state->Window = SDL_CreateWindow(
			"PeonPad Vision Shell", 960, 720,
			SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_RESIZABLE);
		state->Renderer = state->Window
			? SDL_CreateRenderer(state->Window, "metal")
			: nullptr;
		if (!state->Renderer) {
			return Fail("visionOS SDL3 Metal window");
		}
	}
#else
	else if (!SDL_CreateWindowAndRenderer(
		         "PeonPad SDL3 Foundation", 640, 480,
		         SDL_WINDOW_HIDDEN, &state->Window, &state->Renderer)) {
		return Fail("SDL_CreateWindowAndRenderer");
	}
#endif
	if (!state->Renderer) {
		return Fail("SDL renderer creation");
	}
#ifndef PEONPAD_VISIONOS
	if (!SDL_SetRenderLogicalPresentation(
		    state->Renderer, 640, 480, SDL_LOGICAL_PRESENTATION_LETTERBOX)) {
		return Fail("SDL_SetRenderLogicalPresentation");
	}
#endif

	state->Texture = SDL_CreateTexture(
		state->Renderer, SDL_PIXELFORMAT_ARGB8888,
		SDL_TEXTUREACCESS_STREAMING, 2, 2);
	const Uint32 pixels[] = {
		0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff
	};
	if (!state->Texture
	    || !SDL_UpdateTexture(
		    state->Texture, nullptr, pixels, 2 * sizeof(Uint32))) {
		return Fail("SDL renderer/texture path");
	}
#ifdef PEONPAD_VISIONOS
	state->Canvas = SDL_CreateTexture(
		state->Renderer, SDL_PIXELFORMAT_ARGB8888,
		SDL_TEXTUREACCESS_TARGET, 640, 480);
	if (!state->Canvas || !DrawVisionShellCanvas(*state)
	    || !PeonPadVisionOSConfigureShell(
		    state->Window, state->Renderer)
	    || !RenderVisionShell(*state)) {
		return Fail("visionOS shell rendering");
	}
#else
	if (!SDL_SetRenderDrawColor(state->Renderer, 0, 0, 0, 255)
	    || !SDL_RenderClear(state->Renderer)
	    || !SDL_RenderTexture(
		    state->Renderer, state->Texture, nullptr, nullptr)
	    || !SDL_RenderPresent(state->Renderer)) {
		return Fail("SDL renderer/texture path");
	}
#endif

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
#ifdef PEONPAD_VISIONOS
	SDL_Log("PeonPad native visionOS smoke shell ready: "
	        "resizable 4:3 aspect-fit; no playable gameplay");
#endif
	return SDL_APP_CONTINUE;
}

SDL_AppResult SDL_AppEvent(void *appstate, SDL_Event *event)
{
	auto *state = static_cast<SmokeState *>(appstate);
	switch (event->type) {
		case SDL_EVENT_QUIT:
		case SDL_EVENT_TERMINATING:
			return SDL_APP_SUCCESS;
		case SDL_EVENT_WILL_ENTER_BACKGROUND:
		case SDL_EVENT_DID_ENTER_BACKGROUND:
			return SDL_APP_CONTINUE;
#ifdef PEONPAD_VISIONOS
		case SDL_EVENT_WINDOW_RESIZED:
		case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
		case SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED:
		case SDL_EVENT_WINDOW_SAFE_AREA_CHANGED:
			if (state) {
				PeonPadInvalidateViewport(state->Viewport);
			}
			return SDL_APP_CONTINUE;
		case SDL_EVENT_MOUSE_MOTION:
		case SDL_EVENT_MOUSE_BUTTON_DOWN:
		case SDL_EVENT_MOUSE_BUTTON_UP:
			if (state && state->Window) {
				if (!EnsureVisionViewportCurrent(*state)) {
					return SDL_APP_CONTINUE;
				}
				const float x = event->type == SDL_EVENT_MOUSE_MOTION
					? event->motion.x : event->button.x;
				const float y = event->type == SDL_EVENT_MOUSE_MOTION
					? event->motion.y : event->button.y;
				PeonPadViewportPoint logicalPoint;
				PeonPadSDL3MapWindowPointToLogical(
					state->Window, state->Viewport, x, y, logicalPoint);
			}
			return SDL_APP_CONTINUE;
		case SDL_EVENT_FINGER_DOWN:
		case SDL_EVENT_FINGER_MOTION:
		case SDL_EVENT_FINGER_UP:
		case SDL_EVENT_FINGER_CANCELED:
			if (state && state->Window) {
				if (!EnsureVisionViewportCurrent(*state)) {
					return SDL_APP_CONTINUE;
				}
				int width = 0;
				int height = 0;
				if (!SDL_GetWindowSize(state->Window, &width, &height)
				    || width <= 0 || height <= 0) {
					return SDL_APP_CONTINUE;
				}
				PeonPadViewportPoint logicalPoint;
				PeonPadSDL3MapWindowPointToLogical(
					state->Window, state->Viewport,
					event->tfinger.x * width,
					event->tfinger.y * height, logicalPoint);
			}
			return SDL_APP_CONTINUE;
#endif
		default:
			return SDL_APP_CONTINUE;
	}
}

SDL_AppResult SDL_AppIterate(void *appstate)
{
#ifdef PEONPAD_VISIONOS
	auto *state = static_cast<SmokeState *>(appstate);
	if (state && state->Viewport.renderDirty && !RenderVisionShell(*state)) {
		return Fail("visionOS resize rendering");
	}
	return SDL_APP_CONTINUE;
#else
	(void)appstate;
	return SDL_APP_SUCCESS;
#endif
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
	if (state->Canvas) {
		SDL_DestroyTexture(state->Canvas);
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
