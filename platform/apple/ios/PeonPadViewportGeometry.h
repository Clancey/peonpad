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
	float scale;
};

// Fits a logical game surface inside a pixel-safe rectangle while preserving
// aspect ratio. Returns false for unusable dimensions or insets.
bool PeonPadCalculateViewport(int outputWidth,
                             int outputHeight,
                             int logicalWidth,
                             int logicalHeight,
                             PeonPadPixelInsets insets,
                             PeonPadViewportGeometry &viewport);
