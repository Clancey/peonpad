#include "PeonPadViewportGeometry.h"

#include <cmath>
#include <cstdio>

namespace {

int Failures = 0;

void Check(const bool condition, const char *description)
{
	if (!condition) {
		std::fprintf(stderr, "FAIL: %s\n", description);
		++Failures;
	}
}

bool NearlyEqual(const float lhs, const float rhs)
{
	return std::fabs(lhs - rhs) < 0.0001f;
}

void CheckPoint(const PeonPadViewportGeometry &viewport,
                const float outputX,
                const float outputY,
                const bool expectedInside,
                const float expectedX,
                const float expectedY,
                const char *description)
{
	PeonPadViewportPoint point{};
	const bool inside =
		PeonPadMapViewportPoint(viewport, outputX, outputY, point);
	Check(inside == expectedInside, description);
	if (inside && expectedInside) {
		Check(NearlyEqual(point.x, expectedX), "inverse logical x");
		Check(NearlyEqual(point.y, expectedY), "inverse logical y");
	}
}

} // namespace

int main()
{
#if !defined(NDEBUG)
	Check(false, "geometry test must execute with -DNDEBUG");
#endif

	PeonPadViewportGeometry viewport{};

	Check(PeonPadCalculateViewport(2048, 1536, 640, 480,
	                               {0, 0, 0, 0}, viewport),
	      "default 4:3 viewport");
	Check(viewport.x == 0 && viewport.y == 0,
	      "default viewport origin");
	Check(viewport.width == 2048 && viewport.height == 1536,
	      "default viewport size");
	Check(viewport.logicalWidth == 640 && viewport.logicalHeight == 480,
	      "logical dimensions retained");
	Check(NearlyEqual(viewport.scale, 3.2f), "default scale");
	CheckPoint(viewport, 1024.0f, 768.0f, true, 320.0f, 240.0f,
	           "default center inverse");

	// Wide output must pillarbox without changing the 4:3 content ratio.
	Check(PeonPadCalculateViewport(1600, 900, 640, 480,
	                               {0, 0, 0, 0}, viewport),
	      "wide viewport");
	Check(viewport.x == 200 && viewport.y == 0,
	      "wide pillarbox origin");
	Check(viewport.width == 1200 && viewport.height == 900,
	      "wide exact 4:3 dimensions");
	CheckPoint(viewport, 199.0f, 450.0f, false, 0.0f, 0.0f,
	           "left pillarbox rejected");
	CheckPoint(viewport, 1400.0f, 450.0f, false, 0.0f, 0.0f,
	           "right pillarbox rejected");
	CheckPoint(viewport, 800.0f, 450.0f, true, 320.0f, 240.0f,
	           "wide center inverse");

	// Tall output must letterbox.
	Check(PeonPadCalculateViewport(900, 1600, 640, 480,
	                               {0, 0, 0, 0}, viewport),
	      "tall viewport");
	Check(viewport.x == 0 && viewport.y == 462,
	      "tall letterbox origin");
	Check(viewport.width == 900 && viewport.height == 675,
	      "tall exact 4:3 dimensions");
	CheckPoint(viewport, 450.0f, 461.0f, false, 0.0f, 0.0f,
	           "top letterbox rejected");
	CheckPoint(viewport, 450.0f, 1137.0f, false, 0.0f, 0.0f,
	           "bottom letterbox rejected");

	// Retina drawable pixels use the same inverse transform. An 800x600-point
	// window at 2x has a 1600x1200 drawable and maps its pixel center exactly.
	Check(PeonPadCalculateViewport(1600, 1200, 640, 480,
	                               {0, 0, 0, 0}, viewport),
	      "Retina viewport");
	Check(NearlyEqual(viewport.scale, 2.5f), "Retina scale");
	CheckPoint(viewport, 800.0f, 600.0f, true, 320.0f, 240.0f,
	           "Retina center inverse");

	// Repeated resizes overwrite all prior transform state.
	Check(PeonPadCalculateViewport(1200, 900, 640, 480,
	                               {100, 20, 0, 40}, viewport),
	      "inset resize");
	Check(viewport.x >= 100 && viewport.y >= 20,
	      "inset resize origin");
	Check(viewport.x + viewport.width <= 1200,
	      "inset resize horizontal bound");
	Check(viewport.y + viewport.height <= 860,
	      "inset resize vertical bound");
	Check(PeonPadCalculateViewport(640, 480, 640, 480,
	                               {0, 0, 0, 0}, viewport),
	      "repeated default resize");
	Check(viewport.x == 0 && viewport.y == 0
	      && viewport.width == 640 && viewport.height == 480
	      && NearlyEqual(viewport.scale, 1.0f),
	      "repeated resize has no stale state");

	Check(!PeonPadCalculateViewport(0, 900, 640, 480,
	                                {0, 0, 0, 0}, viewport),
	      "zero output rejected");
	Check(viewport.width == 0 && viewport.height == 0,
	      "failed resize clears transform");
	Check(!PeonPadCalculateViewport(1200, 900, 640, 480,
	                                {600, 0, 600, 0}, viewport),
	      "exhausted insets rejected");

	if (Failures != 0) {
		std::fprintf(stderr, "%d viewport check(s) failed\n", Failures);
		return 1;
	}
	std::puts("viewport geometry and inverse input checks passed under NDEBUG");
	return 0;
}
