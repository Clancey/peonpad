#ifndef PEONPAD_IOS_CONTROL_STATE_H
#define PEONPAD_IOS_CONTROL_STATE_H

#include "input_intent.h"

class PeonPadIOSControlState
{
public:
	void ToggleContext()
	{
		ContextArmed = !ContextArmed;
	}

	void ToggleAdditive()
	{
		AdditiveEnabled = !AdditiveEnabled;
	}

	bool IsContextArmed() const
	{
		return ContextArmed;
	}

	bool IsAdditiveEnabled() const
	{
		return AdditiveEnabled;
	}

	unsigned MapPointerButton(unsigned button, bool pressed)
	{
		if (button != InputPrimaryButton) {
			return button;
		}
		if (pressed) {
			if (ActivePointerButton == 0) {
				ActivePointerButton =
					ContextArmed ? InputContextButton : InputPrimaryButton;
				ContextArmed = false;
			}
			return ActivePointerButton;
		}

		const unsigned mappedButton = ActivePointerButton == 0
			? InputPrimaryButton
			: ActivePointerButton;
		ActivePointerButton = 0;
		return mappedButton;
	}

	int ApplyPointerModifiers(int modifiers, bool pressed)
	{
		if (pressed) {
			ActiveAdditive = AdditiveEnabled;
		}
		if (ActiveAdditive) {
			modifiers |= InputModifierAdditiveSelection;
		}
		if (!pressed) {
			ActiveAdditive = false;
		}
		return modifiers;
	}

	void ResetGesture()
	{
		ContextArmed = false;
		ActivePointerButton = 0;
		ActiveAdditive = false;
	}

private:
	bool ContextArmed = false;
	bool AdditiveEnabled = false;
	unsigned ActivePointerButton = 0;
	bool ActiveAdditive = false;
};

#endif
