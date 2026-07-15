#ifndef INPUT_INTENT_H
#define INPUT_INTENT_H

#include <cstddef>
#include <cstdint>
#include <iterator>
#include <map>
#include <set>
#include <vector>

enum class InputIntentKind {
	PointerMotion,
	PointerButton,
	PointerExit,
	ViewportPan,
	Key,
	ControllerAction,
	Modifier
};

enum class InputIntentPhase {
	Begin,
	Update,
	End,
	Cancel
};

enum class InputIntentSource {
	Mouse,
	Touch,
	Controller
};

struct InputPoint {
	int x = 0;
	int y = 0;
};

struct InputDelta {
	int x = 0;
	int y = 0;
};

struct InputIntent {
	InputIntentKind Kind = InputIntentKind::PointerMotion;
	InputIntentPhase Phase = InputIntentPhase::Update;
	InputPoint Position;
	InputDelta Delta;
	int Modifiers = 0;
	std::uint32_t Timestamp = 0;
	unsigned Code = 0;
	unsigned Character = 0;
	InputIntentSource Source = InputIntentSource::Mouse;
};

constexpr unsigned InputPrimaryButton = 1;
constexpr unsigned InputContextButton = 3;
constexpr int InputModifierAdditiveSelection = 1 << 8;
constexpr int InputModifierQueuedOrder = 1 << 9;

enum class InputModifierCode : unsigned {
	AdditiveSelection = 1,
	QueuedOrder
};

enum class ControllerActionCode : unsigned {
	Confirm = 1,
	Cancel,
	ContextSurface,
	NavigateUp,
	NavigateDown,
	NavigateLeft,
	NavigateRight,
	OpenMenu
};

class InputIntentTarget
{
public:
	virtual ~InputIntentTarget() = default;
	virtual bool Dispatch(const InputIntent &intent) = 0;
};

enum class InputButtonOwnershipChange {
	Ignored,
	Retained,
	EffectivePress,
	EffectiveRelease
};

class InputButtonOwnership
{
public:
	InputButtonOwnershipChange Press(InputIntentSource source, unsigned button);
	InputButtonOwnershipChange Release(InputIntentSource source, unsigned button);

	bool HasOwner(InputIntentSource source, unsigned button) const;
	bool HasAnyOwner(unsigned button) const;
	std::size_t OwnerCount(unsigned button) const;

private:
	std::map<unsigned, std::set<InputIntentSource>> Owners;
};

class InputIntentRouter
{
public:
	bool Route(const InputIntent &intent, InputIntentTarget &target);
	void CancelPointer(InputIntentTarget &target, std::uint32_t timestamp,
	                   int modifiers, InputPoint position);
	void CancelPointer(InputIntentTarget &target, std::uint32_t timestamp,
	                   int modifiers, InputPoint position,
	                   InputIntentSource source);

	bool IsPointerButtonActive(unsigned button) const;
	bool IsPointerButtonActive(InputIntentSource source, unsigned button) const;
	bool IsViewportPanActive() const { return !ActiveViewportPans.empty(); }
	bool IsViewportPanActive(InputIntentSource source) const;
	bool IsControllerActionActive(unsigned action) const;
	bool IsModifierActive(unsigned modifier) const;

private:
	std::set<std::pair<InputIntentSource, unsigned>> ActivePointerButtons;
	std::set<InputIntentSource> ActiveViewportPans;
	std::set<unsigned> ActiveControllerActions;
	std::set<unsigned> ActiveModifiers;
};

struct TouchPoint {
	float x = 0.0f;
	float y = 0.0f;
};

class TouchInputState
{
public:
	std::vector<InputIntent> Begin(std::int64_t contact, TouchPoint position,
	                               std::uint32_t timestamp, int modifiers);
	std::vector<InputIntent> Update(std::int64_t contact, TouchPoint position,
	                                std::uint32_t timestamp, int modifiers);
	std::vector<InputIntent> End(std::int64_t contact, TouchPoint position,
	                             std::uint32_t timestamp, int modifiers);
	std::vector<InputIntent> Cancel(std::uint32_t timestamp, int modifiers);

	bool SuppressPointerEvents() const { return SuppressPointer; }
	bool HasPendingContextAction() const { return PendingContextAction; }
	bool IsPanning() const { return Panning; }
	std::size_t ContactCount() const { return Contacts.size(); }

private:
	InputPoint ScreenPoint(const TouchPoint &point) const;
	TouchPoint Center() const;
	TouchPoint Leftmost() const;
	InputIntent MakeIntent(InputIntentKind kind, InputIntentPhase phase,
	                       InputPoint position, InputDelta delta,
	                       std::uint32_t timestamp, int modifiers,
	                       unsigned code = 0) const;
	void Reset();

	std::map<std::int64_t, TouchPoint> Contacts;
	std::map<std::int64_t, TouchPoint> ContextStart;
	TouchPoint PanCenter;
	bool PendingContextAction = false;
	bool Panning = false;
	bool SuppressPointer = false;
};

#endif
