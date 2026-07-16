#ifndef PEONPAD_SDL3_WINDOW_H
#define PEONPAD_SDL3_WINDOW_H

#include <SDL3/SDL_video.h>

#include "PeonPadViewportGeometry.h"

void *PeonPadSDL3GetNativeWindow(SDL_Window *window);
void *PeonPadSDL3GetNativeMetalView(SDL_Window *window);

// Converts SDL window-point input through Retina scale and the authoritative
// aspect-fit viewport. Bar input is rejected.
bool PeonPadSDL3MapWindowPointToLogical(
	SDL_Window *window,
	const PeonPadViewportGeometry &viewport,
	float windowX,
	float windowY,
	PeonPadViewportPoint &logicalPoint);

#endif
