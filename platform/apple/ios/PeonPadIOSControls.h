#ifndef PEONPAD_IOS_CONTROLS_H
#define PEONPAD_IOS_CONTROLS_H

#include <SDL_video.h>

void PeonPadIOSInstallControlDock(SDL_Window *window);
int PeonPadIOSControlDockInsetPoints();
unsigned PeonPadIOSMapPointerButton(unsigned button, bool pressed);
bool PeonPadIOSUseAdditiveModifier(bool pressed);
void PeonPadIOSResetTouchControls();

#endif
