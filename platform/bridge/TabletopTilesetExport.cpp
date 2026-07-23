// TabletopTilesetExport.cpp
//
// See TabletopTilesetExport.h.
#include "TabletopTilesetExport.h"
#include "TabletopTilesetPath.h"

#include <SDL3_image/SDL_image.h>

#include <cstdint>
#include <filesystem>
#include <system_error>

namespace {
namespace fs = std::filesystem;
} // namespace

TabletopTilesetExportResult TabletopExportTilesetSurfacePNG(
    SDL_Surface *surface,
    const std::string &tilesetName,
    const std::string &tilesetSourcePath,
    unsigned long version,
    const std::string &cacheRootDir) noexcept
{
    TabletopTilesetExportResult result;

    if (!surface || surface->w <= 0 || surface->h <= 0) return result;
    if (surface->w > UINT16_MAX || surface->h > UINT16_MAX) return result;
    if (cacheRootDir.empty()) return result;

    try {
        const std::string relativePath =
            TabletopTilesetExportRelativePath(tilesetName, tilesetSourcePath, version);
        const fs::path fullPath   = fs::path(cacheRootDir) / relativePath;
        const fs::path parentDir  = fullPath.parent_path();

        std::error_code ec;
        fs::create_directories(parentDir, ec);
        if (ec) return result;

        // Atomic write: encode to a temp file unique to this attempt (the
        // surface pointer + version make collisions between concurrent
        // exports of *different* tilesets vanishingly unlikely, and this
        // engine only ever exports from a single simulation thread anyway),
        // then rename it over the destination. A reader opening
        // `fullPath` at any point either sees the previous complete file (if
        // one already existed under a different version's name — it isn't
        // touched) or this new complete file; never a partial write.
        const fs::path tempPath = parentDir / (fullPath.filename().string()
            + ".tmp" + std::to_string(reinterpret_cast<std::uintptr_t>(surface))
            + "-" + std::to_string(version));

        if (!IMG_SavePNG(surface, tempPath.string().c_str())) {
            std::error_code cleanupEc;
            fs::remove(tempPath, cleanupEc);
            return result;
        }

        fs::rename(tempPath, fullPath, ec);
        if (ec) {
            std::error_code cleanupEc;
            fs::remove(tempPath, cleanupEc);
            return result;
        }

        result.ok           = true;
        result.relativePath = relativePath;
        result.width        = static_cast<std::uint16_t>(surface->w);
        result.height       = static_cast<std::uint16_t>(surface->h);
        return result;
    } catch (...) {
        return result;
    }
}
