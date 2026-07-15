#ifndef CONTROLLER_INPUT_H
#define CONTROLLER_INPUT_H

#include "input_intent.h"

#include <cstdint>
#include <optional>
#include <set>
#include <vector>

enum class ControllerInputContext
{
	Gameplay,
	Menu
};

enum class ControllerAxis
{
	LeftX,
	LeftY,
	RightX,
	RightY,
	LeftTrigger,
	RightTrigger
};

enum class ControllerButton
{
	Confirm,
	Cancel,
	ContextCommand,
	ContextSurface,
	LeftShoulder,
	RightShoulder,
	DpadUp,
	DpadDown,
	DpadLeft,
	DpadRight,
	Menu
};

struct ControllerInputConfig
{
	float CursorDeadZone = 0.20f;
	float CameraDeadZone = 0.24f;
	float ResponseExponent = 1.6f;
	float CursorAcceleration = 2400.0f;
	float CursorMaximumSpeed = 900.0f;
	float CameraMaximumSpeed = 720.0f;
	float TriggerThreshold = 0.55f;
	std::uint32_t MaximumFrameTime = 50;
	std::uint32_t MenuRepeatDelay = 350;
	std::uint32_t MenuRepeatInterval = 100;
};

class ControllerDeviceRegistry
{
public:
	bool Connect(int instanceId);
	bool Disconnect(int instanceId);
	bool Activate(int instanceId);

	bool Contains(int instanceId) const;
	bool IsActive(int instanceId) const;
	std::optional<int> Active() const { return ActiveInstance; }
	std::size_t Size() const { return Instances.size(); }
	void Clear();

private:
	std::set<int> Instances;
	std::optional<int> ActiveInstance;
};

class ControllerInputState
{
public:
	explicit ControllerInputState(ControllerInputConfig config = {});

	void SetContext(ControllerInputContext context);
	ControllerInputContext Context() const { return CurrentContext; }

	std::vector<InputIntent> SetAxis(ControllerAxis axis, float value, std::uint32_t timestamp);
	std::vector<InputIntent>
	SetButton(ControllerButton button, bool pressed, std::uint32_t timestamp);
	std::vector<InputIntent>
	Update(std::uint32_t timestamp, int width, int height, InputPoint cursorPosition);
	std::vector<InputIntent> Cancel(std::uint32_t timestamp, InputPoint cursorPosition);

	int ActiveModifiers() const;
	bool IsButtonPressed(ControllerButton button) const;

	static InputDelta ShapeRadial(float x, float y, float deadZone, float exponent, float scale);

private:
	struct AxisPair
	{
		float X = 0.0f;
		float Y = 0.0f;
	};

	InputIntent MakeIntent(InputIntentKind kind,
	                       InputIntentPhase phase,
	                       InputPoint position,
	                       InputDelta delta,
	                       std::uint32_t timestamp,
	                       unsigned code = 0) const;
	std::vector<InputIntent>
	UpdateTrigger(ControllerAxis axis, float value, std::uint32_t timestamp);
	std::vector<InputIntent> UpdateMenuDirection(std::uint32_t timestamp);
	std::optional<ControllerActionCode> DesiredMenuDirection() const;
	std::vector<InputIntent>
	ButtonIntent(ControllerButton button, bool pressed, std::uint32_t timestamp);
	void ResetMotion();

	ControllerInputConfig Config;
	ControllerInputContext CurrentContext = ControllerInputContext::Gameplay;
	AxisPair LeftStick;
	AxisPair RightStick;
	std::set<ControllerButton> PressedButtons;
	std::set<InputModifierCode> PressedModifiers;
	std::optional<ControllerActionCode> MenuDirection;
	std::uint32_t NextMenuRepeat = 0;
	std::uint32_t LastUpdate = 0;
	bool HasLastUpdate = false;
	bool CameraPanActive = false;
	float CursorVelocityX = 0.0f;
	float CursorVelocityY = 0.0f;
	float CursorRemainderX = 0.0f;
	float CursorRemainderY = 0.0f;
	float CameraRemainderX = 0.0f;
	float CameraRemainderY = 0.0f;
	InputPoint CursorPosition;
};

#endif
