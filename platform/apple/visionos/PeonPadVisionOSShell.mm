#include "PeonPadVisionOSShell.h"

#include "PeonPadSDL3Window.h"

#include <SDL3/SDL.h>
#include <TargetConditionals.h>

#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>

#if !defined(PEONPAD_VISIONOS) || !TARGET_OS_VISION || TARGET_OS_IOS || TARGET_OS_OSX
#error "PeonPadVisionOSShell.mm must compile only at the native visionOS boundary"
#endif

bool PeonPadVisionOSConfigureShell(SDL_Window *window,
                                  SDL_Renderer *renderer)
{
	if (!window || !renderer) {
		return SDL_SetError("missing visionOS shell window or renderer");
	}
	if (SDL_strcmp(SDL_GetRendererName(renderer), "metal") != 0) {
		return SDL_SetError("visionOS shell requires SDL3 Metal");
	}

	UIWindow *nativeWindow =
		(__bridge UIWindow *)PeonPadSDL3GetNativeWindow(window);
	UIView *metalView =
		(__bridge UIView *)PeonPadSDL3GetNativeMetalView(window);
	if (!nativeWindow || !nativeWindow.windowScene) {
		return SDL_SetError("SDL3 did not attach a visionOS UIWindowScene");
	}
	if (!metalView || ![metalView.layer isKindOfClass:[CAMetalLayer class]]) {
		return SDL_SetError("SDL3 did not attach a UIKit Metal view");
	}

	UIWindowScene *scene = nativeWindow.windowScene;
	NSString *delegateName = NSStringFromClass(scene.delegate.class);
	if (![delegateName isEqualToString:@"SDLUIKitSceneDelegate"]) {
		return SDL_SetError("unexpected visionOS scene delegate");
	}

	UIWindowSceneGeometryPreferencesVision *preferences =
		[[UIWindowSceneGeometryPreferencesVision alloc] init];
	preferences.minimumSize = CGSizeMake(480.0, 360.0);
	preferences.maximumSize = CGSizeMake(1920.0, 1440.0);
	preferences.resizingRestrictions =
		UIWindowSceneResizingRestrictionsFreeform;
	[scene requestGeometryUpdateWithPreferences:preferences
		errorHandler:^(NSError *error) {
		  SDL_LogWarn(SDL_LOG_CATEGORY_APPLICATION,
		              "visionOS resize preference was declined: %s",
		              error.localizedDescription.UTF8String);
		}];

	return SDL_SetWindowResizable(window, true) && SDL_ShowWindow(window);
}
