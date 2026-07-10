#include <cstdint>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#else
#error "PeonPad currently supports Apple toolchains only"
#endif

#if defined(PEONPAD_EXPECT_IOS) && !TARGET_OS_IOS
#error "The iOS preflight probe is not using an iOS target"
#endif

#if defined(PEONPAD_EXPECT_MACOS) && !TARGET_OS_OSX
#error "The native preflight probe is not using a macOS target"
#endif

extern "C" std::uint32_t peonpad_toolchain_probe()
{
    return 0x50454f4eU;
}

