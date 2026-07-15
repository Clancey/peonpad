#include "controller_input.h"

#include <algorithm>
#include <cmath>

namespace
{

float ClampAxis(float value)
{
	return std::max(-1.0f, std::min(1.0f, value));
}

float Approach(float current, float target, float amount)
{
	if (current < target) {
		return std::min(current + amount, target);
	}
	return std::max(current - amount, target);
}

unsigned ActionCode(ControllerActionCode action)
{
	return static_cast<unsigned>(action);
}

unsigned ModifierCode(InputModifierCode modifier)
{
	return static_cast<unsigned>(modifier);
}

} // namespace

bool ControllerDeviceRegistry::Connect(int instanceId)
{
	const bool inserted = Instances.insert(instanceId).second;
	if (inserted && !ActiveInstance) {
		ActiveInstance = instanceId;
	}
	return inserted;
}

bool ControllerDeviceRegistry::Disconnect(int instanceId)
{
	if (Instances.erase(instanceId) == 0) {
		return false;
	}
	if (ActiveInstance == instanceId) {
		ActiveInstance =
			Instances.empty() ? std::optional<int>{} : std::optional<int>{*Instances.begin()};
	}
	return true;
}

bool ControllerDeviceRegistry::Activate(int instanceId)
{
	if (!Contains(instanceId)) {
		return false;
	}
	const bool changed = ActiveInstance != instanceId;
	ActiveInstance = instanceId;
	return changed;
}

bool ControllerDeviceRegistry::Contains(int instanceId) const
{
	return Instances.find(instanceId) != Instances.end();
}

bool ControllerDeviceRegistry::IsActive(int instanceId) const
{
	return ActiveInstance == instanceId;
}

void ControllerDeviceRegistry::Clear()
{
	Instances.clear();
	ActiveInstance.reset();
}

ControllerInputState::ControllerInputState(ControllerInputConfig config) : Config(config)
{}

void ControllerInputState::SetContext(ControllerInputContext context)
{
	CurrentContext = context;
	ResetMotion();
}

std::vector<InputIntent>
ControllerInputState::SetAxis(ControllerAxis axis, float value, std::uint32_t timestamp)
{
	value = ClampAxis(value);
	if (CurrentContext == ControllerInputContext::Menu
	    && (axis == ControllerAxis::LeftTrigger || axis == ControllerAxis::RightTrigger)) {
		return {};
	}
	switch (axis) {
		case ControllerAxis::LeftX: LeftStick.X = value; break;
		case ControllerAxis::LeftY: LeftStick.Y = value; break;
		case ControllerAxis::RightX: RightStick.X = value; break;
		case ControllerAxis::RightY: RightStick.Y = value; break;
		case ControllerAxis::LeftTrigger:
		case ControllerAxis::RightTrigger:
			return UpdateTrigger(axis, std::max(0.0f, value), timestamp);
	}
	if (CurrentContext == ControllerInputContext::Menu
	    && (axis == ControllerAxis::LeftX || axis == ControllerAxis::LeftY)) {
		return UpdateMenuDirection(timestamp);
	}
	return {};
}

std::vector<InputIntent>
ControllerInputState::SetButton(ControllerButton button, bool pressed, std::uint32_t timestamp)
{
	const bool wasPressed = IsButtonPressed(button);
	if (wasPressed == pressed) {
		return {};
	}
	if (pressed) {
		PressedButtons.insert(button);
	} else {
		PressedButtons.erase(button);
	}

	if (CurrentContext == ControllerInputContext::Menu
	    && (button == ControllerButton::DpadUp || button == ControllerButton::DpadDown
	        || button == ControllerButton::DpadLeft || button == ControllerButton::DpadRight)) {
		return UpdateMenuDirection(timestamp);
	}
	return ButtonIntent(button, pressed, timestamp);
}

std::vector<InputIntent> ControllerInputState::Update(std::uint32_t timestamp,
                                                      int width,
                                                      int height,
                                                      InputPoint cursorPosition)
{
	std::vector<InputIntent> intents;
	CursorPosition = cursorPosition;
	if (CurrentContext == ControllerInputContext::Menu) {
		if (MenuDirection && timestamp >= NextMenuRepeat) {
			do {
				intents.push_back(MakeIntent(InputIntentKind::ControllerAction,
				                             InputIntentPhase::Update,
				                             cursorPosition,
				                             {},
				                             timestamp,
				                             ActionCode(*MenuDirection)));
				NextMenuRepeat += Config.MenuRepeatInterval;
			} while (timestamp >= NextMenuRepeat);
		}
		LastUpdate = timestamp;
		HasLastUpdate = true;
		return intents;
	}

	if (!HasLastUpdate) {
		LastUpdate = timestamp;
		HasLastUpdate = true;
		return intents;
	}
	const std::uint32_t elapsed = std::min(timestamp - LastUpdate, Config.MaximumFrameTime);
	LastUpdate = timestamp;
	if (elapsed == 0 || width <= 0 || height <= 0) {
		return intents;
	}
	const float seconds = elapsed / 1000.0f;

	const InputDelta cursorTarget = ShapeRadial(LeftStick.X,
	                                            LeftStick.Y,
	                                            Config.CursorDeadZone,
	                                            Config.ResponseExponent,
	                                            Config.CursorMaximumSpeed);
	const float acceleration = Config.CursorAcceleration * seconds;
	CursorVelocityX = Approach(CursorVelocityX, cursorTarget.x, acceleration);
	CursorVelocityY = Approach(CursorVelocityY, cursorTarget.y, acceleration);
	CursorRemainderX += CursorVelocityX * seconds;
	CursorRemainderY += CursorVelocityY * seconds;
	const int cursorDeltaX = static_cast<int>(std::trunc(CursorRemainderX));
	const int cursorDeltaY = static_cast<int>(std::trunc(CursorRemainderY));
	CursorRemainderX -= cursorDeltaX;
	CursorRemainderY -= cursorDeltaY;

	InputPoint nextCursor{std::max(0, std::min(width - 1, cursorPosition.x + cursorDeltaX)),
	                      std::max(0, std::min(height - 1, cursorPosition.y + cursorDeltaY))};
	if (nextCursor.x != cursorPosition.x || nextCursor.y != cursorPosition.y) {
		if (nextCursor.x == 0 || nextCursor.x == width - 1) {
			CursorRemainderX = 0.0f;
		}
		if (nextCursor.y == 0 || nextCursor.y == height - 1) {
			CursorRemainderY = 0.0f;
		}
		intents.push_back(
			MakeIntent(InputIntentKind::PointerMotion,
		               InputIntentPhase::Update,
		               nextCursor,
		               {nextCursor.x - cursorPosition.x, nextCursor.y - cursorPosition.y},
		               timestamp));
		CursorPosition = nextCursor;
	}

	const InputDelta cameraVelocity = ShapeRadial(RightStick.X,
	                                              RightStick.Y,
	                                              Config.CameraDeadZone,
	                                              Config.ResponseExponent,
	                                              Config.CameraMaximumSpeed);
	const bool cameraMoving = cameraVelocity.x != 0 || cameraVelocity.y != 0;
	const InputPoint panAnchor{width / 2, height / 2};
	if (cameraMoving && !CameraPanActive) {
		CameraPanActive = true;
		intents.push_back(MakeIntent(
			InputIntentKind::ViewportPan, InputIntentPhase::Begin, panAnchor, {}, timestamp));
	}
	if (cameraMoving) {
		CameraRemainderX -= cameraVelocity.x * seconds;
		CameraRemainderY -= cameraVelocity.y * seconds;
		const int cameraDeltaX = static_cast<int>(std::trunc(CameraRemainderX));
		const int cameraDeltaY = static_cast<int>(std::trunc(CameraRemainderY));
		CameraRemainderX -= cameraDeltaX;
		CameraRemainderY -= cameraDeltaY;
		if (cameraDeltaX != 0 || cameraDeltaY != 0) {
			intents.push_back(MakeIntent(InputIntentKind::ViewportPan,
			                             InputIntentPhase::Update,
			                             panAnchor,
			                             {cameraDeltaX, cameraDeltaY},
			                             timestamp));
		}
	} else if (CameraPanActive) {
		CameraPanActive = false;
		CameraRemainderX = 0.0f;
		CameraRemainderY = 0.0f;
		intents.push_back(MakeIntent(
			InputIntentKind::ViewportPan, InputIntentPhase::End, panAnchor, {}, timestamp));
	}
	return intents;
}

std::vector<InputIntent> ControllerInputState::Cancel(std::uint32_t timestamp,
                                                      InputPoint cursorPosition)
{
	CursorPosition = cursorPosition;
	std::vector<InputIntent> intents;
	if (IsButtonPressed(ControllerButton::Confirm)
	    && CurrentContext == ControllerInputContext::Gameplay) {
		intents.push_back(MakeIntent(InputIntentKind::PointerButton,
		                             InputIntentPhase::Cancel,
		                             cursorPosition,
		                             {},
		                             timestamp,
		                             InputPrimaryButton));
	}
	if (IsButtonPressed(ControllerButton::ContextCommand)
	    && CurrentContext == ControllerInputContext::Gameplay) {
		intents.push_back(MakeIntent(InputIntentKind::PointerButton,
		                             InputIntentPhase::Cancel,
		                             cursorPosition,
		                             {},
		                             timestamp,
		                             InputContextButton));
	}
	if (CameraPanActive) {
		intents.push_back(MakeIntent(
			InputIntentKind::ViewportPan, InputIntentPhase::Cancel, cursorPosition, {}, timestamp));
	}

	for (const InputModifierCode modifier : PressedModifiers) {
		intents.push_back(MakeIntent(InputIntentKind::Modifier,
		                             InputIntentPhase::Cancel,
		                             cursorPosition,
		                             {},
		                             timestamp,
		                             ModifierCode(modifier)));
	}

	if (CurrentContext == ControllerInputContext::Gameplay
	    && IsButtonPressed(ControllerButton::ContextSurface)) {
		intents.push_back(MakeIntent(InputIntentKind::ControllerAction,
		                             InputIntentPhase::Cancel,
		                             cursorPosition,
		                             {},
		                             timestamp,
		                             ActionCode(ControllerActionCode::ContextSurface)));
	} else if (CurrentContext == ControllerInputContext::Menu) {
		if (IsButtonPressed(ControllerButton::Confirm)) {
			intents.push_back(MakeIntent(InputIntentKind::ControllerAction,
			                             InputIntentPhase::Cancel,
			                             cursorPosition,
			                             {},
			                             timestamp,
			                             ActionCode(ControllerActionCode::Confirm)));
		}
		if (IsButtonPressed(ControllerButton::Cancel) || IsButtonPressed(ControllerButton::Menu)) {
			intents.push_back(MakeIntent(InputIntentKind::ControllerAction,
			                             InputIntentPhase::Cancel,
			                             cursorPosition,
			                             {},
			                             timestamp,
			                             ActionCode(ControllerActionCode::Cancel)));
		}
	}
	if (MenuDirection) {
		intents.push_back(MakeIntent(InputIntentKind::ControllerAction,
		                             InputIntentPhase::Cancel,
		                             cursorPosition,
		                             {},
		                             timestamp,
		                             ActionCode(*MenuDirection)));
	}

	PressedButtons.clear();
	PressedModifiers.clear();
	LeftStick = {};
	RightStick = {};
	MenuDirection.reset();
	ResetMotion();
	return intents;
}

int ControllerInputState::ActiveModifiers() const
{
	int modifiers = 0;
	if (PressedModifiers.find(InputModifierCode::AdditiveSelection) != PressedModifiers.end()) {
		modifiers |= InputModifierAdditiveSelection;
	}
	if (PressedModifiers.find(InputModifierCode::QueuedOrder) != PressedModifiers.end()) {
		modifiers |= InputModifierQueuedOrder;
	}
	return modifiers;
}

bool ControllerInputState::IsButtonPressed(ControllerButton button) const
{
	return PressedButtons.find(button) != PressedButtons.end();
}

InputDelta
ControllerInputState::ShapeRadial(float x, float y, float deadZone, float exponent, float scale)
{
	const float magnitude = std::sqrt(x * x + y * y);
	if (magnitude <= deadZone || magnitude == 0.0f) {
		return {};
	}
	const float clampedMagnitude = std::min(1.0f, magnitude);
	const float normalized = (clampedMagnitude - deadZone) / (1.0f - deadZone);
	const float response = std::pow(normalized, exponent) * scale;
	return {static_cast<int>(std::lround((x / magnitude) * response)),
	        static_cast<int>(std::lround((y / magnitude) * response))};
}

InputIntent ControllerInputState::MakeIntent(InputIntentKind kind,
                                             InputIntentPhase phase,
                                             InputPoint position,
                                             InputDelta delta,
                                             std::uint32_t timestamp,
                                             unsigned code) const
{
	return {kind, phase, position, delta, ActiveModifiers(), timestamp, code, 0};
}

std::vector<InputIntent>
ControllerInputState::UpdateTrigger(ControllerAxis axis, float value, std::uint32_t timestamp)
{
	const InputModifierCode modifier = axis == ControllerAxis::LeftTrigger
	                                     ? InputModifierCode::AdditiveSelection
	                                     : InputModifierCode::QueuedOrder;
	const bool pressed = value >= Config.TriggerThreshold;
	const bool wasPressed = PressedModifiers.find(modifier) != PressedModifiers.end();
	if (pressed == wasPressed) {
		return {};
	}
	if (pressed) {
		PressedModifiers.insert(modifier);
	} else {
		PressedModifiers.erase(modifier);
	}
	return {MakeIntent(InputIntentKind::Modifier,
	                   pressed ? InputIntentPhase::Begin : InputIntentPhase::End,
	                   {},
	                   {},
	                   timestamp,
	                   ModifierCode(modifier))};
}

std::vector<InputIntent> ControllerInputState::UpdateMenuDirection(std::uint32_t timestamp)
{
	const std::optional<ControllerActionCode> desired = DesiredMenuDirection();
	if (desired == MenuDirection) {
		return {};
	}
	std::vector<InputIntent> intents;
	if (MenuDirection) {
		intents.push_back(MakeIntent(InputIntentKind::ControllerAction,
		                             InputIntentPhase::End,
		                             {},
		                             {},
		                             timestamp,
		                             ActionCode(*MenuDirection)));
	}
	MenuDirection = desired;
	if (MenuDirection) {
		intents.push_back(MakeIntent(InputIntentKind::ControllerAction,
		                             InputIntentPhase::Begin,
		                             {},
		                             {},
		                             timestamp,
		                             ActionCode(*MenuDirection)));
		NextMenuRepeat = timestamp + Config.MenuRepeatDelay;
	}
	return intents;
}

std::optional<ControllerActionCode> ControllerInputState::DesiredMenuDirection() const
{
	if (IsButtonPressed(ControllerButton::DpadUp)) {
		return ControllerActionCode::NavigateUp;
	}
	if (IsButtonPressed(ControllerButton::DpadDown)) {
		return ControllerActionCode::NavigateDown;
	}
	if (IsButtonPressed(ControllerButton::DpadLeft)) {
		return ControllerActionCode::NavigateLeft;
	}
	if (IsButtonPressed(ControllerButton::DpadRight)) {
		return ControllerActionCode::NavigateRight;
	}

	constexpr float PressThreshold = 0.55f;
	constexpr float ReleaseThreshold = 0.35f;
	const float threshold = MenuDirection ? ReleaseThreshold : PressThreshold;
	if (std::abs(LeftStick.Y) >= std::abs(LeftStick.X) && std::abs(LeftStick.Y) >= threshold) {
		return LeftStick.Y < 0.0f ? ControllerActionCode::NavigateUp
		                          : ControllerActionCode::NavigateDown;
	}
	if (std::abs(LeftStick.X) >= threshold) {
		return LeftStick.X < 0.0f ? ControllerActionCode::NavigateLeft
		                          : ControllerActionCode::NavigateRight;
	}
	return std::nullopt;
}

std::vector<InputIntent>
ControllerInputState::ButtonIntent(ControllerButton button, bool pressed, std::uint32_t timestamp)
{
	const InputIntentPhase phase = pressed ? InputIntentPhase::Begin : InputIntentPhase::End;
	if (CurrentContext == ControllerInputContext::Gameplay) {
		switch (button) {
			case ControllerButton::Confirm:
				return {MakeIntent(InputIntentKind::PointerButton,
				                   phase,
				                   CursorPosition,
				                   {},
				                   timestamp,
				                   InputPrimaryButton)};
			case ControllerButton::ContextCommand:
				return {MakeIntent(InputIntentKind::PointerButton,
				                   phase,
				                   CursorPosition,
				                   {},
				                   timestamp,
				                   InputContextButton)};
			case ControllerButton::Cancel:
				return pressed
				         ? std::vector<InputIntent>{MakeIntent(
														InputIntentKind::ControllerAction,
														InputIntentPhase::Begin,
														CursorPosition,
														{},
														timestamp,
														ActionCode(ControllerActionCode::Cancel)),
				                                    MakeIntent(
														InputIntentKind::ControllerAction,
														InputIntentPhase::End,
														CursorPosition,
														{},
														timestamp,
														ActionCode(ControllerActionCode::Cancel))}
				         : std::vector<InputIntent>{};
			case ControllerButton::ContextSurface:
				return {MakeIntent(InputIntentKind::ControllerAction,
				                   phase,
				                   CursorPosition,
				                   {},
				                   timestamp,
				                   ActionCode(ControllerActionCode::ContextSurface))};
			case ControllerButton::Menu:
				return pressed
				         ? std::vector<InputIntent>{MakeIntent(
														InputIntentKind::ControllerAction,
														InputIntentPhase::Begin,
														CursorPosition,
														{},
														timestamp,
														ActionCode(ControllerActionCode::OpenMenu)),
				                                    MakeIntent(
														InputIntentKind::ControllerAction,
														InputIntentPhase::End,
														CursorPosition,
														{},
														timestamp,
														ActionCode(ControllerActionCode::OpenMenu))}
				         : std::vector<InputIntent>{};
			default: return {};
		}
	}

	switch (button) {
		case ControllerButton::Confirm:
			return {MakeIntent(InputIntentKind::ControllerAction,
			                   phase,
			                   {},
			                   {},
			                   timestamp,
			                   ActionCode(ControllerActionCode::Confirm))};
		case ControllerButton::Cancel:
		case ControllerButton::Menu:
			return {MakeIntent(InputIntentKind::ControllerAction,
			                   phase,
			                   {},
			                   {},
			                   timestamp,
			                   ActionCode(ControllerActionCode::Cancel))};
		default: return {};
	}
}

void ControllerInputState::ResetMotion()
{
	HasLastUpdate = false;
	CameraPanActive = false;
	CursorVelocityX = 0.0f;
	CursorVelocityY = 0.0f;
	CursorRemainderX = 0.0f;
	CursorRemainderY = 0.0f;
	CameraRemainderX = 0.0f;
	CameraRemainderY = 0.0f;
}
