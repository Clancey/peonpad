#include "PeonPadViewportGeometry.h"

#include <algorithm>
#include <cstdint>
#include <numeric>

namespace {

int ClampCoordinate(const std::int64_t value, const int extent)
{
	return static_cast<int>(
		std::max<std::int64_t>(0, std::min<std::int64_t>(value, extent)));
}

int ScaleInsetInward(const int inset,
                     const int pointExtent,
                     const int pixelExtent)
{
	const std::int64_t product =
		static_cast<std::int64_t>(inset) * pixelExtent;
	return static_cast<int>((product + pointExtent - 1) / pointExtent);
}

} // namespace

bool PeonPadCalculatePixelInsets(const int pointWidth,
                                const int pointHeight,
                                const int pixelWidth,
                                const int pixelHeight,
                                const PeonPadPointRect safeArea,
                                PeonPadPixelInsets &pixelInsets)
{
	pixelInsets = {};
	if (pointWidth <= 0 || pointHeight <= 0
	    || pixelWidth <= 0 || pixelHeight <= 0
	    || safeArea.width <= 0 || safeArea.height <= 0) {
		return false;
	}

	const int safeLeft = ClampCoordinate(safeArea.x, pointWidth);
	const int safeTop = ClampCoordinate(safeArea.y, pointHeight);
	const int safeRight = ClampCoordinate(
		static_cast<std::int64_t>(safeArea.x) + safeArea.width, pointWidth);
	const int safeBottom = ClampCoordinate(
		static_cast<std::int64_t>(safeArea.y) + safeArea.height, pointHeight);
	if (safeRight <= safeLeft || safeBottom <= safeTop) {
		return false;
	}

	pixelInsets.left =
		ScaleInsetInward(safeLeft, pointWidth, pixelWidth);
	pixelInsets.top =
		ScaleInsetInward(safeTop, pointHeight, pixelHeight);
	pixelInsets.right = ScaleInsetInward(
		pointWidth - safeRight, pointWidth, pixelWidth);
	pixelInsets.bottom = ScaleInsetInward(
		pointHeight - safeBottom, pointHeight, pixelHeight);
	return pixelInsets.left + pixelInsets.right < pixelWidth
	    && pixelInsets.top + pixelInsets.bottom < pixelHeight;
}

void PeonPadInvalidateViewport(PeonPadViewportState &state)
{
	state.geometryDirty = true;
	state.renderDirty = true;
	state.valid = false;
}

bool PeonPadRefreshViewportState(const int pointWidth,
                                const int pointHeight,
                                const int pixelWidth,
                                const int pixelHeight,
                                const PeonPadPointRect safeArea,
                                const int logicalWidth,
                                const int logicalHeight,
                                PeonPadViewportState &state)
{
	PeonPadPixelInsets pixelInsets{};
	PeonPadViewportGeometry viewport{};
	if (!PeonPadCalculatePixelInsets(
		    pointWidth, pointHeight, pixelWidth, pixelHeight,
		    safeArea, pixelInsets)
	    || !PeonPadCalculateViewport(
		    pixelWidth, pixelHeight, logicalWidth, logicalHeight,
		    pixelInsets, viewport)) {
		PeonPadInvalidateViewport(state);
		return false;
	}

	state.viewport = viewport;
	state.geometryDirty = false;
	state.renderDirty = true;
	state.valid = true;
	return true;
}

void PeonPadMarkViewportRendered(PeonPadViewportState &state)
{
	if (state.valid && !state.geometryDirty) {
		state.renderDirty = false;
	}
}

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

bool PeonPadMapViewportStatePoint(const PeonPadViewportState &state,
                                 const float outputX,
                                 const float outputY,
                                 PeonPadViewportPoint &logicalPoint)
{
	if (!state.valid || state.geometryDirty) {
		logicalPoint = {};
		return false;
	}
	return PeonPadMapViewportPoint(
		state.viewport, outputX, outputY, logicalPoint);
}
