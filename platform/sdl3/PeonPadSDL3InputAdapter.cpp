#include "PeonPadSDL3InputAdapter.h"

#include <SDL3/SDL_gamepad.h>

#include <optional>

namespace
{

std::optional<ControllerAxis> AdaptAxis(Uint8 axis)
{
	switch (axis) {
		case SDL_GAMEPAD_AXIS_LEFTX: return ControllerAxis::LeftX;
		case SDL_GAMEPAD_AXIS_LEFTY: return ControllerAxis::LeftY;
		case SDL_GAMEPAD_AXIS_RIGHTX: return ControllerAxis::RightX;
		case SDL_GAMEPAD_AXIS_RIGHTY: return ControllerAxis::RightY;
		case SDL_GAMEPAD_AXIS_LEFT_TRIGGER: return ControllerAxis::LeftTrigger;
		case SDL_GAMEPAD_AXIS_RIGHT_TRIGGER: return ControllerAxis::RightTrigger;
		default: return std::nullopt;
	}
}

std::optional<ControllerButton> AdaptButton(Uint8 button)
{
	switch (button) {
		case SDL_GAMEPAD_BUTTON_SOUTH: return ControllerButton::Confirm;
		case SDL_GAMEPAD_BUTTON_EAST: return ControllerButton::Cancel;
		case SDL_GAMEPAD_BUTTON_WEST: return ControllerButton::ContextCommand;
		case SDL_GAMEPAD_BUTTON_NORTH: return ControllerButton::ContextSurface;
		case SDL_GAMEPAD_BUTTON_LEFT_SHOULDER: return ControllerButton::LeftShoulder;
		case SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER: return ControllerButton::RightShoulder;
		case SDL_GAMEPAD_BUTTON_DPAD_UP: return ControllerButton::DpadUp;
		case SDL_GAMEPAD_BUTTON_DPAD_DOWN: return ControllerButton::DpadDown;
		case SDL_GAMEPAD_BUTTON_DPAD_LEFT: return ControllerButton::DpadLeft;
		case SDL_GAMEPAD_BUTTON_DPAD_RIGHT: return ControllerButton::DpadRight;
		case SDL_GAMEPAD_BUTTON_START: return ControllerButton::Menu;
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

std::vector<InputIntent>
PeonPadAdaptSDL3GamepadAxisEvent(ControllerInputState &state,
                                 const SDL_GamepadAxisEvent &event,
                                 std::uint32_t timestamp)
{
	const std::optional<ControllerAxis> axis = AdaptAxis(event.axis);
	if (!axis) {
		return {};
	}
	const bool trigger =
		*axis == ControllerAxis::LeftTrigger || *axis == ControllerAxis::RightTrigger;
	return state.SetAxis(*axis, NormalizeAxis(event.value, trigger), timestamp);
}

std::vector<InputIntent>
PeonPadAdaptSDL3GamepadButtonEvent(ControllerInputState &state,
                                   const SDL_GamepadButtonEvent &event,
                                   std::uint32_t timestamp)
{
	const std::optional<ControllerButton> button = AdaptButton(event.button);
	return button ? state.SetButton(*button, event.down, timestamp)
	              : std::vector<InputIntent>{};
}

std::vector<InputIntent>
PeonPadAdaptSDL3TouchEvent(TouchInputState &touchInput,
                           const SDL_TouchFingerEvent &event,
                           int width, int height,
                           std::uint32_t timestamp, int modifiers)
{
	const TouchPoint position{event.x, event.y};
	switch (event.type) {
		case SDL_EVENT_FINGER_DOWN:
			if (position.x < 0.0f || position.y < 0.0f
			    || position.x >= width || position.y >= height) {
				return {};
			}
			return touchInput.Begin(event.fingerID, position, timestamp, modifiers);
		case SDL_EVENT_FINGER_MOTION:
			return touchInput.Update(event.fingerID, position, timestamp, modifiers);
		case SDL_EVENT_FINGER_UP:
			return touchInput.End(event.fingerID, position, timestamp, modifiers);
		case SDL_EVENT_FINGER_CANCELED:
			return touchInput.Cancel(timestamp, modifiers);
		default:
			return {};
	}
}

PeonPadSDL3FocusEventPolicy
PeonPadGetSDL3FocusEventPolicy(SDL_EventType eventType,
                               bool networkGame, bool pauseOnLeave)
{
	return {
		eventType == SDL_EVENT_WINDOW_FOCUS_LOST,
		!networkGame && pauseOnLeave
		    && (eventType == SDL_EVENT_WINDOW_FOCUS_LOST
		        || eventType == SDL_EVENT_WINDOW_FOCUS_GAINED)
	};
}
