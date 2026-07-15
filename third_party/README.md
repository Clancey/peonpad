# Third-party dependencies

This directory will contain revision locks, license records, and reproducible
build recipes. Downloaded sources and build output are not committed unless a
dependency's license and the repository policy explicitly permit vendoring.

`sdl3/sources/` contains the exact, checksum-locked upstream release archives
used by the opt-in direct SDL3 lane. CMake extracts these local archives into
the build tree; normal builds never contact the network or modify the archives.
