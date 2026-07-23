// TabletopTilesetPath.cpp
//
// See TabletopTilesetPath.h.
#include "TabletopTilesetPath.h"

#include <cctype>
#include <cstdint>
#include <cstdio>

namespace {

// FNV-1a 64-bit — a small, deterministic, dependency-free hash. Not
// cryptographic; only used to keep unrelated tileset identities from
// colliding on the same generated cache filename, not for security.
std::uint64_t Fnv1aHash64(const std::string &s) noexcept
{
    std::uint64_t h = 1469598103934665603ULL; // offset basis
    for (unsigned char c : s) {
        h ^= static_cast<std::uint64_t>(c);
        h *= 1099511628211ULL; // FNV prime
    }
    return h;
}

} // namespace

std::string TabletopSanitizeTilesetCacheName(const std::string &tilesetName) noexcept
{
    std::string safe;
    safe.reserve(tilesetName.size());
    for (unsigned char c : tilesetName) {
        if (std::isalnum(c)) {
            safe += static_cast<char>(std::tolower(c));
        } else if (c == '-' || c == '_') {
            safe += static_cast<char>(c);
        }
    }
    if (safe.empty()) safe = "tileset";
    return safe;
}

std::string TabletopTilesetExportRelativePath(
    const std::string &tilesetName,
    const std::string &tilesetSourcePath,
    unsigned long version) noexcept
{
    // Bounded, sanitized *display* prefix (readability/debuggability only).
    std::string shortName = TabletopSanitizeTilesetCacheName(tilesetName);
    if (shortName.size() > 20) {
        shortName.resize(20);
    }

    // Hash over the full, unsanitized identity (name + source path +
    // version) so distinct tilesets/generations never collide even when
    // their sanitized display prefixes coincide.
    const std::string identity =
        tilesetName + '\x1f' + tilesetSourcePath + '\x1f' + std::to_string(version);
    const std::uint64_t hash = Fnv1aHash64(identity);

    char hex[17];
    std::snprintf(hex, sizeof(hex), "%016llx", static_cast<unsigned long long>(hash));

    std::string path = "tabletop-generated/" + shortName + "-v" + std::to_string(version)
        + "-" + hex + ".png";

    // Defensive hard cap, well under PEONPAD_TABLETOP_MAX_PATH (128 bytes
    // including the NUL). The construction above is already far below this,
    // but if `version` (an unsigned long, caller-controlled) ever grows
    // enormous, drop the display prefix rather than risk truncation of the
    // fixed-size ABI descriptor field.
    constexpr std::size_t kMaxPathBudget = 100;
    if (path.size() > kMaxPathBudget) {
        path = "tabletop-generated/t-v" + std::to_string(version) + "-" + hex + ".png";
    }
    return path;
}
