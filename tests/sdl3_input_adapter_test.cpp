#include "PeonPadSDL3InputAdapter.h"

#include <cassert>

#if defined(NDEBUG)
#error "peonpad_sdl3_input_adapter_test requires active assertions"
#endif

namespace
{

bool AssertionsAreActive()
{
	bool evaluated = false;
	assert((evaluated = true));
	return evaluated;
}

} // namespace

int main(int argc, char **)
{
	if (argc > 1) {
		return AssertionsAreActive() ? 0 : 1;
	}
	ControllerInputState controller;

	SDL_GamepadAxisEvent axis{};
	axis.type = SDL_EVENT_GAMEPAD_AXIS_MOTION;
	axis.axis = SDL_GAMEPAD_AXIS_LEFT_TRIGGER;
	axis.value = 32767;
	const std::vector<InputIntent> trigger =
		PeonPadAdaptSDL3GamepadAxisEvent(controller, axis, 10);
	assert(trigger.size() == 1);
	assert(trigger[0].Kind == InputIntentKind::Modifier);
	assert(trigger[0].Phase == InputIntentPhase::Begin);
	assert(trigger[0].Code
	       == static_cast<unsigned>(InputModifierCode::AdditiveSelection));
	assert(trigger[0].Source == InputIntentSource::Controller);

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
	finger.x = 160.0f;
	finger.y = 240.0f;
	assert(PeonPadAdaptSDL3TouchEvent(touch, finger, 640, 480, 12, 0).empty());
	finger.fingerID = 8;
	finger.x = 480.0f;
	const std::vector<InputIntent> second =
		PeonPadAdaptSDL3TouchEvent(touch, finger, 640, 480, 13, 0);
	assert(second.size() == 1);
	assert(second[0].Kind == InputIntentKind::PointerButton);
	assert(second[0].Phase == InputIntentPhase::Cancel);
	finger.fingerID = 9;
	finger.x = 320.0f;
	finger.y = 360.0f;
	const std::vector<InputIntent> pan =
		PeonPadAdaptSDL3TouchEvent(touch, finger, 640, 480, 14, 0);
	assert(pan.size() == 1);
	assert(pan[0].Kind == InputIntentKind::ViewportPan);
	assert(pan[0].Phase == InputIntentPhase::Begin);
	finger.type = SDL_EVENT_FINGER_CANCELED;
	const std::vector<InputIntent> canceled =
		PeonPadAdaptSDL3TouchEvent(touch, finger, 640, 480, 15, 0);
	assert(canceled.size() == 1);
	assert(canceled[0].Kind == InputIntentKind::ViewportPan);
	assert(canceled[0].Phase == InputIntentPhase::Cancel);
	assert(touch.ContactCount() == 0);
	assert(!touch.IsPanning());
	assert(!touch.SuppressPointerEvents());

	finger.type = SDL_EVENT_FINGER_DOWN;
	finger.fingerID = 10;
	finger.x = -1.0f;
	finger.y = 240.0f;
	assert(PeonPadAdaptSDL3TouchEvent(
		       touch, finger, 640, 480, 16, 0).empty());
	assert(touch.ContactCount() == 0);

	const PeonPadSDL3FocusEventPolicy focus =
		PeonPadGetSDL3FocusEventPolicy(
			SDL_EVENT_WINDOW_FOCUS_LOST, false, true);
	assert(focus.CancelInput);
	assert(focus.ManagePause);
}
