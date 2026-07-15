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
	Key
};

enum class InputIntentPhase {
	Begin,
	Update,
	End,
	Cancel
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
};

constexpr unsigned InputPrimaryButton = 1;
constexpr unsigned InputContextButton = 3;

class InputIntentTarget
{
public:
	virtual ~InputIntentTarget() = default;
	virtual bool Dispatch(const InputIntent &intent) = 0;
};

class InputIntentRouter
{
public:
	bool Route(const InputIntent &intent, InputIntentTarget &target);
	void CancelPointer(InputIntentTarget &target, std::uint32_t timestamp,
	                   int modifiers, InputPoint position);

	bool IsPointerButtonActive(unsigned button) const;
	bool IsViewportPanActive() const { return ViewportPanActive; }

private:
	std::set<unsigned> ActivePointerButtons;
	bool ViewportPanActive = false;
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
