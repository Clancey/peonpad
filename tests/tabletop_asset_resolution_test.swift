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
}

// MARK: - Team color

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
