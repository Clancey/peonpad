#ifndef PEONPAD_SDL3_INPUT_ADAPTER_H
#define PEONPAD_SDL3_INPUT_ADAPTER_H

#include "controller_input.h"

#include <SDL3/SDL_events.h>

struct PeonPadSDL3FocusEventPolicy
{
	bool CancelInput = false;
	bool ManagePause = false;
};

std::vector<InputIntent>
PeonPadAdaptSDL3GamepadAxisEvent(ControllerInputState &state,
                                 const SDL_GamepadAxisEvent &event,
                                 std::uint32_t timestamp);
std::vector<InputIntent>
PeonPadAdaptSDL3GamepadButtonEvent(ControllerInputState &state,
                                   const SDL_GamepadButtonEvent &event,
                                   std::uint32_t timestamp);
std::vector<InputIntent>
PeonPadAdaptSDL3TouchEvent(TouchInputState &touchInput,
                           const SDL_TouchFingerEvent &event,
                           int width, int height,
                           std::uint32_t timestamp, int modifiers);
PeonPadSDL3FocusEventPolicy
PeonPadGetSDL3FocusEventPolicy(SDL_EventType eventType,
                               bool networkGame, bool pauseOnLeave);

#endif
