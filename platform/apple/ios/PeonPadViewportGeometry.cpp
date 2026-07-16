#include "PeonPadViewportGeometry.h"

#include <algorithm>
#include <numeric>

bool PeonPadCalculateViewport(const int outputWidth,
                             const int outputHeight,
                             const int logicalWidth,
                             const int logicalHeight,
                             PeonPadPixelInsets insets,
                             PeonPadViewportGeometry &viewport)
{
	viewport = {};
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

	const int divisor = std::gcd(logicalWidth, logicalHeight);
	const int aspectWidth = logicalWidth / divisor;
	const int aspectHeight = logicalHeight / divisor;
	const int aspectScale = std::min(safeWidth / aspectWidth,
	                                 safeHeight / aspectHeight);
	if (aspectScale <= 0) {
		return false;
	}

	const int width = aspectWidth * aspectScale;
	const int height = aspectHeight * aspectScale;

	viewport.x = insets.left + (safeWidth - width) / 2;
	viewport.y = insets.top + (safeHeight - height) / 2;
	viewport.width = width;
	viewport.height = height;
	viewport.logicalWidth = logicalWidth;
	viewport.logicalHeight = logicalHeight;
	viewport.scale = static_cast<float>(width) / logicalWidth;
	return true;
}

bool PeonPadMapViewportPoint(const PeonPadViewportGeometry &viewport,
                            const float outputX,
                            const float outputY,
                            PeonPadViewportPoint &logicalPoint)
{
	logicalPoint = {};
	if (viewport.width <= 0 || viewport.height <= 0
	    || viewport.logicalWidth <= 0 || viewport.logicalHeight <= 0
	    || viewport.scale <= 0.0f
	    || outputX < viewport.x || outputY < viewport.y
	    || outputX >= viewport.x + viewport.width
	    || outputY >= viewport.y + viewport.height) {
		return false;
	}

	logicalPoint.x = (outputX - viewport.x) / viewport.scale;
	logicalPoint.y = (outputY - viewport.y) / viewport.scale;
	return logicalPoint.x >= 0.0f && logicalPoint.y >= 0.0f
	    && logicalPoint.x < viewport.logicalWidth
	    && logicalPoint.y < viewport.logicalHeight;
}
