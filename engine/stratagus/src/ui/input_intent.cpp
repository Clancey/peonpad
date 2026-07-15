#include "input_intent.h"

#include <cmath>

namespace {

constexpr int ContextMovementTolerance = 16;
constexpr float PanGain = 1.35f;

} // namespace

bool InputIntentRouter::Route(const InputIntent &intent, InputIntentTarget &target)
{
	switch (intent.Kind) {
		case InputIntentKind::PointerMotion:
			return intent.Phase == InputIntentPhase::Update && target.Dispatch(intent);
		case InputIntentKind::PointerButton:
			if (intent.Phase == InputIntentPhase::Begin) {
				ActivePointerButtons.insert(intent.Code);
				const bool handled = target.Dispatch(intent);
				if (!handled) {
					ActivePointerButtons.erase(intent.Code);
				}
				return handled;
			}
			if (intent.Phase == InputIntentPhase::End) {
				if (!IsPointerButtonActive(intent.Code)) {
					return false;
				}
				const bool handled = target.Dispatch(intent);
				ActivePointerButtons.erase(intent.Code);
				return handled;
			}
			if (intent.Phase == InputIntentPhase::Cancel) {
				const bool handled = target.Dispatch(intent);
				ActivePointerButtons.erase(intent.Code);
				return handled;
			}
			return false;
		case InputIntentKind::PointerExit:
			return intent.Phase == InputIntentPhase::Cancel && target.Dispatch(intent);
		case InputIntentKind::ViewportPan:
			if (intent.Phase == InputIntentPhase::Begin) {
				ViewportPanActive = true;
				const bool handled = target.Dispatch(intent);
				if (!handled) {
					ViewportPanActive = false;
				}
				return handled;
			}
			if (!ViewportPanActive) {
				return false;
			}
			if (intent.Phase == InputIntentPhase::Update) {
				return target.Dispatch(intent);
			}
			if (intent.Phase == InputIntentPhase::End
			    || intent.Phase == InputIntentPhase::Cancel) {
				const bool handled = target.Dispatch(intent);
				ViewportPanActive = false;
				return handled;
			}
			return false;
		case InputIntentKind::Key:
			if (intent.Phase == InputIntentPhase::Begin
			    || intent.Phase == InputIntentPhase::End
			    || intent.Phase == InputIntentPhase::Cancel) {
				return target.Dispatch(intent);
			}
			return false;
		case InputIntentKind::ControllerAction:
		case InputIntentKind::Modifier: {
			std::set<unsigned> &active =
				intent.Kind == InputIntentKind::ControllerAction
				? ActiveControllerActions : ActiveModifiers;
			if (intent.Phase == InputIntentPhase::Begin) {
				active.insert(intent.Code);
				const bool handled = target.Dispatch(intent);
				if (!handled) {
					active.erase(intent.Code);
				}
				return handled;
			}
			if (intent.Phase == InputIntentPhase::Update) {
				return active.find(intent.Code) != active.end()
				    && target.Dispatch(intent);
			}
			if (intent.Phase == InputIntentPhase::End
			    || intent.Phase == InputIntentPhase::Cancel) {
				if (active.find(intent.Code) == active.end()) {
					return false;
				}
				const bool handled = target.Dispatch(intent);
				active.erase(intent.Code);
				return handled;
			}
			return false;
		}
	}
	return false;
}

void InputIntentRouter::CancelPointer(InputIntentTarget &target, std::uint32_t timestamp,
                                      int modifiers, InputPoint position)
{
	if (ViewportPanActive) {
		Route({InputIntentKind::ViewportPan, InputIntentPhase::Cancel, position, {},
		       modifiers, timestamp}, target);
	}

	const std::set<unsigned> buttons = ActivePointerButtons;
	for (const unsigned button : buttons) {
		Route({InputIntentKind::PointerButton, InputIntentPhase::Cancel, position, {},
		       modifiers, timestamp, button}, target);
	}
}

bool InputIntentRouter::IsPointerButtonActive(unsigned button) const
{
	return ActivePointerButtons.find(button) != ActivePointerButtons.end();
}

bool InputIntentRouter::IsControllerActionActive(unsigned action) const
{
	return ActiveControllerActions.find(action) != ActiveControllerActions.end();
}

bool InputIntentRouter::IsModifierActive(unsigned modifier) const
{
	return ActiveModifiers.find(modifier) != ActiveModifiers.end();
}

std::vector<InputIntent> TouchInputState::Begin(std::int64_t contact, TouchPoint position,
                                                std::uint32_t timestamp, int modifiers)
{
	Contacts[contact] = position;
	if (Contacts.size() == 2) {
		ContextStart = Contacts;
		PendingContextAction = true;
		SuppressPointer = true;
		return {MakeIntent(InputIntentKind::PointerButton, InputIntentPhase::Cancel,
		                   ScreenPoint(position), {}, timestamp, modifiers,
		                   InputPrimaryButton)};
	}
	if (Contacts.size() == 3) {
		PendingContextAction = false;
		Panning = true;
		PanCenter = Center();
		return {MakeIntent(InputIntentKind::ViewportPan, InputIntentPhase::Begin,
		                   ScreenPoint(PanCenter), {}, timestamp, modifiers)};
	}
	return {};
}

std::vector<InputIntent> TouchInputState::Update(std::int64_t contact, TouchPoint position,
                                                 std::uint32_t timestamp, int modifiers)
{
	const auto current = Contacts.find(contact);
	if (current == Contacts.end()) {
		return {};
	}
	current->second = position;

	if (Panning && Contacts.size() == 3) {
		const TouchPoint center = Center();
		const InputDelta delta{
			static_cast<int>(std::lround((center.x - PanCenter.x) * PanGain)),
			static_cast<int>(std::lround((center.y - PanCenter.y) * PanGain))
		};
		PanCenter = center;
		return {MakeIntent(InputIntentKind::ViewportPan, InputIntentPhase::Update,
		                   ScreenPoint(center), delta, timestamp, modifiers)};
	}

	if (PendingContextAction && Contacts.size() == 2) {
		for (const auto &[id, start] : ContextStart) {
			const auto touch = Contacts.find(id);
			if (touch == Contacts.end()) {
				continue;
			}
			const InputPoint startPoint = ScreenPoint(start);
			const InputPoint currentPoint = ScreenPoint(touch->second);
			if (std::abs(currentPoint.x - startPoint.x) > ContextMovementTolerance
			    || std::abs(currentPoint.y - startPoint.y) > ContextMovementTolerance) {
				PendingContextAction = false;
				break;
			}
		}
	}
	return {};
}

std::vector<InputIntent> TouchInputState::End(std::int64_t contact, TouchPoint position,
                                              std::uint32_t timestamp, int modifiers)
{
	const auto current = Contacts.find(contact);
	if (current == Contacts.end()) {
		return {};
	}
	current->second = position;

	std::vector<InputIntent> intents;
	if (PendingContextAction && Contacts.size() == 2) {
		const InputPoint target = ScreenPoint(Leftmost());
		intents.push_back(MakeIntent(InputIntentKind::PointerButton,
		                             InputIntentPhase::Begin, target, {},
		                             timestamp, modifiers, InputContextButton));
		intents.push_back(MakeIntent(InputIntentKind::PointerButton,
		                             InputIntentPhase::End, target, {},
		                             timestamp, modifiers, InputContextButton));
		PendingContextAction = false;
	}
	if (Panning && Contacts.size() == 3) {
		intents.push_back(MakeIntent(InputIntentKind::ViewportPan,
		                             InputIntentPhase::End, ScreenPoint(Center()), {},
		                             timestamp, modifiers));
		Panning = false;
	}

	Contacts.erase(current);
	if (Contacts.empty()) {
		SuppressPointer = false;
		ContextStart.clear();
	}
	return intents;
}

std::vector<InputIntent> TouchInputState::Cancel(std::uint32_t timestamp, int modifiers)
{
	std::vector<InputIntent> intents;
	if (Panning) {
		intents.push_back(MakeIntent(InputIntentKind::ViewportPan,
		                             InputIntentPhase::Cancel, ScreenPoint(PanCenter), {},
		                             timestamp, modifiers));
	}
	Reset();
	return intents;
}

InputPoint TouchInputState::ScreenPoint(const TouchPoint &point) const
{
	return {static_cast<int>(std::lround(point.x)),
	        static_cast<int>(std::lround(point.y))};
}

TouchPoint TouchInputState::Center() const
{
	TouchPoint center;
	for (const auto &[contact, point] : Contacts) {
		(void)contact;
		center.x += point.x;
		center.y += point.y;
	}
	center.x /= Contacts.size();
	center.y /= Contacts.size();
	return center;
}

TouchPoint TouchInputState::Leftmost() const
{
	auto leftmost = Contacts.begin();
	for (auto touch = std::next(leftmost); touch != Contacts.end(); ++touch) {
		if (touch->second.x < leftmost->second.x) {
			leftmost = touch;
		}
	}
	return leftmost->second;
}

InputIntent TouchInputState::MakeIntent(InputIntentKind kind, InputIntentPhase phase,
                                        InputPoint position, InputDelta delta,
                                        std::uint32_t timestamp, int modifiers,
                                        unsigned code) const
{
	return {kind, phase, position, delta, modifiers, timestamp, code, 0};
}

void TouchInputState::Reset()
{
	Contacts.clear();
	ContextStart.clear();
	PanCenter = {};
	PendingContextAction = false;
	Panning = false;
	SuppressPointer = false;
}
