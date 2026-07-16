#pragma once

struct SDL_Renderer;
struct SDL_Window;

// Connects the public SDL3 UIKit/Metal window to the native visionOS window
// scene and requests freeform user resizing. SDL retains app/scene ownership.
bool PeonPadVisionOSConfigureShell(SDL_Window *window,
                                  SDL_Renderer *renderer);
