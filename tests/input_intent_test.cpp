#include "controller_input.h"
#include "input_intent.h"
#include "PeonPadIOSControlState.h"
#include "sdl_controller_adapter.h"
#include "sdl_input_adapter.h"

#include <cassert>
#include <cmath>
#include <vector>

#if defined(NDEBUG)
#error "peonpad_input_intent_test requires active assertions"
#endif

namespace
{

bool AssertionsAreActive()
{
	bool evaluated = false;
	assert((evaluated = true));
	return evaluated;
}

class RecordingTarget final : public InputIntentTarget
{
public:
	bool Dispatch(const InputIntent &intent) override
	{
		Intents.push_back(intent);
		return Accept;
	}

	bool Accept = true;
	std::vector<InputIntent> Intents;
};

class OwnershipRecordingTarget final : public InputIntentTarget
{
public:
	bool Dispatch(const InputIntent &intent) override
	{
		if (intent.Kind != InputIntentKind::PointerButton) {
			return true;
		}
		InputButtonOwnershipChange change = InputButtonOwnershipChange::Ignored;
		if (intent.Phase == InputIntentPhase::Begin) {
			change = Ownership.Press(intent.Source, intent.Code);
		} else if (intent.Phase == InputIntentPhase::End
		           || intent.Phase == InputIntentPhase::Cancel) {
			change = Ownership.Release(intent.Source, intent.Code);
		}
		if (change == InputButtonOwnershipChange::EffectivePress
		    || change == InputButtonOwnershipChange::EffectiveRelease) {
			EffectiveIntents.push_back(intent);
		}
		return change != InputButtonOwnershipChange::Ignored;
	}

	InputButtonOwnership Ownership;
	std::vector<InputIntent> EffectiveIntents;
};

InputIntent PointerButtonIntent(InputIntentSource source, InputIntentPhase phase,
                                unsigned button, std::uint32_t timestamp)
{
	return {InputIntentKind::PointerButton, phase, {10, 20}, {},
	        0, timestamp, button, 0, source};
}

void RouteAll(InputIntentRouter &router,
              RecordingTarget &target,
              const std::vector<InputIntent> &intents)
{
	for (const InputIntent &intent : intents) {
		router.Route(intent, target);
	}
}

void TestRouterPropagation()
{
	InputIntentRouter router;
	RecordingTarget target;
	const InputIntent motion{
		InputIntentKind::PointerMotion, InputIntentPhase::Update, {23, 42}, {-4, 8}, 5, 1234};

	assert(router.Route(motion, target));
	assert(target.Intents.size() == 1);
	assert(target.Intents[0].Position.x == 23);
	assert(target.Intents[0].Position.y == 42);
	assert(target.Intents[0].Delta.x == -4);
	assert(target.Intents[0].Delta.y == 8);
	assert(target.Intents[0].Modifiers == 5);
	assert(target.Intents[0].Timestamp == 1234);
}

void TestRouterPhasesAndCancellation()
{
	InputIntentRouter router;
	RecordingTarget target;

	assert(router.Route({InputIntentKind::PointerButton,
	                     InputIntentPhase::Begin,
	                     {10, 20},
	                     {},
	                     1,
	                     100,
	                     InputPrimaryButton},
	                    target));
	assert(router.IsPointerButtonActive(InputPrimaryButton));
	assert(router.Route(
		{InputIntentKind::ViewportPan, InputIntentPhase::Begin, {30, 40}, {}, 2, 110}, target));
	assert(router.IsViewportPanActive());

	router.CancelPointer(target, 120, 3, {50, 60});
	assert(!router.IsPointerButtonActive(InputPrimaryButton));
	assert(!router.IsViewportPanActive());
	assert(target.Intents.size() == 4);
	assert(target.Intents[2].Kind == InputIntentKind::ViewportPan);
	assert(target.Intents[2].Phase == InputIntentPhase::Cancel);
	assert(target.Intents[3].Kind == InputIntentKind::PointerButton);
	assert(target.Intents[3].Phase == InputIntentPhase::Cancel);
	assert(target.Intents[3].Position.x == 50);
	assert(target.Intents[3].Position.y == 60);
	assert(target.Intents[3].Modifiers == 3);
	assert(target.Intents[3].Timestamp == 120);

	const std::size_t count = target.Intents.size();
	assert(!router.Route(
		{InputIntentKind::ViewportPan, InputIntentPhase::Update, {}, {2, 3}, 0, 130}, target));
	assert(target.Intents.size() == count);

	target.Accept = false;
	assert(!router.Route(
		{InputIntentKind::ViewportPan, InputIntentPhase::Begin, {1, 2}, {}, 0, 140}, target));
	assert(!router.IsViewportPanActive());
}

void TestDelayedPointerEndAfterCancellation()
{
	InputIntentRouter router;
	RecordingTarget target;

	assert(router.Route({InputIntentKind::PointerButton,
	                     InputIntentPhase::Begin,
	                     {10, 20},
	                     {},
	                     0,
	                     1,
	                     InputPrimaryButton},
	                    target));
	router.CancelPointer(target, 2, 0, {10, 20});
	assert(target.Intents.size() == 2);
	assert(target.Intents.back().Phase == InputIntentPhase::Cancel);

	assert(!router.Route({InputIntentKind::PointerButton,
	                      InputIntentPhase::End,
	                      {10, 20},
	                      {},
	                      0,
	                      3,
	                      InputPrimaryButton},
	                     target));
	assert(target.Intents.size() == 2);

	assert(router.Route({InputIntentKind::PointerButton,
	                     InputIntentPhase::Begin,
	                     {30, 40},
	                     {},
	                     0,
	                     4,
	                     InputPrimaryButton},
	                    target));
	assert(router.Route({InputIntentKind::PointerButton,
	                     InputIntentPhase::End,
	                     {30, 40},
	                     {},
	                     0,
	                     5,
	                     InputPrimaryButton},
	                    target));
	assert(target.Intents.size() == 4);
	assert(target.Intents.back().Phase == InputIntentPhase::End);
	assert(target.Intents.back().Timestamp == 5);
}

void TestCrossSourcePointerButtonOwnership()
{
	for (const InputIntentSource pointerSource :
	     {InputIntentSource::Mouse, InputIntentSource::Touch}) {
		InputIntentRouter pointerRouter;
		InputIntentRouter controllerRouter;
		OwnershipRecordingTarget target;

		assert(pointerRouter.Route(
			PointerButtonIntent(pointerSource, InputIntentPhase::Begin,
			                    InputPrimaryButton, 1),
			target));
		assert(controllerRouter.Route(
			PointerButtonIntent(InputIntentSource::Controller,
			                    InputIntentPhase::Begin,
			                    InputPrimaryButton, 2),
			target));
		assert(target.EffectiveIntents.size() == 1);
		assert(target.Ownership.OwnerCount(InputPrimaryButton) == 2);

		assert(controllerRouter.Route(
			PointerButtonIntent(InputIntentSource::Controller,
			                    InputIntentPhase::End,
			                    InputPrimaryButton, 3),
			target));
		assert(target.EffectiveIntents.size() == 1);
		assert(target.Ownership.HasOwner(pointerSource, InputPrimaryButton));
		assert(!target.Ownership.HasOwner(
			InputIntentSource::Controller, InputPrimaryButton));

		assert(pointerRouter.Route(
			PointerButtonIntent(pointerSource, InputIntentPhase::End,
			                    InputPrimaryButton, 4),
			target));
		assert(target.EffectiveIntents.size() == 2);
		assert(target.EffectiveIntents.back().Phase == InputIntentPhase::End);
		assert(!target.Ownership.HasAnyOwner(InputPrimaryButton));
	}
}

void TestControllerCancelRetainsPointerOwner()
{
	InputIntentRouter pointerRouter;
	InputIntentRouter controllerRouter;
	OwnershipRecordingTarget target;

	assert(pointerRouter.Route(
		PointerButtonIntent(InputIntentSource::Touch, InputIntentPhase::Begin,
		                    InputPrimaryButton, 1),
		target));
	assert(controllerRouter.Route(
		PointerButtonIntent(InputIntentSource::Controller,
		                    InputIntentPhase::Begin,
		                    InputPrimaryButton, 2),
		target));
	assert(controllerRouter.Route(
		PointerButtonIntent(InputIntentSource::Controller,
		                    InputIntentPhase::Cancel,
		                    InputPrimaryButton, 3),
		target));
	assert(target.EffectiveIntents.size() == 1);
	assert(target.Ownership.HasOwner(
		InputIntentSource::Touch, InputPrimaryButton));

	assert(pointerRouter.Route(
		PointerButtonIntent(InputIntentSource::Touch, InputIntentPhase::End,
		                    InputPrimaryButton, 4),
		target));
	assert(target.EffectiveIntents.size() == 2);
	assert(target.EffectiveIntents.back().Phase == InputIntentPhase::End);
}

void TestReversePointerOwnershipAndContextButton()
{
	for (const unsigned button :
	     {InputPrimaryButton, InputContextButton}) {
		InputIntentRouter pointerRouter;
		InputIntentRouter controllerRouter;
		OwnershipRecordingTarget target;

		assert(controllerRouter.Route(
			PointerButtonIntent(InputIntentSource::Controller,
			                    InputIntentPhase::Begin, button, 1),
			target));
		assert(pointerRouter.Route(
			PointerButtonIntent(InputIntentSource::Mouse,
			                    InputIntentPhase::Begin, button, 2),
			target));
		assert(controllerRouter.Route(
			PointerButtonIntent(InputIntentSource::Controller,
			                    InputIntentPhase::End, button, 3),
			target));
		assert(target.EffectiveIntents.size() == 1);
		assert(target.Ownership.HasOwner(InputIntentSource::Mouse, button));

		assert(pointerRouter.Route(
			PointerButtonIntent(InputIntentSource::Mouse,
			                    InputIntentPhase::End, button, 4),
			target));
		assert(target.EffectiveIntents.size() == 2);
		assert(target.EffectiveIntents.back().Code == button);
		assert(target.EffectiveIntents.back().Phase == InputIntentPhase::End);
		assert(!target.Ownership.HasAnyOwner(button));
	}
}

void TestFocusCancellationClearsAllButtonOwners()
{
	InputIntentRouter pointerRouter;
	InputIntentRouter controllerRouter;
	OwnershipRecordingTarget target;

	assert(pointerRouter.Route(
		PointerButtonIntent(InputIntentSource::Mouse,
		                    InputIntentPhase::Begin,
		                    InputPrimaryButton, 1),
		target));
	assert(controllerRouter.Route(
		PointerButtonIntent(InputIntentSource::Controller,
		                    InputIntentPhase::Begin,
		                    InputPrimaryButton, 2),
		target));
	pointerRouter.CancelPointer(target, 3, 0, {10, 20});
	assert(target.Ownership.HasOwner(
		InputIntentSource::Controller, InputPrimaryButton));
	assert(target.EffectiveIntents.size() == 1);

	controllerRouter.CancelPointer(target, 4, 0, {10, 20});
	assert(!target.Ownership.HasAnyOwner(InputPrimaryButton));
	assert(target.EffectiveIntents.size() == 2);
	assert(target.EffectiveIntents.back().Phase == InputIntentPhase::Cancel);

	assert(!pointerRouter.Route(
		PointerButtonIntent(InputIntentSource::Mouse, InputIntentPhase::End,
		                    InputPrimaryButton, 5),
		target));
	assert(!controllerRouter.Route(
		PointerButtonIntent(InputIntentSource::Controller,
		                    InputIntentPhase::End,
		                    InputPrimaryButton, 6),
		target));

	assert(pointerRouter.Route(
		PointerButtonIntent(InputIntentSource::Mouse,
		                    InputIntentPhase::Begin,
		                    InputPrimaryButton, 7),
		target));
	assert(pointerRouter.Route(
		PointerButtonIntent(InputIntentSource::Mouse, InputIntentPhase::End,
		                    InputPrimaryButton, 8),
		target));
	assert(target.EffectiveIntents.size() == 4);
	assert(!target.Ownership.HasAnyOwner(InputPrimaryButton));
}

void TestSourceSpecificTouchCancellationRetainsMouse()
{
	InputIntentRouter pointerRouter;
	OwnershipRecordingTarget target;

	assert(pointerRouter.Route(
		PointerButtonIntent(InputIntentSource::Mouse,
		                    InputIntentPhase::Begin,
		                    InputPrimaryButton, 1),
		target));
	assert(pointerRouter.Route(
		PointerButtonIntent(InputIntentSource::Touch,
		                    InputIntentPhase::Begin,
		                    InputPrimaryButton, 2),
		target));
	pointerRouter.CancelPointer(
		target, 3, 0, {10, 20}, InputIntentSource::Touch);
	assert(target.EffectiveIntents.size() == 1);
	assert(target.Ownership.HasOwner(
		InputIntentSource::Mouse, InputPrimaryButton));
	assert(!target.Ownership.HasOwner(
		InputIntentSource::Touch, InputPrimaryButton));

	pointerRouter.CancelPointer(
		target, 4, 0, {10, 20}, InputIntentSource::Mouse);
	assert(target.EffectiveIntents.size() == 2);
	assert(target.EffectiveIntents.back().Phase == InputIntentPhase::Cancel);
	assert(!target.Ownership.HasAnyOwner(InputPrimaryButton));
}

void TestVisionControlButtonPairing()
{
	PeonPadIOSControlState controls;
	assert(controls.MapPointerButton(InputPrimaryButton, true)
	       == InputPrimaryButton);
	assert(controls.MapPointerButton(InputPrimaryButton, false)
	       == InputPrimaryButton);

	controls.ToggleContext();
	assert(controls.IsContextArmed());
	assert(controls.MapPointerButton(InputPrimaryButton, true)
	       == InputContextButton);
	assert(!controls.IsContextArmed());
	assert(controls.MapPointerButton(InputPrimaryButton, false)
	       == InputContextButton);

	assert(controls.MapPointerButton(InputPrimaryButton, true)
	       == InputPrimaryButton);
	controls.ToggleContext();
	assert(controls.MapPointerButton(InputPrimaryButton, false)
	       == InputPrimaryButton);
	assert(controls.IsContextArmed());
	assert(controls.MapPointerButton(InputPrimaryButton, true)
	       == InputContextButton);
	controls.ResetGesture();
	assert(!controls.IsContextArmed());
	assert(controls.MapPointerButton(InputPrimaryButton, false)
	       == InputPrimaryButton);
}

void TestVisionControlAdditiveSelection()
{
	PeonPadIOSControlState controls;
	const int existingModifier = 1 << 4;
	assert(controls.ApplyPointerModifiers(existingModifier, true)
	       == existingModifier);
	assert(controls.ApplyPointerModifiers(existingModifier, false)
	       == existingModifier);

	controls.ToggleAdditive();
	assert(controls.IsAdditiveEnabled());
	const int pressed = controls.ApplyPointerModifiers(existingModifier, true);
	assert(pressed & existingModifier);
	assert(pressed & InputModifierAdditiveSelection);
	assert(controls.ApplyPointerModifiers(0, false)
	       == InputModifierAdditiveSelection);
	assert(controls.IsAdditiveEnabled());

	controls.ApplyPointerModifiers(0, true);
	controls.ResetGesture();
	assert(controls.ApplyPointerModifiers(0, false) == 0);
	assert(controls.IsAdditiveEnabled());
	controls.ToggleAdditive();
	assert(!controls.IsAdditiveEnabled());
}

void TestTwoFingerContextAction()
{
	TouchInputState touch;
	assert(touch.Begin(1, {800.0f, 100.0f}, 10, 4).empty());
	const std::vector<InputIntent> second = touch.Begin(2, {200.0f, 300.0f}, 11, 4);
	assert(second.size() == 1);
	assert(second[0].Kind == InputIntentKind::PointerButton);
	assert(second[0].Phase == InputIntentPhase::Cancel);
	assert(second[0].Code == InputPrimaryButton);
	assert(touch.SuppressPointerEvents());
	assert(touch.HasPendingContextAction());

	const std::vector<InputIntent> action = touch.End(1, {800.0f, 100.0f}, 12, 4);
	assert(action.size() == 2);
	assert(action[0].Phase == InputIntentPhase::Begin);
	assert(action[1].Phase == InputIntentPhase::End);
	assert(action[0].Code == InputContextButton);
	assert(action[0].Position.x == 200);
	assert(action[0].Position.y == 300);
	assert(action[0].Modifiers == 4);
	assert(action[0].Timestamp == 12);

	assert(touch.End(2, {200.0f, 300.0f}, 13, 4).empty());
	assert(!touch.SuppressPointerEvents());
	assert(touch.ContactCount() == 0);
}

void TestContextMovementTolerance()
{
	TouchInputState touch;
	touch.Begin(1, {100.0f, 100.0f}, 1, 0);
	touch.Begin(2, {200.0f, 200.0f}, 2, 0);
	assert(touch.Update(2, {216.0f, 200.0f}, 3, 0).empty());
	assert(touch.HasPendingContextAction());
	assert(touch.Update(2, {217.0f, 200.0f}, 4, 0).empty());
	assert(!touch.HasPendingContextAction());
	assert(touch.End(1, {100.0f, 100.0f}, 5, 0).empty());
	assert(touch.End(2, {217.0f, 200.0f}, 6, 0).empty());
}

void TestPendingContextCancellation()
{
	TouchInputState touch;
	touch.Begin(1, {100.0f, 100.0f}, 1, 0);
	touch.Begin(2, {200.0f, 200.0f}, 2, 0);
	assert(touch.HasPendingContextAction());
	assert(touch.Cancel(3, 0).empty());
	assert(!touch.HasPendingContextAction());
	assert(!touch.SuppressPointerEvents());
	assert(touch.ContactCount() == 0);
	assert(touch.End(1, {100.0f, 100.0f}, 4, 0).empty());
}

void TestSdlTouchCancellationAdapter()
{
	TouchInputState touch;
	SDL_TouchFingerEvent event{};
	event.type = SDL_FINGERDOWN;
	event.fingerId = 1;
	event.x = 0.8f;
	event.y = 0.2f;
	assert(AdaptSdlTouchEvent(touch, event, 1000, 500, 1, 0).empty());

	event.fingerId = 2;
	event.x = 0.2f;
	event.y = 0.6f;
	const std::vector<InputIntent> second = AdaptSdlTouchEvent(touch, event, 1000, 500, 2, 4);
	assert(second.size() == 1);
	assert(second[0].Position.x == 200);
	assert(second[0].Position.y == 300);
	assert(second[0].Modifiers == 4);
	assert(second[0].Timestamp == 2);
	assert(second[0].Source == InputIntentSource::Touch);
	assert(touch.HasPendingContextAction());

	event.type = SDL_FINGERCANCEL;
	const std::vector<InputIntent> canceled = AdaptSdlTouchEvent(touch, event, 1000, 500, 3, 0);
	assert(canceled.empty());
	assert(!touch.HasPendingContextAction());
	assert(touch.ContactCount() == 0);

	event.type = SDL_FINGERUP;
	assert(AdaptSdlTouchEvent(touch, event, 1000, 500, 4, 0).empty());
}

void TestFocusLossPolicy()
{
	const SdlFocusEventPolicy network =
		GetSdlFocusEventPolicy(SDL_WINDOWEVENT_FOCUS_LOST, true, true);
	assert(network.CancelInput);
	assert(!network.ManagePause);

	const SdlFocusEventPolicy pauseDisabled =
		GetSdlFocusEventPolicy(SDL_WINDOWEVENT_FOCUS_LOST, false, false);
	assert(pauseDisabled.CancelInput);
	assert(!pauseDisabled.ManagePause);

	const SdlFocusEventPolicy pauseEnabled =
		GetSdlFocusEventPolicy(SDL_WINDOWEVENT_FOCUS_LOST, false, true);
	assert(pauseEnabled.CancelInput);
	assert(pauseEnabled.ManagePause);

	const SdlFocusEventPolicy focusGained =
		GetSdlFocusEventPolicy(SDL_WINDOWEVENT_FOCUS_GAINED, true, false);
	assert(!focusGained.CancelInput);
	assert(!focusGained.ManagePause);
}

void TestPanAndTouchCancellation()
{
	TouchInputState touch;
	touch.Begin(1, {0.0f, 0.0f}, 1, 0);
	touch.Begin(2, {30.0f, 0.0f}, 2, 0);
	const std::vector<InputIntent> begin = touch.Begin(3, {60.0f, 0.0f}, 3, 0);
	assert(begin.size() == 1);
	assert(begin[0].Kind == InputIntentKind::ViewportPan);
	assert(begin[0].Phase == InputIntentPhase::Begin);
	assert(begin[0].Position.x == 30);
	assert(touch.IsPanning());

	const std::vector<InputIntent> update = touch.Update(3, {90.0f, 0.0f}, 4, 6);
	assert(update.size() == 1);
	assert(update[0].Phase == InputIntentPhase::Update);
	assert(update[0].Position.x == 40);
	assert(update[0].Delta.x == 14);
	assert(update[0].Delta.y == 0);
	assert(update[0].Modifiers == 6);
	assert(update[0].Timestamp == 4);

	const std::vector<InputIntent> cancel = touch.Cancel(5, 7);
	assert(cancel.size() == 1);
	assert(cancel[0].Phase == InputIntentPhase::Cancel);
	assert(cancel[0].Position.x == 40);
	assert(cancel[0].Modifiers == 7);
	assert(cancel[0].Timestamp == 5);
	assert(!touch.IsPanning());
	assert(!touch.SuppressPointerEvents());
	assert(touch.ContactCount() == 0);
}

void TestControllerDeviceRegistry()
{
	ControllerDeviceRegistry devices;
	assert(devices.Connect(10));
	assert(!devices.Connect(10));
	assert(devices.Size() == 1);
	assert(devices.IsActive(10));
	assert(devices.Connect(20));
	assert(devices.Size() == 2);
	assert(devices.Activate(20));
	assert(devices.IsActive(20));
	assert(devices.Disconnect(20));
	assert(devices.IsActive(10));
	assert(!devices.Disconnect(20));
	assert(devices.Disconnect(10));
	assert(!devices.Active());
}

void TestControllerDeadZoneAndCurve()
{
	assert(ControllerInputState::ShapeRadial(0.19f, 0.0f, 0.2f, 1.6f, 100.0f).x == 0);
	const InputDelta curved = ControllerInputState::ShapeRadial(0.6f, 0.0f, 0.2f, 1.6f, 100.0f);
	assert(curved.x > 30 && curved.x < 35);
	const InputDelta diagonal = ControllerInputState::ShapeRadial(1.0f, 1.0f, 0.2f, 1.6f, 100.0f);
	assert(std::abs(diagonal.x - diagonal.y) <= 1);
	assert(diagonal.x > 69 && diagonal.x < 72);
}

InputPoint SimulateCursor(std::uint32_t frameTime)
{
	ControllerInputState controller;
	controller.SetAxis(ControllerAxis::LeftX, 1.0f, 0);
	InputPoint cursor{100, 100};
	controller.Update(0, 2000, 1000, cursor);
	for (std::uint32_t timestamp = frameTime; timestamp <= 1000; timestamp += frameTime) {
		for (const InputIntent &intent : controller.Update(timestamp, 2000, 1000, cursor)) {
			if (intent.Kind == InputIntentKind::PointerMotion) {
				cursor = intent.Position;
			}
		}
	}
	return cursor;
}

InputDelta SimulateCameraPan(std::uint32_t frameTime)
{
	ControllerInputState controller;
	controller.SetAxis(ControllerAxis::RightX, 1.0f, 0);
	controller.Update(0, 2000, 1000, {1000, 500});
	InputDelta total;
	for (std::uint32_t timestamp = frameTime; timestamp <= 1000; timestamp += frameTime) {
		for (const InputIntent &intent : controller.Update(timestamp, 2000, 1000, {1000, 500})) {
			if (intent.Kind == InputIntentKind::ViewportPan
			    && intent.Phase == InputIntentPhase::Update) {
				total.x += intent.Delta.x;
				total.y += intent.Delta.y;
			}
		}
	}
	return total;
}

void TestControllerCursorBoundsAndFrameRate()
{
	const InputPoint sixtyFps = SimulateCursor(10);
	const InputPoint thirtyFps = SimulateCursor(20);
	assert(std::abs(sixtyFps.x - thirtyFps.x) <= 10);
	assert(sixtyFps.y == 100);

	ControllerInputState controller;
	controller.SetAxis(ControllerAxis::LeftX, 1.0f, 0);
	InputPoint cursor{98, 20};
	controller.Update(0, 100, 50, cursor);
	for (std::uint32_t timestamp = 16; timestamp <= 500; timestamp += 16) {
		for (const InputIntent &intent : controller.Update(timestamp, 100, 50, cursor)) {
			if (intent.Kind == InputIntentKind::PointerMotion) {
				cursor = intent.Position;
			}
		}
	}
	assert(cursor.x == 99);
	assert(cursor.y == 20);

	const InputDelta fastPan = SimulateCameraPan(10);
	const InputDelta slowPan = SimulateCameraPan(20);
	assert(std::abs(fastPan.x - slowPan.x) <= 3);
	assert(fastPan.y == 0);

	ControllerInputState clamped;
	clamped.SetAxis(ControllerAxis::RightX, 1.0f, 0);
	clamped.Update(0, 1000, 500, {500, 250});
	const std::vector<InputIntent> delayed = clamped.Update(1000, 1000, 500, {500, 250});
	int delayedPan = 0;
	for (const InputIntent &intent : delayed) {
		if (intent.Kind == InputIntentKind::ViewportPan
		    && intent.Phase == InputIntentPhase::Update) {
			delayedPan += std::abs(intent.Delta.x);
		}
	}
	assert(delayedPan <= 36);
}

void TestControllerAxisReturnToZero()
{
	ControllerInputState controller;
	InputIntentRouter router;
	RecordingTarget target;
	controller.SetAxis(ControllerAxis::RightX, 1.0f, 0);
	controller.Update(0, 1000, 500, {500, 250});
	RouteAll(router, target, controller.Update(16, 1000, 500, {500, 250}));
	assert(router.IsViewportPanActive());

	controller.SetAxis(ControllerAxis::RightX, 0.0f, 17);
	RouteAll(router, target, controller.Update(32, 1000, 500, {500, 250}));
	assert(!router.IsViewportPanActive());
	assert(target.Intents.back().Kind == InputIntentKind::ViewportPan);
	assert(target.Intents.back().Phase == InputIntentPhase::End);

	ControllerInputState cursorController;
	InputPoint cursor{100, 100};
	cursorController.SetAxis(ControllerAxis::LeftX, 1.0f, 0);
	cursorController.Update(0, 2000, 500, cursor);
	for (std::uint32_t timestamp = 16; timestamp <= 400; timestamp += 16) {
		for (const InputIntent &intent : cursorController.Update(timestamp, 2000, 500, cursor)) {
			if (intent.Kind == InputIntentKind::PointerMotion) {
				cursor = intent.Position;
			}
		}
	}
	cursorController.SetAxis(ControllerAxis::LeftX, 0.0f, 401);
	for (std::uint32_t timestamp = 416; timestamp <= 1200; timestamp += 16) {
		for (const InputIntent &intent : cursorController.Update(timestamp, 2000, 500, cursor)) {
			if (intent.Kind == InputIntentKind::PointerMotion) {
				cursor = intent.Position;
			}
		}
	}
	const InputPoint settled = cursor;
	for (std::uint32_t timestamp = 1216; timestamp <= 1600; timestamp += 16) {
		for (const InputIntent &intent : cursorController.Update(timestamp, 2000, 500, cursor)) {
			if (intent.Kind == InputIntentKind::PointerMotion) {
				cursor = intent.Position;
			}
		}
	}
	assert(cursor.x == settled.x);
	assert(cursor.y == settled.y);
}

void TestControllerModifierCleanup()
{
	ControllerInputState controller;
	InputIntentRouter router;
	RecordingTarget target;
	const unsigned additive = static_cast<unsigned>(InputModifierCode::AdditiveSelection);

	RouteAll(router, target, controller.SetAxis(ControllerAxis::LeftTrigger, 0.8f, 1));
	assert(router.IsModifierActive(additive));
	assert(controller.ActiveModifiers() & InputModifierAdditiveSelection);
	RouteAll(router, target, controller.Cancel(2, {30, 40}));
	assert(!router.IsModifierActive(additive));
	assert(controller.ActiveModifiers() == 0);
	assert(controller.SetAxis(ControllerAxis::LeftTrigger, 0.0f, 3).empty());

	RouteAll(router, target, controller.SetAxis(ControllerAxis::LeftTrigger, 0.8f, 4));
	assert(router.IsModifierActive(additive));
}

void TestControllerContextSwitchAndCancellationRecovery()
{
	ControllerInputState controller;
	InputIntentRouter router;
	RecordingTarget target;
	controller.Update(0, 100, 100, {40, 50});

	RouteAll(router, target, controller.SetButton(ControllerButton::Confirm, true, 1));
	assert(router.IsPointerButtonActive(InputPrimaryButton));
	RouteAll(router, target, controller.Cancel(2, {40, 50}));
	assert(!router.IsPointerButtonActive(InputPrimaryButton));
	assert(target.Intents.back().Phase == InputIntentPhase::Cancel);

	controller.SetContext(ControllerInputContext::Menu);
	assert(controller.SetButton(ControllerButton::Confirm, false, 3).empty());
	const std::vector<InputIntent> confirm =
		controller.SetButton(ControllerButton::Confirm, true, 4);
	assert(confirm.size() == 1);
	assert(confirm[0].Kind == InputIntentKind::ControllerAction);
	assert(confirm[0].Code == static_cast<unsigned>(ControllerActionCode::Confirm));
	RouteAll(router, target, confirm);
	assert(router.IsControllerActionActive(confirm[0].Code));
	RouteAll(router, target, controller.SetButton(ControllerButton::Confirm, false, 5));
	assert(!router.IsControllerActionActive(confirm[0].Code));
}

void TestDisconnectDuringContextCommand()
{
	ControllerInputState controller;
	InputIntentRouter router;
	RecordingTarget target;
	controller.Update(0, 100, 100, {25, 30});

	RouteAll(router, target, controller.SetButton(ControllerButton::ContextCommand, true, 1));
	assert(router.IsPointerButtonActive(InputContextButton));
	RouteAll(router, target, controller.Cancel(2, {25, 30}));
	assert(!router.IsPointerButtonActive(InputContextButton));
	assert(target.Intents.back().Kind == InputIntentKind::PointerButton);
	assert(target.Intents.back().Phase == InputIntentPhase::Cancel);
	assert(controller.SetButton(ControllerButton::ContextCommand, false, 3).empty());

	RouteAll(router, target, controller.SetButton(ControllerButton::ContextCommand, true, 4));
	RouteAll(router, target, controller.SetButton(ControllerButton::ContextCommand, false, 5));
	assert(!router.IsPointerButtonActive(InputContextButton));
	assert(target.Intents.back().Phase == InputIntentPhase::End);
	assert(target.Intents.back().Timestamp == 5);
}

void TestControllerMenuRepeat()
{
	ControllerInputState controller;
	controller.SetContext(ControllerInputContext::Menu);
	const std::vector<InputIntent> begin =
		controller.SetButton(ControllerButton::DpadDown, true, 100);
	assert(begin.size() == 1);
	assert(begin[0].Phase == InputIntentPhase::Begin);
	assert(begin[0].Code == static_cast<unsigned>(ControllerActionCode::NavigateDown));
	assert(controller.SetButton(ControllerButton::DpadDown, true, 101).empty());
	assert(controller.Update(449, 100, 100, {}).empty());
	const std::vector<InputIntent> repeat = controller.Update(450, 100, 100, {});
	assert(repeat.size() == 1);
	assert(repeat[0].Phase == InputIntentPhase::Update);
	const std::vector<InputIntent> end =
		controller.SetButton(ControllerButton::DpadDown, false, 451);
	assert(end.size() == 1);
	assert(end[0].Phase == InputIntentPhase::End);
	assert(controller.Update(1000, 100, 100, {}).empty());
}

void TestControllerUnsupportedGameplayMappings()
{
	ControllerInputState controller;
	assert(controller.SetButton(ControllerButton::LeftShoulder, true, 1).empty());
	assert(controller.SetButton(ControllerButton::RightShoulder, true, 2).empty());
	assert(controller.SetButton(ControllerButton::DpadUp, true, 3).empty());
}

void TestSdlControllerAdapter()
{
	ControllerInputState controller;
	SDL_ControllerAxisEvent axis{};
	axis.axis = SDL_CONTROLLER_AXIS_TRIGGERLEFT;
	axis.value = 32767;
	const std::vector<InputIntent> modifier = AdaptSdlControllerAxisEvent(controller, axis, 10);
	assert(modifier.size() == 1);
	assert(modifier[0].Kind == InputIntentKind::Modifier);

	SDL_ControllerButtonEvent button{};
	button.button = SDL_CONTROLLER_BUTTON_X;
	button.state = SDL_PRESSED;
	const std::vector<InputIntent> context = AdaptSdlControllerButtonEvent(controller, button, 11);
	assert(context.size() == 1);
	assert(context[0].Kind == InputIntentKind::PointerButton);
	assert(context[0].Code == InputContextButton);
	assert(context[0].Modifiers & InputModifierAdditiveSelection);
	assert(context[0].Source == InputIntentSource::Controller);
}

} // namespace

int main(int argc, char **)
{
	if (argc > 1) {
		return AssertionsAreActive() ? 0 : 1;
	}
	TestRouterPropagation();
	TestRouterPhasesAndCancellation();
	TestDelayedPointerEndAfterCancellation();
	TestCrossSourcePointerButtonOwnership();
	TestControllerCancelRetainsPointerOwner();
	TestReversePointerOwnershipAndContextButton();
	TestFocusCancellationClearsAllButtonOwners();
	TestSourceSpecificTouchCancellationRetainsMouse();
	TestVisionControlButtonPairing();
	TestVisionControlAdditiveSelection();
	TestTwoFingerContextAction();
	TestContextMovementTolerance();
	TestPendingContextCancellation();
	TestSdlTouchCancellationAdapter();
	TestFocusLossPolicy();
	TestPanAndTouchCancellation();
	TestControllerDeviceRegistry();
	TestControllerDeadZoneAndCurve();
	TestControllerCursorBoundsAndFrameRate();
	TestControllerAxisReturnToZero();
	TestControllerModifierCleanup();
	TestControllerContextSwitchAndCancellationRecovery();
	TestDisconnectDuringContextCommand();
	TestControllerMenuRepeat();
	TestControllerUnsupportedGameplayMappings();
	TestSdlControllerAdapter();
	return 0;
}
