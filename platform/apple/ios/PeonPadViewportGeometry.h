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
