#include "PeonPadIOSViewport.h"

#include "PeonPadViewportGeometry.h"
#include "sdl_compat.h"

#include <SDL.h>
#ifdef PEONPAD_USE_SDL3
#include "PeonPadSDL3Window.h"
#else
#include <SDL_syswm.h>
#endif
#include <UIKit/UIKit.h>

#include <cmath>

void PeonPadIOSApplySafeAreaViewport(SDL_Window *window,
                                    SDL_Renderer *renderer,
                                    const int logicalWidth,
                                    const int logicalHeight)
{
	if (!window || !renderer) {
		return;
	}

#ifdef PEONPAD_USE_SDL3
	UIWindow *uiWindow =
		(__bridge UIWindow *)PeonPadSDL3GetNativeWindow(window);
#else
	SDL_SysWMinfo windowInfo;
	SDL_VERSION(&windowInfo.version);
	if (!SDL_GetWindowWMInfo(window, &windowInfo)) {
		return;
	}
	UIWindow *uiWindow = windowInfo.info.uikit.window;
#endif
	if (!uiWindow) {
		return;
	}
	UIView *rootView = uiWindow.rootViewController.view;
	if (!rootView) {
		return;
	}

	int windowWidth = 0;
	int windowHeight = 0;
	int outputWidth = 0;
	int outputHeight = 0;
	if (!SdlCompatGetWindowSize(window, &windowWidth, &windowHeight)
	    || windowWidth <= 0 || windowHeight <= 0
	    || !SdlCompatGetRenderOutputSize(renderer, &outputWidth, &outputHeight)) {
		SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
		             "Unable to query safe-area viewport dimensions: %s",
		             SDL_GetError());
		return;
	}

	const UIEdgeInsets points = rootView.safeAreaInsets;
	const double scaleX = static_cast<double>(outputWidth) / windowWidth;
	const double scaleY = static_cast<double>(outputHeight) / windowHeight;
	const PeonPadPixelInsets pixels = {
		static_cast<int>(std::ceil(points.left * scaleX)),
		static_cast<int>(std::ceil(points.top * scaleY)),
		static_cast<int>(std::ceil(points.right * scaleX)),
		static_cast<int>(std::ceil(points.bottom * scaleY)),
	};

	PeonPadViewportGeometry geometry;
	if (!PeonPadCalculateViewport(outputWidth, outputHeight,
	                              logicalWidth, logicalHeight,
	                              pixels, geometry)) {
		return;
	}

#ifdef PEONPAD_USE_SDL3
	PeonPadRendererTransform transform;
	if (!PeonPadCalculateRendererTransform(geometry, transform)) {
		SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
		             "Unable to calculate safe-area renderer transform");
		return;
	}
	const SDL_Rect viewport = {
		transform.viewportX,
		transform.viewportY,
		transform.viewportWidth,
		transform.viewportHeight,
	};
	if (!SdlCompatDisableRenderLogicalPresentation(renderer)
	    || !SdlCompatSetRenderScale(
		    renderer, transform.scale, transform.scale)
	    || !SdlCompatSetRenderViewport(renderer, &viewport)) {
		SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
		             "Unable to apply safe-area renderer transform: %s",
		             SDL_GetError());
	}
#else
	const SDL_Rect viewport = {
		geometry.x,
		geometry.y,
		geometry.width,
		geometry.height,
	};
	if (!SdlCompatSetRenderScale(renderer, 1.0f, 1.0f)
	    || !SdlCompatSetRenderViewport(renderer, &viewport)) {
		SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
		             "Unable to reset safe-area renderer state: %s",
		             SDL_GetError());
		return;
	}
	if (!SdlCompatSetRenderScale(renderer, geometry.scale, geometry.scale)) {
		SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
		             "Unable to apply safe-area renderer scale: %s",
		             SDL_GetError());
	}
#endif
}
