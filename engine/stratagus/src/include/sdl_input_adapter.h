#ifndef SDL_INPUT_ADAPTER_H
#define SDL_INPUT_ADAPTER_H

#include "input_intent.h"

#include <SDL_events.h>

struct SdlFocusEventPolicy {
	bool CancelInput = false;
	bool ManagePause = false;
};

std::vector<InputIntent> AdaptSdlTouchEvent(TouchInputState &touchInput,
                                            const SDL_TouchFingerEvent &event,
                                            int width, int height,
                                            std::uint32_t timestamp, int modifiers);

SdlFocusEventPolicy GetSdlFocusEventPolicy(Uint8 windowEvent,
                                            bool networkGame,
                                            bool pauseOnLeave);

#endif
