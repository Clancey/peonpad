#pragma once

#include <SDL.h>

#include <algorithm>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

struct SdlCompatPixelFormatDetails
{
	int BitsPerPixel = 0;
	int BytesPerPixel = 0;
	Uint32 Rmask = 0;
	Uint32 Gmask = 0;
	Uint32 Bmask = 0;
	Uint32 Amask = 0;
	Uint8 Rshift = 0;
	Uint8 Gshift = 0;
	Uint8 Bshift = 0;
	Uint8 Ashift = 0;
};

inline bool SdlCompatWriteReadinessMarker(FILE *stream)
{
	if (stream == nullptr) {
		SDL_SetError("Readiness marker requires an output stream");
		return false;
	}
	if (std::fputs("PEONPAD_ENGINE_READY\n", stream) == EOF
	    || std::fflush(stream) != 0) {
		SDL_SetError("Unable to write and flush the engine readiness marker");
		return false;
	}
	return true;
}

inline std::string SdlCompatGetBasePath()
{
#ifdef PEONPAD_USE_SDL3
	const char *path = SDL_GetBasePath();
	return path != nullptr ? path : "";
#else
	char *path = SDL_GetBasePath();
	const std::string result = path != nullptr ? path : "";
	SDL_free(path);
	return result;
#endif
}

inline Uint32 SdlCompatSurfaceFormat(const SDL_Surface *surface)
{
#ifdef PEONPAD_USE_SDL3
	return static_cast<Uint32>(surface->format);
#else
	return surface->format->format;
#endif
}

inline SdlCompatPixelFormatDetails
SdlCompatGetPixelFormatDetails(const SDL_Surface *surface)
{
	SdlCompatPixelFormatDetails result;
#ifdef PEONPAD_USE_SDL3
	const SDL_PixelFormatDetails *details =
		SDL_GetPixelFormatDetails(surface->format);
	if (details != nullptr) {
		result.BitsPerPixel = details->bits_per_pixel;
		result.BytesPerPixel = details->bytes_per_pixel;
		result.Rmask = details->Rmask;
		result.Gmask = details->Gmask;
		result.Bmask = details->Bmask;
		result.Amask = details->Amask;
		result.Rshift = details->Rshift;
		result.Gshift = details->Gshift;
		result.Bshift = details->Bshift;
		result.Ashift = details->Ashift;
	}
#else
	result.BitsPerPixel = surface->format->BitsPerPixel;
	result.BytesPerPixel = surface->format->BytesPerPixel;
	result.Rmask = surface->format->Rmask;
	result.Gmask = surface->format->Gmask;
	result.Bmask = surface->format->Bmask;
	result.Amask = surface->format->Amask;
	result.Rshift = surface->format->Rshift;
	result.Gshift = surface->format->Gshift;
	result.Bshift = surface->format->Bshift;
	result.Ashift = surface->format->Ashift;
#endif
	return result;
}

inline SDL_Palette *SdlCompatGetSurfacePalette(SDL_Surface *surface)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_GetSurfacePalette(surface);
#else
	return surface->format->palette;
#endif
}

inline bool SdlCompatSurfaceHasFormat(const SDL_Surface *surface)
{
#ifdef PEONPAD_USE_SDL3
	return surface != nullptr && surface->format != SDL_PIXELFORMAT_UNKNOWN;
#else
	return surface != nullptr && surface->format != nullptr;
#endif
}

inline bool SdlCompatSurfaceUsesPreallocatedPixels(const SDL_Surface *surface)
{
#ifdef PEONPAD_USE_SDL3
	return (surface->flags & SDL_SURFACE_PREALLOCATED) != 0;
#else
	return (surface->flags & SDL_PREALLOC) != 0;
#endif
}

inline bool SdlCompatGetColorKey(SDL_Surface *surface, Uint32 *colorKey)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_GetSurfaceColorKey(surface, colorKey);
#else
	return SDL_GetColorKey(surface, colorKey) == 0;
#endif
}

inline bool
SdlCompatSetColorKey(SDL_Surface *surface, bool enabled, Uint32 colorKey)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_SetSurfaceColorKey(surface, enabled, colorKey);
#else
	return SDL_SetColorKey(surface, enabled ? SDL_TRUE : SDL_FALSE, colorKey) == 0;
#endif
}

inline Uint32 SdlCompatMapRGB(SDL_Surface *surface, Uint8 r, Uint8 g, Uint8 b)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_MapSurfaceRGB(surface, r, g, b);
#else
	return SDL_MapRGB(surface->format, r, g, b);
#endif
}

inline Uint32
SdlCompatMapRGBA(SDL_Surface *surface, Uint8 r, Uint8 g, Uint8 b, Uint8 a)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_MapSurfaceRGBA(surface, r, g, b, a);
#else
	return SDL_MapRGBA(surface->format, r, g, b, a);
#endif
}

inline void SdlCompatGetRGB(SDL_Surface *surface, Uint32 pixel,
                            Uint8 *r, Uint8 *g, Uint8 *b)
{
#ifdef PEONPAD_USE_SDL3
	SDL_GetRGB(pixel, SDL_GetPixelFormatDetails(surface->format),
	           SDL_GetSurfacePalette(surface), r, g, b);
#else
	SDL_GetRGB(pixel, surface->format, r, g, b);
#endif
}

inline void SdlCompatGetRGBA(SDL_Surface *surface, Uint32 pixel,
                             Uint8 *r, Uint8 *g, Uint8 *b, Uint8 *a)
{
#ifdef PEONPAD_USE_SDL3
	SDL_GetRGBA(pixel, SDL_GetPixelFormatDetails(surface->format),
	            SDL_GetSurfacePalette(surface), r, g, b, a);
#else
	SDL_GetRGBA(pixel, surface->format, r, g, b, a);
#endif
}

inline Uint32 SdlCompatPixelFormatForMasks(int bitsPerPixel,
                                           Uint32 rmask, Uint32 gmask,
                                           Uint32 bmask, Uint32 amask)
{
#ifdef PEONPAD_USE_SDL3
	return static_cast<Uint32>(SDL_GetPixelFormatForMasks(
		bitsPerPixel, rmask, gmask, bmask, amask));
#else
	return SDL_MasksToPixelFormatEnum(
		bitsPerPixel, rmask, gmask, bmask, amask);
#endif
}

inline SDL_Surface *SdlCompatCreateSurface(int width, int height,
                                           int bitsPerPixel,
                                           Uint32 rmask, Uint32 gmask,
                                           Uint32 bmask, Uint32 amask)
{
#ifdef PEONPAD_USE_SDL3
	const SDL_PixelFormat format = SDL_GetPixelFormatForMasks(
		bitsPerPixel, rmask, gmask, bmask, amask);
	if (format == SDL_PIXELFORMAT_UNKNOWN) {
		SDL_SetError("Unsupported %d-bit surface masks", bitsPerPixel);
		return nullptr;
	}
	SDL_Surface *surface = SDL_CreateSurface(width, height, format);
	if (surface != nullptr && SDL_ISPIXELFORMAT_INDEXED(format)
	    && SDL_CreateSurfacePalette(surface) == nullptr) {
		SDL_DestroySurface(surface);
		return nullptr;
	}
	return surface;
#else
	return SDL_CreateRGBSurface(
		0, width, height, bitsPerPixel, rmask, gmask, bmask, amask);
#endif
}

inline SDL_Surface *SdlCompatCreateSurfaceFrom(
	void *pixels, int width, int height, int bitsPerPixel, int pitch,
	Uint32 rmask, Uint32 gmask, Uint32 bmask, Uint32 amask)
{
#ifdef PEONPAD_USE_SDL3
	const SDL_PixelFormat format = SDL_GetPixelFormatForMasks(
		bitsPerPixel, rmask, gmask, bmask, amask);
	if (format == SDL_PIXELFORMAT_UNKNOWN) {
		SDL_SetError("Unsupported %d-bit surface masks", bitsPerPixel);
		return nullptr;
	}
	SDL_Surface *surface =
		SDL_CreateSurfaceFrom(width, height, format, pixels, pitch);
	if (surface != nullptr && SDL_ISPIXELFORMAT_INDEXED(format)
	    && SDL_CreateSurfacePalette(surface) == nullptr) {
		SDL_DestroySurface(surface);
		return nullptr;
	}
	return surface;
#else
	return SDL_CreateRGBSurfaceFrom(
		pixels, width, height, bitsPerPixel, pitch,
		rmask, gmask, bmask, amask);
#endif
}

inline SDL_Surface *SdlCompatConvertSurface(SDL_Surface *surface, Uint32 format)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_ConvertSurface(surface, static_cast<SDL_PixelFormat>(format));
#else
	return SDL_ConvertSurfaceFormat(surface, format, 0);
#endif
}

inline SDL_Surface *SdlCompatDuplicateSurface(SDL_Surface *surface)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_DuplicateSurface(surface);
#else
	return SDL_ConvertSurface(surface, surface->format, 0);
#endif
}

inline bool SdlCompatBlitScaled(SDL_Surface *source,
                                const SDL_Rect *sourceRect,
                                SDL_Surface *destination,
                                const SDL_Rect *destinationRect)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_BlitSurfaceScaled(source, sourceRect, destination,
	                             destinationRect, SDL_SCALEMODE_NEAREST);
#else
	SDL_Rect mutableDestination;
	SDL_Rect *destinationPointer = nullptr;
	if (destinationRect != nullptr) {
		mutableDestination = *destinationRect;
		destinationPointer = &mutableDestination;
	}
	return SDL_BlitScaled(
		source, sourceRect, destination, destinationPointer) == 0;
#endif
}

inline bool SdlCompatBlitSurface(SDL_Surface *source,
                                 const SDL_Rect *sourceRect,
                                 SDL_Surface *destination,
                                 SDL_Rect *destinationRect)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_BlitSurface(
		source, sourceRect, destination, destinationRect);
#else
	return SDL_BlitSurface(
		source, sourceRect, destination, destinationRect) == 0;
#endif
}

inline SDL_Keycode SdlCompatEventKeycode(const SDL_Event &event)
{
#ifdef PEONPAD_USE_SDL3
	return event.key.key;
#else
	return event.key.keysym.sym;
#endif
}

inline SDL_Keymod SdlCompatEventKeymod(const SDL_Event &event)
{
#ifdef PEONPAD_USE_SDL3
	return event.key.mod;
#else
	return static_cast<SDL_Keymod>(event.key.keysym.mod);
#endif
}

inline void SdlCompatSetEventKeycode(SDL_Event &event, SDL_Keycode keycode)
{
#ifdef PEONPAD_USE_SDL3
	event.key.key = keycode;
#else
	event.key.keysym.sym = keycode;
#endif
}

inline bool SdlCompatIsWindowEvent(const SDL_Event &event, Uint32 eventType)
{
#ifdef PEONPAD_USE_SDL3
	return event.type == eventType;
#else
	return event.type == SDL_WINDOWEVENT && event.window.event == eventType;
#endif
}

inline bool SdlCompatSetEnvironmentVariable(const char *name,
                                            const char *value,
                                            bool overwrite)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_setenv_unsafe(name, value, overwrite ? 1 : 0) == 0;
#else
	return SDL_setenv(name, value, overwrite ? 1 : 0) == 0;
#endif
}

inline bool SdlCompatInitCore()
{
#ifdef PEONPAD_USE_SDL3
	return SDL_Init(SDL_INIT_AUDIO | SDL_INIT_VIDEO | SDL_INIT_EVENTS);
#else
	return SDL_Init(
		SDL_INIT_AUDIO | SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_TIMER) == 0;
#endif
}

inline bool SdlCompatRegisterUserEvent(Uint32 *eventType)
{
	const Uint32 registered = SDL_RegisterEvents(1);
#ifdef PEONPAD_USE_SDL3
	if (registered == 0) {
#else
	if (registered == static_cast<Uint32>(-1)) {
#endif
		return false;
	}
	*eventType = registered;
	return true;
}

inline Uint32 SdlCompatTicks()
{
	return static_cast<Uint32>(SDL_GetTicks());
}

inline const SDL_ControllerAxisEvent &
SdlCompatControllerAxisEvent(const SDL_Event &event)
{
#ifdef PEONPAD_USE_SDL3
	return event.gaxis;
#else
	return event.caxis;
#endif
}

inline const SDL_ControllerButtonEvent &
SdlCompatControllerButtonEvent(const SDL_Event &event)
{
#ifdef PEONPAD_USE_SDL3
	return event.gbutton;
#else
	return event.cbutton;
#endif
}

inline bool SdlCompatStartTextInput(SDL_Window *window)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_StartTextInput(window);
#else
	(void)window;
	SDL_StartTextInput();
	return true;
#endif
}

inline bool SdlCompatStopTextInput(SDL_Window *window)
{
#ifdef PEONPAD_USE_SDL3
	return window == nullptr || SDL_StopTextInput(window);
#else
	(void)window;
	SDL_StopTextInput();
	return true;
#endif
}

inline bool SdlCompatInitGameControllers()
{
#ifdef PEONPAD_USE_SDL3
	if (SDL_WasInit(SDL_INIT_GAMEPAD) == 0
	    && !SDL_InitSubSystem(SDL_INIT_GAMEPAD)) {
		return false;
	}
	SDL_SetGamepadEventsEnabled(true);
	return true;
#else
	if (SDL_WasInit(SDL_INIT_GAMECONTROLLER) == 0
	    && SDL_InitSubSystem(SDL_INIT_GAMECONTROLLER) < 0) {
		return false;
	}
	SDL_GameControllerEventState(SDL_ENABLE);
	return true;
#endif
}

inline std::vector<SDL_JoystickID> SdlCompatGetGameControllerDevices()
{
	std::vector<SDL_JoystickID> devices;
#ifdef PEONPAD_USE_SDL3
	int count = 0;
	SDL_JoystickID *identifiers = SDL_GetGamepads(&count);
	if (identifiers == nullptr) {
		return devices;
	}
	devices.assign(identifiers, identifiers + count);
	SDL_free(identifiers);
#else
	const int count = SDL_NumJoysticks();
	for (int index = 0; index < count; ++index) {
		if (SDL_IsGameController(index)) {
			devices.push_back(index);
		}
	}
#endif
	return devices;
}

inline SDL_GameController *
SdlCompatOpenGameController(SDL_JoystickID device)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_OpenGamepad(device);
#else
	return SDL_IsGameController(device) ? SDL_GameControllerOpen(device) : nullptr;
#endif
}

inline SDL_JoystickID
SdlCompatGameControllerInstanceId(SDL_GameController *controller)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_GetGamepadID(controller);
#else
	return SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(controller));
#endif
}

inline bool SdlCompatJoystickIdIsValid(SDL_JoystickID identifier)
{
#ifdef PEONPAD_USE_SDL3
	return identifier != 0
		&& identifier <= static_cast<SDL_JoystickID>(
			std::numeric_limits<int>::max());
#else
	return identifier >= 0;
#endif
}

inline const char *
SdlCompatGameControllerName(SDL_GameController *controller)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_GetGamepadName(controller);
#else
	return SDL_GameControllerName(controller);
#endif
}

inline void SdlCompatCloseGameController(SDL_GameController *controller)
{
#ifdef PEONPAD_USE_SDL3
	SDL_CloseGamepad(controller);
#else
	SDL_GameControllerClose(controller);
#endif
}

inline int SdlCompatMaximumDisplayRefreshRate()
{
	int maximum = 0;
#ifdef PEONPAD_USE_SDL3
	int count = 0;
	SDL_DisplayID *displays = SDL_GetDisplays(&count);
	if (displays == nullptr) {
		return 0;
	}
	for (int index = 0; index < count; ++index) {
		const SDL_DisplayMode *mode =
			SDL_GetDesktopDisplayMode(displays[index]);
		if (mode != nullptr) {
			maximum = std::max(
				maximum, static_cast<int>(mode->refresh_rate + 0.5f));
		}
	}
	SDL_free(displays);
#else
	const int count = SDL_GetNumVideoDisplays();
	for (int index = 0; index < count; ++index) {
		SDL_DisplayMode mode;
		if (SDL_GetDesktopDisplayMode(index, &mode) == 0) {
			maximum = std::max(maximum, mode.refresh_rate);
		}
	}
#endif
	return maximum;
}

inline bool SdlCompatSetSwapInterval(int interval)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_GL_SetSwapInterval(interval);
#else
	return SDL_GL_SetSwapInterval(interval) == 0;
#endif
}

inline SDL_Window *SdlCompatCreateWindow(const char *title, int x, int y,
                                         int width, int height, Uint64 flags)
{
#ifdef PEONPAD_USE_SDL3
	SDL_Window *window = SDL_CreateWindow(
		title, width, height, static_cast<SDL_WindowFlags>(flags));
	if (window != nullptr && x != SDL_WINDOWPOS_UNDEFINED
	    && y != SDL_WINDOWPOS_UNDEFINED
	    && !SDL_SetWindowPosition(window, x, y)) {
		SDL_DestroyWindow(window);
		return nullptr;
	}
	return window;
#else
	return SDL_CreateWindow(
		title, x, y, width, height, static_cast<Uint32>(flags));
#endif
}

inline SDL_Renderer *
SdlCompatCreateRenderer(SDL_Window *window, bool verticalSync)
{
#ifdef PEONPAD_USE_SDL3
	SDL_Renderer *renderer = SDL_CreateRenderer(window, nullptr);
	if (renderer != nullptr && verticalSync
	    && !SDL_SetRenderVSync(renderer, 1)) {
		SDL_DestroyRenderer(renderer);
		return nullptr;
	}
	return renderer;
#else
	Uint32 flags = SDL_RENDERER_ACCELERATED | SDL_RENDERER_TARGETTEXTURE;
	if (verticalSync) {
		flags |= SDL_RENDERER_PRESENTVSYNC;
	}
	return SDL_CreateRenderer(window, -1, flags);
#endif
}

inline const char *SdlCompatRendererName(SDL_Renderer *renderer)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_GetRendererName(renderer);
#else
	static SDL_RendererInfo info;
	return SDL_GetRendererInfo(renderer, &info) == 0 ? info.name : nullptr;
#endif
}

inline bool SdlCompatGetWindowMouseGrab(SDL_Window *window)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_GetWindowMouseGrab(window);
#else
	return SDL_GetWindowGrab(window) == SDL_TRUE;
#endif
}

inline bool SdlCompatSetWindowMouseGrab(SDL_Window *window, bool grabbed)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_SetWindowMouseGrab(window, grabbed);
#else
	SDL_SetWindowGrab(window, grabbed ? SDL_TRUE : SDL_FALSE);
	return true;
#endif
}

inline bool SdlCompatSetWindowFullscreen(SDL_Window *window, bool fullscreen)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_SetWindowFullscreen(window, fullscreen);
#else
	return SDL_SetWindowFullscreen(
		window, fullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0) == 0;
#endif
}

inline bool SdlCompatGetWindowSize(SDL_Window *window, int *width, int *height)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_GetWindowSize(window, width, height);
#else
	SDL_GetWindowSize(window, width, height);
	return true;
#endif
}

inline bool SdlCompatSetWindowSize(SDL_Window *window, int width, int height)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_SetWindowSize(window, width, height);
#else
	SDL_SetWindowSize(window, width, height);
	return true;
#endif
}

inline bool
SdlCompatSetWindowIcon(SDL_Window *window, SDL_Surface *icon)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_SetWindowIcon(window, icon);
#else
	SDL_SetWindowIcon(window, icon);
	return true;
#endif
}

inline bool SdlCompatSetCursor(SDL_Cursor *cursor)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_SetCursor(cursor);
#else
	SDL_SetCursor(cursor);
	return true;
#endif
}

inline bool SdlCompatSetClipboardText(const char *text)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_SetClipboardText(text);
#else
	return SDL_SetClipboardText(text) == 0;
#endif
}

inline bool
SdlCompatGetWindowDrawableSize(SDL_Window *window, int *width, int *height)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_GetWindowSizeInPixels(window, width, height);
#else
	SDL_GL_GetDrawableSize(window, width, height);
	return true;
#endif
}

inline bool SdlCompatIsWindowEvent(const SDL_Event &event)
{
#ifdef PEONPAD_USE_SDL3
	return event.type >= SDL_EVENT_WINDOW_FIRST
		&& event.type <= SDL_EVENT_WINDOW_LAST;
#else
	return event.type == SDL_WINDOWEVENT;
#endif
}

inline Uint32 SdlCompatWindowEventType(const SDL_Event &event)
{
#ifdef PEONPAD_USE_SDL3
	return event.type;
#else
	return event.window.event;
#endif
}

inline bool SdlCompatSetRenderDrawColor(SDL_Renderer *renderer,
                                        Uint8 red, Uint8 green,
                                        Uint8 blue, Uint8 alpha)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_SetRenderDrawColor(renderer, red, green, blue, alpha);
#else
	return SDL_SetRenderDrawColor(renderer, red, green, blue, alpha) == 0;
#endif
}

inline bool SdlCompatSetRenderTarget(SDL_Renderer *renderer,
                                     SDL_Texture *texture)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_SetRenderTarget(renderer, texture);
#else
	return SDL_SetRenderTarget(renderer, texture) == 0;
#endif
}

inline bool SdlCompatRenderClear(SDL_Renderer *renderer)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_RenderClear(renderer);
#else
	return SDL_RenderClear(renderer) == 0;
#endif
}

inline bool SdlCompatRenderPresent(SDL_Renderer *renderer)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_RenderPresent(renderer);
#else
	SDL_RenderPresent(renderer);
	return true;
#endif
}

inline bool SdlCompatRenderCopy(SDL_Renderer *renderer, SDL_Texture *texture,
                                const SDL_Rect *source, const SDL_Rect *target)
{
#ifdef PEONPAD_USE_SDL3
	SDL_FRect sourceFloat;
	SDL_FRect targetFloat;
	const SDL_FRect *sourcePointer = nullptr;
	const SDL_FRect *targetPointer = nullptr;
	if (source != nullptr) {
		sourceFloat = {
			static_cast<float>(source->x), static_cast<float>(source->y),
			static_cast<float>(source->w), static_cast<float>(source->h)};
		sourcePointer = &sourceFloat;
	}

	if (target != nullptr) {
		targetFloat = {
			static_cast<float>(target->x), static_cast<float>(target->y),
			static_cast<float>(target->w), static_cast<float>(target->h)};
		targetPointer = &targetFloat;
	}
	return SDL_RenderTexture(renderer, texture, sourcePointer, targetPointer);
#else
	return SDL_RenderCopy(renderer, texture, source, target) == 0;
#endif
}

inline bool SdlCompatUpdateTexture(SDL_Texture *texture,
                                   const SDL_Rect *rect,
                                   const void *pixels, int pitch)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_UpdateTexture(texture, rect, pixels, pitch);
#else
	return SDL_UpdateTexture(texture, rect, pixels, pitch) == 0;
#endif
}

inline bool SdlCompatUpdateYuvTexture(SDL_Texture *texture,
                                      const SDL_Rect *rect,
                                      const Uint8 *yPlane, int yPitch,
                                      const Uint8 *uPlane, int uPitch,
                                      const Uint8 *vPlane, int vPitch)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_UpdateYUVTexture(
		texture, rect, yPlane, yPitch, uPlane, uPitch, vPlane, vPitch);
#else
	return SDL_UpdateYUVTexture(
		texture, rect, yPlane, yPitch, uPlane, uPitch, vPlane, vPitch) == 0;
#endif
}

inline bool SdlCompatSetTextureNearest(SDL_Texture *texture)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_SetTextureScaleMode(texture, SDL_SCALEMODE_NEAREST);
#else
	return SDL_SetTextureScaleMode(texture, SDL_ScaleModeNearest) == 0;
#endif
}

inline bool SdlCompatSetRenderLogicalSize(SDL_Renderer *renderer,
                                          int width, int height)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_SetRenderLogicalPresentation(
		renderer, width, height, SDL_LOGICAL_PRESENTATION_LETTERBOX);
#else
	return SDL_RenderSetLogicalSize(renderer, width, height) == 0;
#endif
}

inline bool SdlCompatDisableRenderLogicalPresentation(SDL_Renderer *renderer)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_SetRenderLogicalPresentation(
		renderer, 0, 0, SDL_LOGICAL_PRESENTATION_DISABLED);
#else
	return SDL_RenderSetLogicalSize(renderer, 0, 0) == 0;
#endif
}

inline bool SdlCompatGetRenderLogicalSize(SDL_Renderer *renderer,
                                          int *width, int *height)
{
#ifdef PEONPAD_USE_SDL3
	SDL_RendererLogicalPresentation presentation;
	return SDL_GetRenderLogicalPresentation(
		renderer, width, height, &presentation);
#else
	SDL_RenderGetLogicalSize(renderer, width, height);
	return true;
#endif
}

inline bool SdlCompatGetRenderOutputSize(SDL_Renderer *renderer,
                                         int *width, int *height)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_GetCurrentRenderOutputSize(renderer, width, height);
#else
	return SDL_GetRendererOutputSize(renderer, width, height) == 0;
#endif
}

inline bool
SdlCompatSetRenderScale(SDL_Renderer *renderer, float scaleX, float scaleY)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_SetRenderScale(renderer, scaleX, scaleY);
#else
	return SDL_RenderSetScale(renderer, scaleX, scaleY) == 0;
#endif
}

inline bool
SdlCompatSetRenderViewport(SDL_Renderer *renderer, const SDL_Rect *viewport)
{
#ifdef PEONPAD_USE_SDL3
	return SDL_SetRenderViewport(renderer, viewport);
#else
	return SDL_RenderSetViewport(renderer, viewport) == 0;
#endif
}

inline bool SdlCompatConvertEventToRenderCoordinates(
	SDL_Renderer *renderer, SDL_Event *event)
{
	if (renderer == nullptr || event == nullptr) {
		SDL_SetError("Renderer event conversion requires non-null arguments");
		return false;
	}
#ifdef PEONPAD_USE_SDL3
	return SDL_ConvertEventToRenderCoordinates(renderer, event);
#else
	return true;
#endif
}

inline bool SdlCompatPointerPressIsOutside(
	const SDL_Event &event, int logicalWidth, int logicalHeight)
{
	float x = 0.0f;
	float y = 0.0f;
	if (event.type == SDL_MOUSEBUTTONDOWN) {
		x = event.button.x;
		y = event.button.y;
	} else if (event.type == SDL_FINGERDOWN) {
#ifdef PEONPAD_USE_SDL3
		x = event.tfinger.x;
		y = event.tfinger.y;
#else
		x = event.tfinger.x * logicalWidth;
		y = event.tfinger.y * logicalHeight;
#endif
	} else {
		return false;
	}
	return x < 0.0f || y < 0.0f
	    || x >= logicalWidth || y >= logicalHeight;
}

inline bool SdlCompatRenderReadPixels(SDL_Renderer *renderer,
                                      const SDL_Rect *rect,
                                      SDL_Surface *destination)
{
#ifdef PEONPAD_USE_SDL3
	SDL_Surface *readback = SDL_RenderReadPixels(renderer, rect);
	if (readback == nullptr) {
		return false;
	}
	const bool copied =
		SDL_BlitSurface(readback, nullptr, destination, nullptr);
	SDL_DestroySurface(readback);
	return copied;
#else
	return SDL_RenderReadPixels(
		renderer, rect, destination->format->format,
		destination->pixels, destination->pitch) == 0;
#endif
}

inline bool SdlCompatRenderFillRect(SDL_Renderer *renderer,
                                    const SDL_Rect *rect)
{
#ifdef PEONPAD_USE_SDL3
	if (rect == nullptr) {
		return SDL_RenderFillRect(renderer, nullptr);
	}
	const SDL_FRect floatRect{
		static_cast<float>(rect->x), static_cast<float>(rect->y),
		static_cast<float>(rect->w), static_cast<float>(rect->h)};
	return SDL_RenderFillRect(renderer, &floatRect);
#else
	return SDL_RenderFillRect(renderer, rect) == 0;
#endif
}

inline bool SdlCompatRenderDrawRect(SDL_Renderer *renderer,
                                    const SDL_Rect *rect)
{
#ifdef PEONPAD_USE_SDL3
	if (rect == nullptr) {
		return SDL_RenderRect(renderer, nullptr);
	}
	const SDL_FRect floatRect{
		static_cast<float>(rect->x), static_cast<float>(rect->y),
		static_cast<float>(rect->w), static_cast<float>(rect->h)};
	return SDL_RenderRect(renderer, &floatRect);
#else
	return SDL_RenderDrawRect(renderer, rect) == 0;
#endif
}
