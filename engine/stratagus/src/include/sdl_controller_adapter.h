#ifndef SDL_CONTROLLER_ADAPTER_H
#define SDL_CONTROLLER_ADAPTER_H

#include "controller_input.h"

#include <SDL_events.h>

std::vector<InputIntent> AdaptSdlControllerAxisEvent(ControllerInputState &state,
                                                     const SDL_ControllerAxisEvent &event,
                                                     std::uint32_t timestamp);
std::vector<InputIntent> AdaptSdlControllerButtonEvent(ControllerInputState &state,
                                                       const SDL_ControllerButtonEvent &event,
                                                       std::uint32_t timestamp);

#endif
