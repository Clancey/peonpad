#include "PeonPadSDL3Window.h"

#include <SDL3/SDL_properties.h>
#include <TargetConditionals.h>

#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#endif

void *PeonPadSDL3GetNativeWindow(SDL_Window *window)
{
	if (!window) {
		return nullptr;
	}
	const SDL_PropertiesID properties = SDL_GetWindowProperties(window);
#if TARGET_OS_OSX
	return SDL_GetPointerProperty(
		properties, SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, nullptr);
#elif TARGET_OS_VISION || TARGET_OS_IOS
	return SDL_GetPointerProperty(
		properties, SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER, nullptr);
#else
#error "Unsupported Apple window platform"
#endif
}

void *PeonPadSDL3GetNativeMetalView(SDL_Window *window)
{
#if TARGET_OS_OSX
	(void)window;
	return nullptr;
#elif TARGET_OS_VISION || TARGET_OS_IOS
	UIWindow *nativeWindow =
		(__bridge UIWindow *)PeonPadSDL3GetNativeWindow(window);
	if (!nativeWindow) {
		return nullptr;
	}
	const SDL_PropertiesID properties = SDL_GetWindowProperties(window);
	const NSInteger tag = static_cast<NSInteger>(SDL_GetNumberProperty(
		properties, SDL_PROP_WINDOW_UIKIT_METAL_VIEW_TAG_NUMBER, 0));
	return (__bridge void *)[nativeWindow viewWithTag:tag];
#else
#error "Unsupported Apple Metal view platform"
#endif
}

bool PeonPadSDL3MapWindowPointToLogical(
	SDL_Window *window,
	const PeonPadViewportState &viewport,
	const float windowX,
	const float windowY,
	PeonPadViewportPoint &logicalPoint)
{
	int pointWidth = 0;
	int pointHeight = 0;
	int pixelWidth = 0;
	int pixelHeight = 0;
	if (!window
	    || !SDL_GetWindowSize(window, &pointWidth, &pointHeight)
	    || !SDL_GetWindowSizeInPixels(window, &pixelWidth, &pixelHeight)
	    || pointWidth <= 0 || pointHeight <= 0
	    || pixelWidth <= 0 || pixelHeight <= 0) {
		logicalPoint = {};
		return false;
	}

	const float pixelX = windowX * pixelWidth / pointWidth;
	const float pixelY = windowY * pixelHeight / pointHeight;
	return PeonPadMapViewportStatePoint(
		viewport, pixelX, pixelY, logicalPoint);
}
