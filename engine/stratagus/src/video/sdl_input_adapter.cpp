#include "sdl_input_adapter.h"

std::vector<InputIntent> AdaptSdlTouchEvent(TouchInputState &touchInput,
                                            const SDL_TouchFingerEvent &event,
                                            int width, int height,
                                            std::uint32_t timestamp, int modifiers)
{
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
}

SdlFocusEventPolicy GetSdlFocusEventPolicy(Uint8 windowEvent,
                                            bool networkGame,
                                            bool pauseOnLeave)
{
	return {
		windowEvent == SDL_WINDOWEVENT_FOCUS_LOST,
		!networkGame && pauseOnLeave
		    && (windowEvent == SDL_WINDOWEVENT_FOCUS_LOST
		        || windowEvent == SDL_WINDOWEVENT_FOCUS_GAINED)
	};
}
