#include "PeonPadViewportGeometry.h"

#include <algorithm>
#include <cmath>

bool PeonPadCalculateViewport(const int outputWidth,
                             const int outputHeight,
                             const int logicalWidth,
                             const int logicalHeight,
                             PeonPadPixelInsets insets,
                             PeonPadViewportGeometry &viewport)
{
	if (outputWidth <= 0 || outputHeight <= 0
	    || logicalWidth <= 0 || logicalHeight <= 0) {
		return false;
	}

	insets.left = std::max(0, insets.left);
	insets.top = std::max(0, insets.top);
	insets.right = std::max(0, insets.right);
	insets.bottom = std::max(0, insets.bottom);

	const int safeWidth = outputWidth - insets.left - insets.right;
	const int safeHeight = outputHeight - insets.top - insets.bottom;
	if (safeWidth <= 0 || safeHeight <= 0) {
		return false;
	}

	const float scale = std::min(static_cast<float>(safeWidth) / logicalWidth,
	                             static_cast<float>(safeHeight) / logicalHeight);
	const int width = std::max(1, static_cast<int>(std::floor(logicalWidth * scale)));
	const int height = std::max(1, static_cast<int>(std::floor(logicalHeight * scale)));

	viewport.x = insets.left + (safeWidth - width) / 2;
	viewport.y = insets.top + (safeHeight - height) / 2;
	viewport.width = width;
	viewport.height = height;
	viewport.scale = scale;
	return true;
}
