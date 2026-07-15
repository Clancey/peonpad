#include "input_intent.h"
#include "sdl_input_adapter.h"

#include <cassert>
#include <vector>

namespace {

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

void TestRouterPropagation()
{
	InputIntentRouter router;
	RecordingTarget target;
	const InputIntent motion{
		InputIntentKind::PointerMotion,
		InputIntentPhase::Update,
		{23, 42},
		{-4, 8},
		5,
		1234
	};

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

	assert(router.Route({InputIntentKind::PointerButton, InputIntentPhase::Begin,
	                     {10, 20}, {}, 1, 100, InputPrimaryButton}, target));
	assert(router.IsPointerButtonActive(InputPrimaryButton));
	assert(router.Route({InputIntentKind::ViewportPan, InputIntentPhase::Begin,
	                     {30, 40}, {}, 2, 110}, target));
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
	assert(!router.Route({InputIntentKind::ViewportPan, InputIntentPhase::Update,
	                      {}, {2, 3}, 0, 130}, target));
	assert(target.Intents.size() == count);

	target.Accept = false;
	assert(!router.Route({InputIntentKind::ViewportPan, InputIntentPhase::Begin,
	                      {1, 2}, {}, 0, 140}, target));
	assert(!router.IsViewportPanActive());
}

void TestDelayedPointerEndAfterCancellation()
{
	InputIntentRouter router;
	RecordingTarget target;

	assert(router.Route({InputIntentKind::PointerButton, InputIntentPhase::Begin,
	                     {10, 20}, {}, 0, 1, InputPrimaryButton}, target));
	router.CancelPointer(target, 2, 0, {10, 20});
	assert(target.Intents.size() == 2);
	assert(target.Intents.back().Phase == InputIntentPhase::Cancel);

	assert(!router.Route({InputIntentKind::PointerButton, InputIntentPhase::End,
	                      {10, 20}, {}, 0, 3, InputPrimaryButton}, target));
	assert(target.Intents.size() == 2);

	assert(router.Route({InputIntentKind::PointerButton, InputIntentPhase::Begin,
	                     {30, 40}, {}, 0, 4, InputPrimaryButton}, target));
	assert(router.Route({InputIntentKind::PointerButton, InputIntentPhase::End,
	                     {30, 40}, {}, 0, 5, InputPrimaryButton}, target));
	assert(target.Intents.size() == 4);
	assert(target.Intents.back().Phase == InputIntentPhase::End);
	assert(target.Intents.back().Timestamp == 5);
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
	const std::vector<InputIntent> second =
		AdaptSdlTouchEvent(touch, event, 1000, 500, 2, 4);
	assert(second.size() == 1);
	assert(second[0].Position.x == 200);
	assert(second[0].Position.y == 300);
	assert(second[0].Modifiers == 4);
	assert(second[0].Timestamp == 2);
	assert(touch.HasPendingContextAction());

	event.type = SDL_FINGERCANCEL;
	const std::vector<InputIntent> canceled =
		AdaptSdlTouchEvent(touch, event, 1000, 500, 3, 0);
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

} // namespace

int main()
{
	TestRouterPropagation();
	TestRouterPhasesAndCancellation();
	TestDelayedPointerEndAfterCancellation();
	TestTwoFingerContextAction();
	TestContextMovementTolerance();
	TestPendingContextCancellation();
	TestSdlTouchCancellationAdapter();
	TestFocusLossPolicy();
	TestPanAndTouchCancellation();
	return 0;
}
