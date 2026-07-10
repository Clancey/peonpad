#include "PeonPadIOSViewport.h"

#include "PeonPadViewportGeometry.h"

#include <SDL.h>
#include <SDL_syswm.h>
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

	SDL_SysWMinfo windowInfo;
	SDL_VERSION(&windowInfo.version);
	if (!SDL_GetWindowWMInfo(window, &windowInfo) || !windowInfo.info.uikit.window) {
		return;
	}

	UIWindow *uiWindow = windowInfo.info.uikit.window;
	UIView *rootView = uiWindow.rootViewController.view;
	if (!rootView) {
		return;
	}

	int windowWidth = 0;
	int windowHeight = 0;
	int outputWidth = 0;
	int outputHeight = 0;
	SDL_GetWindowSize(window, &windowWidth, &windowHeight);
	if (windowWidth <= 0 || windowHeight <= 0
	    || SDL_GetRendererOutputSize(renderer, &outputWidth, &outputHeight) != 0) {
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

	// SDL's logical-size event watcher reads this viewport and scale when it
	// converts Retina pointer/touch coordinates. Updating the public renderer
	// state here therefore keeps drawing and input on one transform.
	SDL_RenderSetScale(renderer, 1.0f, 1.0f);
	const SDL_Rect viewport = {
		geometry.x,
		geometry.y,
		geometry.width,
		geometry.height,
	};
	SDL_RenderSetViewport(renderer, &viewport);
	SDL_RenderSetScale(renderer, geometry.scale, geometry.scale);
}
