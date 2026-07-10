#pragma once

struct SDL_Window;
struct SDL_Renderer;

void PeonPadIOSApplySafeAreaViewport(SDL_Window *window,
                                    SDL_Renderer *renderer,
                                    int logicalWidth,
                                    int logicalHeight);
