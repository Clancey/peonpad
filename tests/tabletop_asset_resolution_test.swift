// tabletop_asset_resolution_test.swift
//
// Host-Mac unit tests for the framework-free asset-resolution layer
// (TabletopAssetResolution.swift): path confinement, atlas source-rectangle
// math, direction/frame selection, team color, the staged-data resolver's
// placement decisions (including missing/corrupt-asset fallback), and the
// bounded LRU cache eviction order. No Simulator, RealityKit, or proprietary
// data required.
//
// Run: ./scripts/test-visionos-tabletop-assets.sh
import Foundation

var totalChecks = 0
var failedChecks = 0

func expect(_ condition: Bool, _ message: String) {
    totalChecks += 1
    if !condition {
        failedChecks += 1
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
    expect(a == b, "\(message) (got \(a), expected \(b))")
}

// MARK: - Path confinement

func testPathConfinement() {
    expectEqual(TabletopAssetPath.confine("human/units/footman.png"),
                "human/units/footman.png", "confine passes a normal relative path")
    expectEqual(TabletopAssetPath.confine("./a/./b.png"), "a/b.png",
                "confine strips single-dot segments")
    expect(TabletopAssetPath.confine("/etc/passwd") == nil, "reject absolute path")
    expect(TabletopAssetPath.confine("../secret.png") == nil, "reject parent traversal")
    expect(TabletopAssetPath.confine("a/../../b.png") == nil, "reject embedded traversal")
    expect(TabletopAssetPath.confine("a\\b.png") == nil, "reject backslash separators")
    expect(TabletopAssetPath.confine("") == nil, "reject empty path")
    expect(TabletopAssetPath.confine("a\0b") == nil, "reject embedded NUL")

    let root = URL(fileURLWithPath: "/tmp/wargus-data", isDirectory: true)
    let ok = TabletopAssetPath.resolvedURL(root: root, relative: "graphics/x.png")
    expect(ok?.path == "/tmp/wargus-data/graphics/x.png", "resolvedURL stays within root")
    expect(TabletopAssetPath.resolvedURL(root: root, relative: "../escape.png") == nil,
           "resolvedURL rejects escape")

    // The engine's expanded-tileset-PNG cache prefix (see
    // PeonPadTabletopBridge.cpp's TabletopTilesetExportRelativePath) is a
    // normal, confinable relative path — confinement rules are identical
    // regardless of which root (data vs. cache) it ultimately resolves
    // against.
    expectEqual(TabletopAssetPath.generatedCachePrefix, "tabletop-generated/",
                "generated-cache prefix matches the engine's convention")
    let generatedPath = TabletopAssetPath.generatedCachePrefix + "forest-v1-abcdef0123456789.png"
    expectEqual(TabletopAssetPath.confine(generatedPath), generatedPath,
                "a generated-cache path confines like any other relative path")
}

// MARK: - Atlas geometry / frame selection

func testAtlasGeometry() {
    // 8-wide sheet of 72x72 frames, image 576x144 => 8 columns, 2 rows.
    let r0 = TabletopAtlasGeometry.sourceRect(
        frame: 0, frameWidth: 72, frameHeight: 72, imageWidth: 576, imageHeight: 144)
    expectEqual(r0, TabletopSourceRect(x: 0, y: 0, width: 72, height: 72), "frame 0 top-left")

    let r9 = TabletopAtlasGeometry.sourceRect(
        frame: 9, frameWidth: 72, frameHeight: 72, imageWidth: 576, imageHeight: 144)
    expectEqual(r9, TabletopSourceRect(x: 72, y: 72, width: 72, height: 72),
                "frame 9 => row 1, col 1")

    // Out-of-bounds frame returns nil (no garbage crop).
    expect(TabletopAtlasGeometry.sourceRect(
        frame: 16, frameWidth: 72, frameHeight: 72, imageWidth: 576, imageHeight: 144) == nil,
        "frame past the last row => nil")

    // Degenerate inputs.
    expect(TabletopAtlasGeometry.sourceRect(
        frame: 0, frameWidth: 0, frameHeight: 72, imageWidth: 576, imageHeight: 144) == nil,
        "zero cell width => nil")
    expect(TabletopAtlasGeometry.sourceRect(
        frame: -1, frameWidth: 72, frameHeight: 72, imageWidth: 576, imageHeight: 144) == nil,
        "negative frame => nil")
    expect(TabletopAtlasGeometry.sourceRect(
        frame: 0, frameWidth: 72, frameHeight: 72, imageWidth: 10, imageHeight: 10) == nil,
        "image smaller than a cell => nil")
    let paddedSheet = TabletopAtlasGeometry.sourceRect(
        frame: 17, frameWidth: 32, frameHeight: 32,
        imageWidth: 514, imageHeight: 770)
    expectEqual(paddedSheet, TabletopSourceRect(
        x: 32, y: 32, width: 32, height: 32),
        "trailing sheet padding preserves canonical floor-division frame addressing")

    // Representative Warcraft II transition and terrain frames use the same
    // canonical left-to-right, top-to-bottom addressing as CGraphic::GenFramesMap.
    let transition = TabletopAtlasGeometry.sourceRect(
        frame: 206, frameWidth: 32, frameHeight: 32,
        imageWidth: 512, imageHeight: 768)
    expectEqual(transition, TabletopSourceRect(
        x: 14 * 32, y: 12 * 32, width: 32, height: 32),
        "transition frame 206 preserves canonical row and column")
    let forest = TabletopAtlasGeometry.sourceRect(
        frame: 125, frameWidth: 32, frameHeight: 32,
        imageWidth: 512, imageHeight: 768)
    expectEqual(forest, TabletopSourceRect(
        x: 13 * 32, y: 7 * 32, width: 32, height: 32),
        "forest frame 125 preserves canonical row and column")
}

// MARK: - Extended (procedurally-generated) tileset frames
//
// Regression coverage for the "wrong floor tiles" bug: Wargus tilesets call
// GenerateExtendedTileset() (game/wargus/scripts/tilesets/wargus/extended.lua)
// at load time, which appends procedurally-generated transition/cliff/coast
// frames to the engine's *in-memory* tile graphic via CGraphic::AppendFrames
// (engine/stratagus/src/video/graphic.cpp) — growing the surface *taller*
// than the authored PNG on disk, using the *same column count* (image width
// unchanged; only new rows are appended below the existing ones — see
// CGraphic::ExpandFor). A `graphic_index` referencing one of these appended
// frames has no matching pixels in the raw on-disk file.
//
// The engine-side fix (PeonPadTabletopBridge.cpp's ExportExpandedTilesetPNG)
// exports the engine's actual fully-expanded surface — base + generated rows
// — to a PNG once per tileset load, so the decoded image height the Swift
// layer sees always covers every frame the engine can produce. This test
// documents that contract on the Swift side: once `imageHeight` reflects the
// true expanded surface, a frame in an appended row resolves correctly
// (whereas it would return nil against the original, truncated file height).
func testExtendedTilesetFrameResolution() {
    // A 4-column, 32×32 base tileset with 2 authored rows (8 base frames,
    // indices 0...7), extended with 3 more generated rows (12 more frames,
    // indices 8...19) appended below — mirroring CGraphic::ExpandFor, which
    // never changes the column count, only the surface height.
    let frameSize = 32
    let columns = 4
    let baseRows = 2
    let extendedRows = 3
    let baseImageHeight = baseRows * frameSize        // 64 — the raw on-disk PNG
    let expandedImageHeight = (baseRows + extendedRows) * frameSize  // 160

    // Frame 11 sits in the 3rd row (row index 2 = the 3rd of 5 rows), i.e. an
    // extended/generated frame, not present in the on-disk tileset PNG.
    let extendedFrame = 11

    // Against the raw on-disk file's height, the extended frame is out of
    // bounds — this is the state *before* the fix (or for a fallback path
    // where the export failed), correctly rejected rather than cropping
    // garbage pixels.
    expect(TabletopAtlasGeometry.sourceRect(
        frame: extendedFrame, frameWidth: frameSize, frameHeight: frameSize,
        imageWidth: columns * frameSize, imageHeight: baseImageHeight) == nil,
        "extended frame is out of bounds against the raw on-disk tileset height")

    // Against the exported, fully-expanded surface height, the same frame
    // resolves to its real rectangle — this is the state after the fix.
    let resolved = TabletopAtlasGeometry.sourceRect(
        frame: extendedFrame, frameWidth: frameSize, frameHeight: frameSize,
        imageWidth: columns * frameSize, imageHeight: expandedImageHeight)
    expect(resolved != nil, "extended frame resolves once imageHeight covers the expanded surface")
    // frame 11 => row 2 (11/4), col 3 (11%4) => x=96, y=64
    expectEqual(resolved, TabletopSourceRect(x: 96, y: 64, width: frameSize, height: frameSize),
                "extended frame lands in its own generated row, not reinterpreted as a base frame")

    // A base-tileset frame (row 0) resolves identically regardless of
    // whether the image is the raw file or the expanded export — the fix
    // must never perturb frames that already existed on disk.
    let baseFrame = 2
    let baseResolved = TabletopAtlasGeometry.sourceRect(
        frame: baseFrame, frameWidth: frameSize, frameHeight: frameSize,
        imageWidth: columns * frameSize, imageHeight: baseImageHeight)
    let baseResolvedExpanded = TabletopAtlasGeometry.sourceRect(
        frame: baseFrame, frameWidth: frameSize, frameHeight: frameSize,
        imageWidth: columns * frameSize, imageHeight: expandedImageHeight)
    expectEqual(baseResolved, baseResolvedExpanded,
                "base (non-extended) frames are unaffected by the expanded surface height")
}

func testTeamPalette() {
    let red = TabletopTeamPalette.tint(owner: 0)
    let blue = TabletopTeamPalette.tint(owner: 1)
    expect(red != blue, "distinct owners get distinct tints")
    expectEqual(TabletopTeamPalette.tint(owner: 8), red, "owner index wraps at 8")
    expectEqual(TabletopTeamPalette.tint(owner: -8), red, "negative owner index wraps")
    expectEqual(TabletopTeamPalette.tint(owner: 3), TabletopTeamPalette.tint(owner: 3),
                "team tint is deterministic")
}

// MARK: - Staged-data resolver placements

func testTerrainPlacement() {
    let resolver = WargusStagedAssetResolver()
    let tileset = TabletopTilesetInfo(
        imagePath: "tilesets/summer/terrain/summer.png",
        pixelTileWidth: 32, pixelTileHeight: 32, name: "Forest")

    let p = resolver.terrainPlacement(graphicIndex: 329, tileset: tileset)
    expect(p != nil, "terrain placement resolved for a real tileset")
    expectEqual(p?.relativePath, "tilesets/summer/terrain/summer.png", "terrain path passthrough")
    expectEqual(p?.frame, 329, "terrain frame = graphic index")
    expectEqual(p?.cellWidth, 32, "terrain cell width")
    expectEqual(p?.mirror, false, "terrain never mirrors")
    expect(p?.teamTint == nil, "terrain has no team tint")
    expectEqual(p?.isGeneratedCache, false, "an authored asset path is not a generated-cache placement")

    // A tileset descriptor whose ABI v5 `pathRoot` discriminator says
    // "writable cache root" (regardless of its filename) is flagged so the
    // material provider resolves it against the writable cache root instead
    // of the read-only staged data root. This is the *authoritative* signal
    // (not the "tabletop-generated/" filename convention, which is engine-side
    // documentation only — see TabletopAssetPath.generatedCachePrefix).
    let generated = TabletopTilesetInfo(
        imagePath: "tabletop-generated/forest-v1-abcdef0123456789.png",
        pixelTileWidth: 32, pixelTileHeight: 32, name: "Forest",
        pathRoot: .cacheRoot)
    let gp = resolver.terrainPlacement(graphicIndex: 329, tileset: generated)
    expect(gp != nil, "terrain placement resolved for a generated-cache tileset")
    expectEqual(gp?.isGeneratedCache, true, "pathRoot == .cacheRoot is flagged as generated-cache")

    // The filename convention alone is NOT authoritative: a descriptor whose
    // path happens to start with "tabletop-generated/" but whose pathRoot
    // still says .dataRoot (e.g. an older/misbehaving engine build, or any
    // future rename of the convention) must resolve against the data root,
    // not be silently treated as generated-cache by name-sniffing.
    let lookalike = TabletopTilesetInfo(
        imagePath: "tabletop-generated/forest-v1-abcdef0123456789.png",
        pixelTileWidth: 32, pixelTileHeight: 32, name: "Forest",
        pathRoot: .dataRoot)
    let lp = resolver.terrainPlacement(graphicIndex: 329, tileset: lookalike)
    expectEqual(lp?.isGeneratedCache, false,
                "pathRoot is authoritative even when the filename looks generated")

    // Missing / corrupt descriptors → nil (per-tile procedural fallback).
    expect(resolver.terrainPlacement(graphicIndex: 5, tileset: nil) == nil,
           "no tileset => nil terrain placement")
    let noPath = TabletopTilesetInfo(imagePath: "", pixelTileWidth: 32, pixelTileHeight: 32)
    expect(resolver.terrainPlacement(graphicIndex: 5, tileset: noPath) == nil,
           "empty tileset path => nil")
    let zeroCell = TabletopTilesetInfo(imagePath: "t.png", pixelTileWidth: 0, pixelTileHeight: 32)
    expect(resolver.terrainPlacement(graphicIndex: 5, tileset: zeroCell) == nil,
           "zero tile size => nil")
    let badPath = TabletopTilesetInfo(imagePath: "../escape.png", pixelTileWidth: 32, pixelTileHeight: 32)
    expect(resolver.terrainPlacement(graphicIndex: 5, tileset: badPath) == nil,
           "unconfinable tileset path => nil")
}

func testUnitPlacement() {
    let resolver = WargusStagedAssetResolver()
    let sprite = TabletopUnitSpriteInfo(
        spritePath: "human/units/footman.png",
        frameWidth: 72, frameHeight: 72, numDirections: 5, flip: true,
        teamColorStart: 208, teamColorCount: 4)

    let unit = TabletopGameplayUnit(
        id: "1", owner: 1, hp: 60, maxHP: 60, facingRadians: 0, tileX: 3, tileZ: 4,
        kind: "unit-footman", spriteFrame: 12, spriteMirror: true)
    let p = resolver.unitPlacement(unit: unit, sprite: sprite)
    expect(p != nil, "unit placement resolved for a real sprite")
    expectEqual(p?.relativePath, "human/units/footman.png", "unit sprite path passthrough")
    expectEqual(p?.frame, 12, "unit frame from engine-resolved sprite frame")
    expectEqual(p?.mirror, true, "unit mirror from engine-resolved flag")
    expect(p?.teamTint == TabletopTeamPalette.tint(owner: 1),
           "team tint applied for a team-colored sprite")

    // No team color span => no tint.
    let noTeam = TabletopUnitSpriteInfo(
        spritePath: "neutral/crate.png", frameWidth: 32, frameHeight: 32,
        numDirections: 1, flip: false, teamColorStart: 0, teamColorCount: 0)
    let p2 = resolver.unitPlacement(unit: unit, sprite: noTeam)
    expect(p2?.teamTint == nil, "no team span => no tint")

    // Missing sprite / bad path => nil (per-unit procedural fallback).
    expect(resolver.unitPlacement(unit: unit, sprite: nil) == nil, "no sprite => nil")
    let badPath = TabletopUnitSpriteInfo(
        spritePath: "/abs/footman.png", frameWidth: 72, frameHeight: 72,
        numDirections: 5, flip: true)
    expect(resolver.unitPlacement(unit: unit, sprite: badPath) == nil,
           "unconfinable sprite path => nil")

    // Negative engine frame is clamped to 0.
    let negUnit = TabletopGameplayUnit(
        id: "2", owner: 0, hp: 60, maxHP: 60, facingRadians: 0, tileX: 0, tileZ: 0,
        kind: "unit-footman", spriteFrame: -3, spriteMirror: false)
    expectEqual(resolver.unitPlacement(unit: negUnit, sprite: sprite)?.frame, 0,
                "negative frame clamped to 0")
}

func testPlacementSourceRectAndKey() {
    let resolver = WargusStagedAssetResolver()
    let sprite = TabletopUnitSpriteInfo(
        spritePath: "human/units/footman.png", frameWidth: 72, frameHeight: 72,
        numDirections: 5, flip: true, teamColorStart: 208, teamColorCount: 4)
    let unit = TabletopGameplayUnit(
        id: "1", owner: 2, hp: 60, maxHP: 60, facingRadians: 0, tileX: 0, tileZ: 0,
        kind: "unit-footman", spriteFrame: 9, spriteMirror: false)
    let p = resolver.unitPlacement(unit: unit, sprite: sprite)!
    // 576x144 sheet => 8 cols; frame 9 => row 1 col 1.
    expectEqual(p.sourceRect(imageWidth: 576, imageHeight: 144),
                TabletopSourceRect(x: 72, y: 72, width: 72, height: 72),
                "placement computes its source rect from decoded dims")
    // Distinct placements have distinct cache keys; identical inputs match.
    let p2 = resolver.unitPlacement(unit: unit, sprite: sprite)!
    expectEqual(p.cacheKey, p2.cacheKey, "identical placements share a cache key")
    let otherUnit = TabletopGameplayUnit(
        id: "1", owner: 3, hp: 60, maxHP: 60, facingRadians: 0, tileX: 0, tileZ: 0,
        kind: "unit-footman", spriteFrame: 9, spriteMirror: false)
    let p3 = resolver.unitPlacement(unit: otherUnit, sprite: sprite)!
    expect(p.cacheKey != p3.cacheKey, "different team tint => different cache key")

    // Regression: the *same* relative path under the data root vs. the
    // writable cache root must never alias in the LRU cache / in-flight
    // `pending` dictionary (both keyed on `cacheKey`), even though the path
    // text, frame, cell size, mirror, and tint are otherwise identical —
    // otherwise a tileset transition that toggles only the root (not the
    // path text) could serve/coalesce onto a decode of the wrong root's
    // file. See WargusTabletopMaterialProvider.root(for:).
    let dataRootPlacement = TabletopAssetPlacement(
        relativePath: "tabletop-generated/forest-v1-aaaa.png",
        frame: 5, cellWidth: 32, cellHeight: 32, mirror: false, teamTint: nil,
        isGeneratedCache: false)
    let cacheRootPlacement = TabletopAssetPlacement(
        relativePath: "tabletop-generated/forest-v1-aaaa.png",
        frame: 5, cellWidth: 32, cellHeight: 32, mirror: false, teamTint: nil,
        isGeneratedCache: true)
    expect(dataRootPlacement.relativePath == cacheRootPlacement.relativePath,
           "precondition: identical path text")
    expect(dataRootPlacement.cacheKey != cacheRootPlacement.cacheKey,
           "same relative path but different root => distinct cache keys (never aliased)")
}

// MARK: - Bounded LRU cache

func testLRUCache() {
    let cache = TabletopLRUCache<String, Int>(capacity: 2)
    expect(cache.setValue(1, forKey: "a") == nil, "insert a (no eviction)")
    expect(cache.setValue(2, forKey: "b") == nil, "insert b (no eviction)")
    expectEqual(cache.count, 2, "cache holds two entries")

    // Touch "a" so "b" becomes least-recently-used.
    expectEqual(cache.value(forKey: "a"), 1, "read a")
    let evicted = cache.setValue(3, forKey: "c")
    expectEqual(evicted, 2, "inserting c evicts least-recently-used b")
    expect(cache.value(forKey: "b") == nil, "b was evicted")
    expectEqual(cache.value(forKey: "a"), 1, "a survived (recently used)")
    expectEqual(cache.value(forKey: "c"), 3, "c present")

    // Updating an existing key does not evict.
    expect(cache.setValue(30, forKey: "c") == nil, "update c (no eviction)")
    expectEqual(cache.count, 2, "still two entries after update")

    cache.removeAll()
    expectEqual(cache.count, 0, "removeAll clears the cache")
}

// MARK: - Runner

@main
struct AssetResolutionTests {
    static func main() {
        testPathConfinement()
        testAtlasGeometry()
        testExtendedTilesetFrameResolution()
        testTeamPalette()
        testTerrainPlacement()
        testUnitPlacement()
        testPlacementSourceRectAndKey()
        testLRUCache()

        if failedChecks == 0 {
            print("PASSED: \(totalChecks)/\(totalChecks) checks")
        } else {
            print("FAILED: \(failedChecks)/\(totalChecks) checks failed")
            exit(1)
        }
    }
}
