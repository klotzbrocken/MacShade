// Frame rate limiter (MACSHADE_FPS_LIMIT=<fps>, 0/unset = off). Called once per presented frame by the OpenGL, Metal and Vulkan paths; sleeps until the
// frame is at least 1/limit seconds after the previous one. Games on macOS often have no limiter of their own, and an uncapped game next to ReShade only
// heats the machine and makes frame times uneven.
#include <mach/mach_time.h>
#include <cstdlib>
#include <algorithm>

void macshade_frame_limit()
{
	static const double fps = [] { const char *v = std::getenv("MACSHADE_FPS_LIMIT"); return v ? std::atof(v) : 0.0; }();
	if (fps < 1.0) return;
	static mach_timebase_info_data_t tb = [] { mach_timebase_info_data_t t; mach_timebase_info(&t); return t; }();
	static const uint64_t interval = static_cast<uint64_t>(1e9 / fps * tb.denom / tb.numer);
	static uint64_t last = 0;
	const uint64_t now = mach_absolute_time();
	uint64_t target = last + interval;
	if (last != 0 && now < target)
	{
		const uint64_t spin = static_cast<uint64_t>(300e3 * tb.denom / tb.numer);   // sleep until 0.3 ms before the target, spin for the rest (the OS timer is not that exact)
		if (target - now > spin) mach_wait_until(target - spin);
		while (mach_absolute_time() < target) {}
		last = target;
	}
	else
		last = now;   // late (or first frame): no catching up with a burst of frames
}
