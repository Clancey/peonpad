#include "sdl_input_adapter.h"

#ifdef PEONPAD_USE_SDL3
#include "PeonPadSDL3InputAdapter.h"
#endif

std::vector<InputIntent> AdaptSdlTouchEvent(TouchInputState &touchInput,
                                            const SDL_TouchFingerEvent &event,
                                            int width, int height,
                                            std::uint32_t timestamp, int modifiers)
{
#ifdef PEONPAD_USE_SDL3
	return PeonPadAdaptSDL3TouchEvent(
		touchInput, event, width, height, timestamp, modifiers);
#else
	const TouchPoint position{event.x * width, event.y * height};
	switch (event.type) {
		case SDL_FINGERDOWN:
			return touchInput.Begin(event.fingerId, position, timestamp, modifiers);
		case SDL_FINGERMOTION:
			return touchInput.Update(event.fingerId, position, timestamp, modifiers);
		case SDL_FINGERUP:
			return touchInput.End(event.fingerId, position, timestamp, modifiers);
		case SDL_FINGERCANCEL:
			return touchInput.Cancel(timestamp, modifiers);
		default:
			return {};
	}
#endif
}

SdlFocusEventPolicy GetSdlFocusEventPolicy(Uint32 windowEvent,
                                            bool networkGame,
                                            bool pauseOnLeave)
{
#ifdef PEONPAD_USE_SDL3
	const PeonPadSDL3FocusEventPolicy policy =
		PeonPadGetSDL3FocusEventPolicy(
			static_cast<SDL_EventType>(windowEvent),
			networkGame, pauseOnLeave);
	return {policy.CancelInput, policy.ManagePause};
#else
	return {
		windowEvent == SDL_WINDOWEVENT_FOCUS_LOST,
		!networkGame && pauseOnLeave
		    && (windowEvent == SDL_WINDOWEVENT_FOCUS_LOST
		        || windowEvent == SDL_WINDOWEVENT_FOCUS_GAINED)
	};
#endif
}
