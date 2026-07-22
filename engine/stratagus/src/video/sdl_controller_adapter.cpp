#include "sdl_controller_adapter.h"

#ifdef PEONPAD_USE_SDL3
#include "PeonPadSDL3InputAdapter.h"
#else
#include <SDL_gamecontroller.h>
#include <optional>

namespace
{

std::optional<ControllerAxis> AdaptAxis(Uint8 axis)
{
	switch (axis) {
		case SDL_CONTROLLER_AXIS_LEFTX: return ControllerAxis::LeftX;
		case SDL_CONTROLLER_AXIS_LEFTY: return ControllerAxis::LeftY;
		case SDL_CONTROLLER_AXIS_RIGHTX: return ControllerAxis::RightX;
		case SDL_CONTROLLER_AXIS_RIGHTY: return ControllerAxis::RightY;
		case SDL_CONTROLLER_AXIS_TRIGGERLEFT: return ControllerAxis::LeftTrigger;
		case SDL_CONTROLLER_AXIS_TRIGGERRIGHT: return ControllerAxis::RightTrigger;
		default: return std::nullopt;
	}
}

std::optional<ControllerButton> AdaptButton(Uint8 button)
{
	switch (button) {
		case SDL_CONTROLLER_BUTTON_A: return ControllerButton::Confirm;
		case SDL_CONTROLLER_BUTTON_B: return ControllerButton::Cancel;
		case SDL_CONTROLLER_BUTTON_X: return ControllerButton::ContextCommand;
		case SDL_CONTROLLER_BUTTON_Y: return ControllerButton::ContextSurface;
		case SDL_CONTROLLER_BUTTON_LEFTSHOULDER: return ControllerButton::LeftShoulder;
		case SDL_CONTROLLER_BUTTON_RIGHTSHOULDER: return ControllerButton::RightShoulder;
		case SDL_CONTROLLER_BUTTON_DPAD_UP: return ControllerButton::DpadUp;
		case SDL_CONTROLLER_BUTTON_DPAD_DOWN: return ControllerButton::DpadDown;
		case SDL_CONTROLLER_BUTTON_DPAD_LEFT: return ControllerButton::DpadLeft;
		case SDL_CONTROLLER_BUTTON_DPAD_RIGHT: return ControllerButton::DpadRight;
		case SDL_CONTROLLER_BUTTON_START: return ControllerButton::Menu;
		default: return std::nullopt;
	}
}

float NormalizeAxis(Sint16 value, bool trigger)
{
	if (trigger) {
		return value <= 0 ? 0.0f : value / 32767.0f;
	}
	return value < 0 ? value / 32768.0f : value / 32767.0f;
}

} // namespace
#endif

std::vector<InputIntent> AdaptSdlControllerAxisEvent(ControllerInputState &state,
                                                     const SDL_ControllerAxisEvent &event,
                                                     std::uint32_t timestamp)
{
#ifdef PEONPAD_USE_SDL3
	return PeonPadAdaptSDL3GamepadAxisEvent(state, event, timestamp);
#else
	const std::optional<ControllerAxis> axis = AdaptAxis(event.axis);
	if (!axis) {
		return {};
	}
	const bool trigger =
		*axis == ControllerAxis::LeftTrigger || *axis == ControllerAxis::RightTrigger;
	return state.SetAxis(*axis, NormalizeAxis(event.value, trigger), timestamp);
#endif
}

std::vector<InputIntent> AdaptSdlControllerButtonEvent(ControllerInputState &state,
                                                       const SDL_ControllerButtonEvent &event,
                                                       std::uint32_t timestamp)
{
#ifdef PEONPAD_USE_SDL3
	return PeonPadAdaptSDL3GamepadButtonEvent(state, event, timestamp);
#else
	const std::optional<ControllerButton> button = AdaptButton(event.button);
	if (!button) {
		return {};
	}
	return state.SetButton(*button, event.state == SDL_PRESSED, timestamp);
#endif
}
