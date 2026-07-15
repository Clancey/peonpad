#include "input_intent.h"

#include <cmath>

namespace {

constexpr int ContextMovementTolerance = 16;
constexpr float PanGain = 1.35f;

} // namespace

InputButtonOwnershipChange InputButtonOwnership::Press(InputIntentSource source,
                                                       unsigned button)
{
	std::set<InputIntentSource> &owners = Owners[button];
	if (!owners.insert(source).second) {
		return InputButtonOwnershipChange::Ignored;
	}
	return owners.size() == 1
		? InputButtonOwnershipChange::EffectivePress
		: InputButtonOwnershipChange::Retained;
}

InputButtonOwnershipChange InputButtonOwnership::Release(InputIntentSource source,
                                                         unsigned button)
{
	const auto owners = Owners.find(button);
	if (owners == Owners.end() || owners->second.erase(source) == 0) {
		return InputButtonOwnershipChange::Ignored;
	}
	if (!owners->second.empty()) {
		return InputButtonOwnershipChange::Retained;
	}
	Owners.erase(owners);
	return InputButtonOwnershipChange::EffectiveRelease;
}

bool InputButtonOwnership::HasOwner(InputIntentSource source, unsigned button) const
{
	const auto owners = Owners.find(button);
	return owners != Owners.end()
	    && owners->second.find(source) != owners->second.end();
}

bool InputButtonOwnership::HasAnyOwner(unsigned button) const
{
	return Owners.find(button) != Owners.end();
}

std::size_t InputButtonOwnership::OwnerCount(unsigned button) const
{
	const auto owners = Owners.find(button);
	return owners == Owners.end() ? 0 : owners->second.size();
}

bool InputIntentRouter::Route(const InputIntent &intent, InputIntentTarget &target)
{
	switch (intent.Kind) {
		case InputIntentKind::PointerMotion:
			return intent.Phase == InputIntentPhase::Update && target.Dispatch(intent);
		case InputIntentKind::PointerButton:
		{
			const std::pair<InputIntentSource, unsigned> button{
				intent.Source, intent.Code};
			if (intent.Phase == InputIntentPhase::Begin) {
				if (!ActivePointerButtons.insert(button).second) {
					return false;
				}
				const bool handled = target.Dispatch(intent);
				if (!handled) {
					ActivePointerButtons.erase(button);
				}
				return handled;
			}
			if (intent.Phase == InputIntentPhase::End) {
				if (ActivePointerButtons.find(button) == ActivePointerButtons.end()) {
					return false;
				}
				const bool handled = target.Dispatch(intent);
				ActivePointerButtons.erase(button);
				return handled;
			}
			if (intent.Phase == InputIntentPhase::Cancel) {
				if (ActivePointerButtons.find(button) == ActivePointerButtons.end()) {
					return false;
				}
				const bool handled = target.Dispatch(intent);
				ActivePointerButtons.erase(button);
				return handled;
			}
			return false;
		}
		case InputIntentKind::PointerExit:
			return intent.Phase == InputIntentPhase::Cancel && target.Dispatch(intent);
		case InputIntentKind::ViewportPan:
			if (intent.Phase == InputIntentPhase::Begin) {
				if (!ActiveViewportPans.insert(intent.Source).second) {
					return false;
				}
				const bool handled = target.Dispatch(intent);
				if (!handled) {
					ActiveViewportPans.erase(intent.Source);
				}
				return handled;
			}
			if (!IsViewportPanActive(intent.Source)) {
				return false;
			}
			if (intent.Phase == InputIntentPhase::Update) {
				return target.Dispatch(intent);
			}
			if (intent.Phase == InputIntentPhase::End
			    || intent.Phase == InputIntentPhase::Cancel) {
				const bool handled = target.Dispatch(intent);
				ActiveViewportPans.erase(intent.Source);
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
	const std::set<InputIntentSource> pans = ActiveViewportPans;
	for (const InputIntentSource source : pans) {
		Route({InputIntentKind::ViewportPan, InputIntentPhase::Cancel, position, {},
		       modifiers, timestamp, 0, 0, source}, target);
	}

	const std::set<std::pair<InputIntentSource, unsigned>> buttons =
		ActivePointerButtons;
	for (const auto &[source, button] : buttons) {
		Route({InputIntentKind::PointerButton, InputIntentPhase::Cancel, position, {},
		       modifiers, timestamp, button, 0, source}, target);
	}
}

void InputIntentRouter::CancelPointer(InputIntentTarget &target,
                                      std::uint32_t timestamp, int modifiers,
                                      InputPoint position,
                                      InputIntentSource source)
{
	if (IsViewportPanActive(source)) {
		Route({InputIntentKind::ViewportPan, InputIntentPhase::Cancel, position, {},
		       modifiers, timestamp, 0, 0, source}, target);
	}

	const std::set<std::pair<InputIntentSource, unsigned>> buttons =
		ActivePointerButtons;
	for (const auto &[buttonSource, button] : buttons) {
		if (buttonSource == source) {
			Route({InputIntentKind::PointerButton, InputIntentPhase::Cancel,
			       position, {}, modifiers, timestamp, button, 0, source},
			      target);
		}
	}
}

bool InputIntentRouter::IsPointerButtonActive(unsigned button) const
{
	for (const auto &[source, activeButton] : ActivePointerButtons) {
		(void)source;
		if (activeButton == button) {
			return true;
		}
	}
	return false;
}

bool InputIntentRouter::IsPointerButtonActive(InputIntentSource source,
                                              unsigned button) const
{
	return ActivePointerButtons.find({source, button})
	    != ActivePointerButtons.end();
}

bool InputIntentRouter::IsViewportPanActive(InputIntentSource source) const
{
	return ActiveViewportPans.find(source) != ActiveViewportPans.end();
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
	return {kind, phase, position, delta, modifiers, timestamp, code, 0,
	        InputIntentSource::Touch};
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
