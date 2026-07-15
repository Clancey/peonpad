#include "PeonPadSDL3InputAdapter.h"

#include <cassert>

int main()
{
	ControllerInputState controller;

	SDL_GamepadAxisEvent axis{};
	axis.type = SDL_EVENT_GAMEPAD_AXIS_MOTION;
	axis.axis = SDL_GAMEPAD_AXIS_LEFT_TRIGGER;
	axis.value = 32767;
	const std::vector<InputIntent> trigger =
		PeonPadAdaptSDL3GamepadAxisEvent(controller, axis, 10);
	assert(trigger.size() == 1);
	assert(trigger[0].Kind == InputIntentKind::PointerButton);
	assert(trigger[0].Phase == InputIntentPhase::Begin);
	assert(trigger[0].Code == InputPrimaryButton);

	SDL_GamepadButtonEvent button{};
	button.type = SDL_EVENT_GAMEPAD_BUTTON_DOWN;
	button.button = SDL_GAMEPAD_BUTTON_WEST;
	button.down = true;
	const std::vector<InputIntent> context =
		PeonPadAdaptSDL3GamepadButtonEvent(controller, button, 11);
	assert(context.size() == 1);
	assert(context[0].Code == InputContextButton);
	assert(context[0].Source == InputIntentSource::Controller);

	TouchInputState touch;
	SDL_TouchFingerEvent finger{};
	finger.type = SDL_EVENT_FINGER_DOWN;
	finger.fingerID = 7;
	finger.x = 0.25f;
	finger.y = 0.5f;
	assert(PeonPadAdaptSDL3TouchEvent(touch, finger, 640, 480, 12, 0).empty());
	finger.type = SDL_EVENT_FINGER_CANCELED;
	const std::vector<InputIntent> canceled =
		PeonPadAdaptSDL3TouchEvent(touch, finger, 640, 480, 13, 0);
	assert(canceled.size() == 1);
	assert(canceled[0].Phase == InputIntentPhase::Cancel);

	const PeonPadSDL3FocusEventPolicy focus =
		PeonPadGetSDL3FocusEventPolicy(
			SDL_EVENT_WINDOW_FOCUS_LOST, false, true);
	assert(focus.CancelInput);
	assert(focus.ManagePause);
}
