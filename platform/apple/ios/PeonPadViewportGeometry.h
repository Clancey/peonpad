#pragma once

struct PeonPadPixelInsets {
	int left;
	int top;
	int right;
	int bottom;
};

struct PeonPadViewportGeometry {
	int x;
	int y;
	int width;
	int height;
	int logicalWidth;
	int logicalHeight;
	float scale;
};

struct PeonPadViewportPoint {
	float x;
	float y;
};

struct PeonPadPointRect {
	int x;
	int y;
	int width;
	int height;
};

struct PeonPadViewportState {
	PeonPadViewportGeometry viewport{};
	bool geometryDirty = true;
	bool renderDirty = true;
	bool valid = false;
};

// Converts a safe client rectangle from SDL window coordinates (points) into
// drawable-pixel insets. Every edge rounds inward so the result cannot place
// interactive content outside the safe rectangle at fractional display scales.
bool PeonPadCalculatePixelInsets(int pointWidth,
                                int pointHeight,
                                int pixelWidth,
                                int pixelHeight,
                                PeonPadPointRect safeArea,
                                PeonPadPixelInsets &pixelInsets);

// Invalidates both rendering and inverse input. A dirty state is never allowed
// to map through the previously calculated viewport.
void PeonPadInvalidateViewport(PeonPadViewportState &state);

// Rebuilds the authoritative viewport from current point/pixel geometry and
// safe bounds. Failed refreshes invalidate input instead of retaining stale
// success-shaped state.
bool PeonPadRefreshViewportState(int pointWidth,
                                int pointHeight,
                                int pixelWidth,
                                int pixelHeight,
                                PeonPadPointRect safeArea,
                                int logicalWidth,
                                int logicalHeight,
                                PeonPadViewportState &state);

void PeonPadMarkViewportRendered(PeonPadViewportState &state);

// Fits a logical surface inside a pixel-safe rectangle. The output dimensions
// retain the logical aspect ratio exactly, so no resize can stretch the image.
// Returns false for unusable dimensions or insets.
bool PeonPadCalculateViewport(int outputWidth,
                             int outputHeight,
                             int logicalWidth,
                             int logicalHeight,
                             PeonPadPixelInsets insets,
                             PeonPadViewportGeometry &viewport);

// Applies the inverse of PeonPadCalculateViewport. Points in letterbox or
// pillarbox bars return false instead of leaking out-of-range logical input.
bool PeonPadMapViewportPoint(const PeonPadViewportGeometry &viewport,
                            float outputX,
                            float outputY,
                            PeonPadViewportPoint &logicalPoint);

// Maps only through current, valid state. Dirty or failed state rejects input.
bool PeonPadMapViewportStatePoint(const PeonPadViewportState &state,
                                 float outputX,
                                 float outputY,
                                 PeonPadViewportPoint &logicalPoint);
