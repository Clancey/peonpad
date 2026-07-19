#pragma once

#include <SDL.h>
#include <SDL_opengl.h>

#include <limits>

struct SdlCompatOpenGlTextureBinding
{
#ifdef PEONPAD_USE_SDL3
	GLenum target = 0;
#else
	SDL_Texture *texture = nullptr;
#endif
};

inline bool SdlCompatBindOpenGlTexture(
	SDL_Renderer *renderer, SDL_Texture *texture,
	SdlCompatOpenGlTextureBinding *binding)
{
	if (renderer == nullptr || texture == nullptr || binding == nullptr) {
		SDL_InvalidParamError("renderer, texture, or binding");
		return false;
	}

#ifdef PEONPAD_USE_SDL3
	if (!SDL_FlushRenderer(renderer)) {
		return false;
	}
	const SDL_PropertiesID properties = SDL_GetTextureProperties(texture);
	if (properties == 0) {
		return false;
	}
	const Sint64 textureName = SDL_GetNumberProperty(
		properties, SDL_PROP_TEXTURE_OPENGL_TEXTURE_NUMBER, 0);
	const Sint64 textureTarget = SDL_GetNumberProperty(
		properties, SDL_PROP_TEXTURE_OPENGL_TEXTURE_TARGET_NUMBER, 0);
	if (textureName <= 0 || textureTarget <= 0
	    || static_cast<Uint64>(textureName)
	           > std::numeric_limits<GLuint>::max()
	    || static_cast<Uint64>(textureTarget)
	           > std::numeric_limits<GLenum>::max()) {
		SDL_SetError("SDL texture is not backed by the OpenGL renderer");
		return false;
	}
	(void)glGetError();
	binding->target = static_cast<GLenum>(textureTarget);
	glBindTexture(binding->target, static_cast<GLuint>(textureName));
	if (glGetError() != GL_NO_ERROR) {
		SDL_SetError("OpenGL rejected the SDL texture binding");
		binding->target = 0;
		return false;
	}
	return true;
#else
	if (SDL_GL_BindTexture(texture, nullptr, nullptr) != 0) {
		return false;
	}
	binding->texture = texture;
	return true;
#endif
}

inline bool
SdlCompatUnbindOpenGlTexture(SdlCompatOpenGlTextureBinding *binding)
{
	if (binding == nullptr) {
		SDL_InvalidParamError("binding");
		return false;
	}

#ifdef PEONPAD_USE_SDL3
	if (binding->target == 0) {
		SDL_SetError("OpenGL texture binding is not active");
		return false;
	}
	(void)glGetError();
	glBindTexture(binding->target, 0);
	binding->target = 0;
	if (glGetError() != GL_NO_ERROR) {
		SDL_SetError("OpenGL rejected the SDL texture unbind");
		return false;
	}
	return true;
#else
	if (binding->texture == nullptr) {
		SDL_SetError("OpenGL texture binding is not active");
		return false;
	}
	SDL_Texture *texture = binding->texture;
	binding->texture = nullptr;
	return SDL_GL_UnbindTexture(texture) == 0;
#endif
}
