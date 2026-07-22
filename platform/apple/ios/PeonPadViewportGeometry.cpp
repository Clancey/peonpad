#include "PeonPadViewportGeometry.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
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

bool PeonPadCalculateRendererTransform(
	const PeonPadViewportGeometry &viewport,
	PeonPadRendererTransform &transform)
{
	transform = {};
	if (viewport.x < 0 || viewport.y < 0
	    || viewport.width <= 0 || viewport.height <= 0
	    || viewport.logicalWidth <= 0 || viewport.logicalHeight <= 0
	    || viewport.scale <= 0.0f) {
		return false;
	}

	float scale = viewport.scale;
	for (int iteration = 0; iteration < 32; ++iteration) {
		const double unscaledX =
			std::ceil(static_cast<double>(viewport.x) / scale);
		const double unscaledY =
			std::ceil(static_cast<double>(viewport.y) / scale);
		if (unscaledX > std::numeric_limits<int>::max()
		    || unscaledY > std::numeric_limits<int>::max()) {
			return false;
		}
		int viewportX = static_cast<int>(unscaledX);
		int viewportY = static_cast<int>(unscaledY);
		while (std::floor(viewportX * static_cast<double>(scale))
		       < viewport.x) {
			if (viewportX == std::numeric_limits<int>::max()) {
				return false;
			}
			++viewportX;
		}
		while (std::floor(viewportY * static_cast<double>(scale))
		       < viewport.y) {
			if (viewportY == std::numeric_limits<int>::max()) {
				return false;
			}
			++viewportY;
		}

		const int pixelX = static_cast<int>(
			std::floor(viewportX * static_cast<double>(scale)));
		const int pixelY = static_cast<int>(
			std::floor(viewportY * static_cast<double>(scale)));
		const int availableWidth =
			viewport.x + viewport.width - pixelX;
		const int availableHeight =
			viewport.y + viewport.height - pixelY;
		if (availableWidth <= 0 || availableHeight <= 0) {
			return false;
		}

		const double maximumScale = std::min({
			static_cast<double>(scale),
			static_cast<double>(availableWidth) / viewport.logicalWidth,
			static_cast<double>(availableHeight) / viewport.logicalHeight,
		});
		float fittedScale = static_cast<float>(maximumScale);
		while (fittedScale > maximumScale) {
			fittedScale = std::nextafter(fittedScale, 0.0f);
		}
		if (fittedScale <= 0.0f) {
			return false;
		}

		const double fittedX = std::ceil(
			static_cast<double>(viewport.x) / fittedScale);
		const double fittedY = std::ceil(
			static_cast<double>(viewport.y) / fittedScale);
		if (fittedX > std::numeric_limits<int>::max()
		    || fittedY > std::numeric_limits<int>::max()) {
			return false;
		}
		viewportX = static_cast<int>(fittedX);
		viewportY = static_cast<int>(fittedY);
		while (std::floor(viewportX * static_cast<double>(fittedScale))
		       < viewport.x) {
			if (viewportX == std::numeric_limits<int>::max()) {
				return false;
			}
			++viewportX;
		}
		while (std::floor(viewportY * static_cast<double>(fittedScale))
		       < viewport.y) {
			if (viewportY == std::numeric_limits<int>::max()) {
				return false;
			}
			++viewportY;
		}
		transform = {
			viewportX,
			viewportY,
			viewport.logicalWidth,
			viewport.logicalHeight,
			fittedScale,
		};

		const int transformedX = static_cast<int>(
			std::floor(viewportX * static_cast<double>(fittedScale)));
		const int transformedY = static_cast<int>(
			std::floor(viewportY * static_cast<double>(fittedScale)));
		const int transformedWidth = static_cast<int>(
			std::ceil(viewport.logicalWidth
			          * static_cast<double>(fittedScale)));
		const int transformedHeight = static_cast<int>(
			std::ceil(viewport.logicalHeight
			          * static_cast<double>(fittedScale)));
		if (transformedX >= viewport.x && transformedY >= viewport.y
		    && transformedX + transformedWidth
		           <= viewport.x + viewport.width
		    && transformedY + transformedHeight
		           <= viewport.y + viewport.height) {
			return true;
		}
		scale = std::nextafter(fittedScale, 0.0f);
		if (scale <= 0.0f) {
			return false;
		}
	}
	transform = {};
	return false;
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
