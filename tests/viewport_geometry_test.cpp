#include "PeonPadViewportGeometry.h"

#include <cassert>
#include <cmath>

namespace {

bool NearlyEqual(const float lhs, const float rhs)
{
	return std::fabs(lhs - rhs) < 0.0001f;
}

} // namespace

int main()
{
	PeonPadViewportGeometry viewport;

	assert(PeonPadCalculateViewport(2048, 1536, 640, 480,
	                                {0, 0, 0, 0}, viewport));
	assert(viewport.x == 0);
	assert(viewport.y == 0);
	assert(viewport.width == 2048);
	assert(viewport.height == 1536);
	assert(NearlyEqual(viewport.scale, 3.2f));

	assert(PeonPadCalculateViewport(2732, 2048, 640, 480,
	                                {24, 0, 24, 42}, viewport));
	assert(viewport.x >= 24);
	assert(viewport.y >= 0);
	assert(viewport.x + viewport.width <= 2732 - 24);
	assert(viewport.y + viewport.height <= 2048 - 42);
	assert(viewport.width == static_cast<int>(std::floor(640 * viewport.scale)));
	assert(viewport.height == static_cast<int>(std::floor(480 * viewport.scale)));

	assert(PeonPadCalculateViewport(1200, 900, 640, 480,
	                                {100, 20, 0, 40}, viewport));
	assert(viewport.x >= 100);
	assert(viewport.y >= 20);
	assert(viewport.x + viewport.width <= 1200);
	assert(viewport.y + viewport.height <= 860);

	assert(!PeonPadCalculateViewport(0, 900, 640, 480,
	                                 {0, 0, 0, 0}, viewport));
	assert(!PeonPadCalculateViewport(1200, 900, 640, 480,
	                                 {600, 0, 600, 0}, viewport));

	return 0;
}
