#include "PeonPadSDL3Window.h"

#include <SDL3/SDL_properties.h>
#include <TargetConditionals.h>

void *PeonPadSDL3GetNativeWindow(SDL_Window *window)
{
	if (!window) {
		return nullptr;
	}
	const SDL_PropertiesID properties = SDL_GetWindowProperties(window);
#if TARGET_OS_OSX
	return SDL_GetPointerProperty(
		properties, SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, nullptr);
#else
	return SDL_GetPointerProperty(
		properties, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
#endif
}
