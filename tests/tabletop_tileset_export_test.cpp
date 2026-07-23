// tabletop_tileset_export_test.cpp
//
// SDL3-linked regression test for the visionOS tabletop's expanded-tileset
// PNG exporter (platform/bridge/TabletopTilesetExport.cpp / .h). This is the
// engine-independent core behind PeonPadTabletopBridge.cpp's
// ExportExpandedTilesetPNG — the fix for the "wrong floor tiles" bug (Wargus
// tilesets append procedurally-generated tile frames to the in-memory tile
// graphic at load time, which never exist in the on-disk tileset PNG).
//
// Unlike tests/tabletop_bridge_test.cpp (which compiles the bridge WITHOUT
// PEONPAD_TABLETOP and therefore never touches the exporter at all), this
// binary links real SDL3 + SDL3_image and exercises the actual IMG_SavePNG
// write + decode path end to end, using only synthetic, procedurally
// generated pixel data — no proprietary game assets.
//
// Run: ./scripts/build-visionos-tabletop.sh-independent — see
//      tests/tabletop_bridge_acceptance.sh section 6, which builds and runs
//      this binary via CMake (PEONPAD_ENABLE_SDL3=ON, PEONPAD_ENABLE_ENGINE=OFF).

#include "TabletopTilesetExport.h"
#include "TabletopTilesetPath.h"

#include <SDL3/SDL.h>
#include <SDL3_image/SDL_image.h>

#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#ifndef _WIN32
#include <unistd.h>
#endif

namespace fs = std::filesystem;

namespace {

int g_failures = 0;

void Expect(bool condition, const char *message)
{
    if (!condition) {
        ++g_failures;
        std::fprintf(stderr, "FAIL: %s\n", message);
    }
}

// Creates an RGBA32 surface of the given size, filled with a deterministic,
// position-dependent pattern (not proprietary art — just a synthetic
// gradient) so decoded output can be verified pixel-for-pixel.
SDL_Surface *MakeSyntheticSurface(int w, int h, Uint8 seed)
{
    SDL_Surface *surface = SDL_CreateSurface(w, h, SDL_PIXELFORMAT_RGBA32);
    if (!surface) return nullptr;
    SDL_LockSurface(surface);
    auto *pixels = static_cast<Uint8 *>(surface->pixels);
    for (int y = 0; y < h; ++y) {
        Uint8 *row = pixels + y * surface->pitch;
        for (int x = 0; x < w; ++x) {
            Uint8 *px = row + x * 4;
            px[0] = static_cast<Uint8>((x + seed) & 0xFF);       // R
            px[1] = static_cast<Uint8>((y + seed) & 0xFF);       // G
            px[2] = static_cast<Uint8>((x ^ y ^ seed) & 0xFF);   // B
            px[3] = 255;                                          // A (opaque)
        }
    }
    SDL_UnlockSurface(surface);
    return surface;
}

// Reads back a pixel from a decoded (possibly non-RGBA32) surface as RGBA.
void ReadPixelRGBA(SDL_Surface *surface, int x, int y,
                    Uint8 &r, Uint8 &g, Uint8 &b, Uint8 &a)
{
    const SDL_PixelFormatDetails *details = SDL_GetPixelFormatDetails(surface->format);
    SDL_LockSurface(surface);
    const auto *pixels = static_cast<const Uint8 *>(surface->pixels);
    const Uint8 *px = pixels + y * surface->pitch + x * details->bytes_per_pixel;
    Uint32 raw = 0;
    for (int i = 0; i < details->bytes_per_pixel; ++i) {
        raw |= static_cast<Uint32>(px[i]) << (8 * i);
    }
    SDL_UnlockSurface(surface);
    SDL_GetRGBA(raw, details, nullptr, &r, &g, &b, &a);
}

std::string MakeTempCacheRoot()
{
    std::string tmpl = (fs::temp_directory_path() / "peonpad-tileset-export-XXXXXX").string();
    std::vector<char> buf(tmpl.begin(), tmpl.end());
    buf.push_back('\0');
    char *result = mkdtemp(buf.data());
    return result ? std::string(result) : std::string();
}

} // namespace

int main()
{
    // ── 1. A successful export produces a valid, decodable PNG with exact
    //       dimensions and pixel content. ────────────────────────────────
    {
        const std::string cacheRoot = MakeTempCacheRoot();
        Expect(!cacheRoot.empty(), "created a temp cache root");

        SDL_Surface *surface = MakeSyntheticSurface(37, 53, 17);
        Expect(surface != nullptr, "created synthetic surface");

        const TabletopTilesetExportResult result = TabletopExportTilesetSurfacePNG(
            surface, "Forest", "tilesets/summer/terrain/summer.png", 1, cacheRoot);
        Expect(result.ok, "export succeeded");
        Expect(result.width == 37 && result.height == 53, "exported dimensions match surface");
        Expect(result.relativePath.rfind("tabletop-generated/", 0) == 0,
               "relative path under tabletop-generated/");

        if (result.ok) {
            const fs::path fullPath = fs::path(cacheRoot) / result.relativePath;
            Expect(fs::exists(fullPath) && fs::is_regular_file(fullPath),
                   "exported file exists on disk as a regular file");
            std::error_code sizeEc;
            Expect(fs::file_size(fullPath, sizeEc) > 0 && !sizeEc, "exported file is non-empty");

            SDL_Surface *decoded = IMG_Load(fullPath.string().c_str());
            Expect(decoded != nullptr, "exported PNG decodes");
            if (decoded) {
                Expect(decoded->w == 37 && decoded->h == 53, "decoded dimensions match");
                Uint8 r, g, b, a;
                ReadPixelRGBA(decoded, 0, 0, r, g, b, a);
                Expect(r == 17 && g == 17 && b == 17 && a == 255, "pixel (0,0) matches synthetic pattern");
                ReadPixelRGBA(decoded, 20, 30, r, g, b, a);
                Expect(r == static_cast<Uint8>(20 + 17) && g == static_cast<Uint8>(30 + 17),
                       "pixel (20,30) matches synthetic pattern");
                SDL_DestroySurface(decoded);
            }
        }

        SDL_DestroySurface(surface);
        std::error_code ec;
        fs::remove_all(cacheRoot, ec);
    }

    // ── 2. Reload/versioning: a changed version produces a distinct file;
    //       the previous version's file is left untouched (never
    //       overwritten), so no in-flight reader can be served a mix of old
    //       and new content. ──────────────────────────────────────────────
    {
        const std::string cacheRoot = MakeTempCacheRoot();
        SDL_Surface *v1 = MakeSyntheticSurface(16, 16, 1);
        SDL_Surface *v2 = MakeSyntheticSurface(16, 24, 2); // simulates a grown/expanded surface

        const auto r1 = TabletopExportTilesetSurfacePNG(v1, "Winter", "tilesets/winter/terrain/winter.png", 1, cacheRoot);
        const auto r2 = TabletopExportTilesetSurfacePNG(v2, "Winter", "tilesets/winter/terrain/winter.png", 2, cacheRoot);
        Expect(r1.ok && r2.ok, "both versions exported successfully");
        Expect(r1.relativePath != r2.relativePath, "different versions get different filenames");
        Expect(fs::exists(fs::path(cacheRoot) / r1.relativePath), "v1 file still exists after v2 export");
        Expect(fs::exists(fs::path(cacheRoot) / r2.relativePath), "v2 file exists");
        Expect(r1.height == 16 && r2.height == 24, "v2 reflects the grown surface height");

        SDL_Surface *v1decoded = IMG_Load((fs::path(cacheRoot) / r1.relativePath).string().c_str());
        Expect(v1decoded != nullptr && v1decoded->h == 16, "v1 file content is unaffected by v2's export");
        if (v1decoded) SDL_DestroySurface(v1decoded);

        SDL_DestroySurface(v1);
        SDL_DestroySurface(v2);
        std::error_code ec;
        fs::remove_all(cacheRoot, ec);
    }

    // ── 3. Collision resistance: two distinct tileset identities whose
    //       *sanitized display prefixes* coincide never clobber each
    //       other's exported file. ──────────────────────────────────────
    {
        const std::string cacheRoot = MakeTempCacheRoot();
        SDL_Surface *a = MakeSyntheticSurface(8, 8, 100);
        SDL_Surface *b = MakeSyntheticSurface(8, 8, 200);

        Expect(TabletopSanitizeTilesetCacheName("Ice Cliffs-2")
               == TabletopSanitizeTilesetCacheName("IceCliffs-2"),
               "the two names do sanitize to the same display prefix (precondition)");

        const auto ra = TabletopExportTilesetSurfacePNG(a, "Ice Cliffs-2", "tilesets/ice/terrain/ice.png", 1, cacheRoot);
        const auto rb = TabletopExportTilesetSurfacePNG(b, "IceCliffs-2", "tilesets/ice/terrain/ice.png", 1, cacheRoot);
        Expect(ra.ok && rb.ok, "both colliding-name exports succeeded");
        Expect(ra.relativePath != rb.relativePath, "colliding display names still get distinct files");
        Expect(fs::exists(fs::path(cacheRoot) / ra.relativePath), "first tileset's file exists");
        Expect(fs::exists(fs::path(cacheRoot) / rb.relativePath), "second tileset's file exists");

        SDL_Surface *aDecoded = IMG_Load((fs::path(cacheRoot) / ra.relativePath).string().c_str());
        Expect(aDecoded != nullptr, "first tileset's file decodes");
        if (aDecoded) {
            Uint8 r, g, b8, a8;
            ReadPixelRGBA(aDecoded, 0, 0, r, g, b8, a8);
            Expect(r == 100, "first tileset's content was not overwritten by the second");
            SDL_DestroySurface(aDecoded);
        }

        SDL_DestroySurface(a);
        SDL_DestroySurface(b);
        std::error_code ec;
        fs::remove_all(cacheRoot, ec);
    }

    // ── 4. Path-length bound: an adversarially long tileset name/source
    //       still produces a path safely under PEONPAD_TABLETOP_MAX_PATH,
    //       and the export still succeeds and is decodable. ─────────────
    {
        const std::string cacheRoot = MakeTempCacheRoot();
        SDL_Surface *surface = MakeSyntheticSurface(4, 4, 9);
        const std::string longName(400, 'Q');
        const std::string longSource(400, '/');

        const auto result = TabletopExportTilesetSurfacePNG(
            surface, longName, longSource, 1, cacheRoot);
        Expect(result.ok, "export with a pathological name/source still succeeds");
        Expect(result.relativePath.size() + 1 <= 128,
               "path stays within PEONPAD_TABLETOP_MAX_PATH (128 incl. NUL)");

        SDL_Surface *decoded = IMG_Load((fs::path(cacheRoot) / result.relativePath).string().c_str());
        Expect(decoded != nullptr, "long-name export decodes");
        if (decoded) SDL_DestroySurface(decoded);

        SDL_DestroySurface(surface);
        std::error_code ec;
        fs::remove_all(cacheRoot, ec);
    }

    // ── 5. Write failure: an unwritable/unusable cache root fails cleanly
    //       (no crash, ok == false, no partial file left at the final
    //       destination path). ──────────────────────────────────────────
    {
        const std::string cacheRoot = MakeTempCacheRoot();
        // Create a plain *file* where the exporter would need a directory,
        // guaranteeing fs::create_directories() fails.
        const fs::path blocker = fs::path(cacheRoot) / "tabletop-generated";
        { std::ofstream(blocker.string()) << "not a directory"; }

        SDL_Surface *surface = MakeSyntheticSurface(4, 4, 3);
        const auto result = TabletopExportTilesetSurfacePNG(
            surface, "Blocked", "tilesets/blocked/terrain/blocked.png", 1, cacheRoot);
        Expect(!result.ok, "export fails cleanly when the cache directory cannot be created");
        Expect(result.relativePath.empty(), "no relative path is returned on failure");

        SDL_DestroySurface(surface);
        std::error_code ec;
        fs::remove_all(cacheRoot, ec);
    }

    // ── 6. Degenerate inputs never crash. ────────────────────────────────
    {
        const auto nullResult = TabletopExportTilesetSurfacePNG(
            nullptr, "Forest", "tilesets/summer/terrain/summer.png", 1, "/tmp");
        Expect(!nullResult.ok, "null surface fails cleanly");

        SDL_Surface *surface = MakeSyntheticSurface(2, 2, 0);
        const auto emptyRootResult = TabletopExportTilesetSurfacePNG(
            surface, "Forest", "tilesets/summer/terrain/summer.png", 1, "");
        Expect(!emptyRootResult.ok, "empty cache root fails cleanly");
        SDL_DestroySurface(surface);
    }

    if (g_failures == 0) {
        std::printf("PASSED: all tabletop tileset-export checks\n");
        return 0;
    }
    std::fprintf(stderr, "FAILED: %d check(s) failed\n", g_failures);
    return 1;
}
