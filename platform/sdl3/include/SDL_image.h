#ifndef PEONPAD_SDL3_COMPAT_SDL_IMAGE_H
#define PEONPAD_SDL3_COMPAT_SDL_IMAGE_H

#include "SDL.h"
#include <SDL3_image/SDL_image.h>

#define IMG_GetError() SDL_GetError()
#define IMG_Load_RW(source, closeSource) IMG_Load_IO(source, (closeSource) != 0)

static inline int IMG_Init(int flags)
{
	return flags;
}

static inline void IMG_Quit(void)
{
}

#endif
