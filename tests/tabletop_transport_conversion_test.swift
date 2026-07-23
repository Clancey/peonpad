// tabletop_transport_conversion_test.swift
//
// Standalone pure-logic tests for the live engine transport layer:
//   - EngineSnapshot → TabletopGameplaySnapshot conversion
//     (TabletopSnapshotConverter): ABI version guard, terrain/fog/unit
//     mapping, unit-type ident resolution, selection.
//   - TabletopGameplayCommand → EngineCommand lowering
//     (EngineCommandEncoder): id parsing, out-of-range rejection.
//   - Board map-fit geometry (TabletopMapFit).
//   - Asset key mapping (WargusTabletopAssetResolver).
//   - Engine startup preconditions and argv (EngineStartupPlanner).
//
// No dependency on RealityKit, SwiftUI, UIKit, C interop, or the engine.
// Compiles and runs on the host Mac:
//
//   ./scripts/test-visionos-tabletop-transport.sh
import Foundation

// MARK: - Minimal test harness

private var failureCount = 0
private var checkCount = 0

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String,
    file: StaticString = #file,
    line: UInt = #line
) {
    checkCount += 1
    if !condition() {
        failureCount += 1
        print("FAIL [\(file):\(line)]: \(message)")
    }
}

private func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: String,
    file: StaticString = #file,
    line: UInt = #line
) {
    expect(actual == expected,
           "\(message) -- expected \(expected), got \(actual)",
           file: file, line: line)
}

private func approxEqual(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool {
    abs(a - b) <= tol
}

// MARK: - Fixtures

private func makeEngineSnapshot(
    abiVersion: UInt32 = kPeonPadTabletopABIVersion,
    width: UInt32 = 2,
    height: UInt32 = 2,
    terrain: [EngineTerrainCell]? = nil,
    units: [EngineUnitRecord] = [],
    types: [EngineUnitType] = []
) -> EngineSnapshot {
    let cells = terrain ?? Array(
        repeating: EngineTerrainCell(tileIndex: 0,
                                     fogState: EngineFogState.visible.rawValue,
                                     terrainClass: EngineTerrainClass.grass.rawValue),
        count: Int(width) * Int(height))
    return EngineSnapshot(
        abiVersion: abiVersion, generation: 1,
        mapWidth: width, mapHeight: height,
        terrain: cells, units: units, unitTypes: types)
}

// MARK: - Converter: ABI + structural guards

func testConversionRejectsABIMismatch() {
    let snap = makeEngineSnapshot(abiVersion: kPeonPadTabletopABIVersion + 1)
    do {
        _ = try TabletopSnapshotConverter.convert(snap)
        expect(false, "conversion must throw on ABI mismatch")
    } catch let e as TabletopConversionError {
        expectEqual(e, .abiVersionMismatch(
            expected: kPeonPadTabletopABIVersion,
            actual: kPeonPadTabletopABIVersion + 1),
            "ABI mismatch surfaces the expected/actual versions")
    } catch {
        expect(false, "unexpected error type: \(error)")
    }
}

func testConversionRejectsEmptyMap() {
    let snap = EngineSnapshot(abiVersion: kPeonPadTabletopABIVersion, generation: 1,
                              mapWidth: 0, mapHeight: 0, terrain: [], units: [], unitTypes: [])
    do {
        _ = try TabletopSnapshotConverter.convert(snap)
        expect(false, "conversion must throw on empty map")
    } catch let e as TabletopConversionError {
        expectEqual(e, .emptyMap, "empty map is rejected")
    } catch { expect(false, "unexpected error: \(error)") }
}

func testConversionRejectsTerrainCountMismatch() {
    let snap = EngineSnapshot(abiVersion: kPeonPadTabletopABIVersion, generation: 1,
                              mapWidth: 3, mapHeight: 3,
                              terrain: [EngineTerrainCell(tileIndex: 0, fogState: 2, terrainClass: 1)],
                              units: [], unitTypes: [])
    do {
        _ = try TabletopSnapshotConverter.convert(snap)
        expect(false, "conversion must throw on terrain count mismatch")
    } catch let e as TabletopConversionError {
        expectEqual(e, .terrainCountMismatch(expected: 9, actual: 1),
                    "terrain count mismatch is reported with counts")
    } catch { expect(false, "unexpected error: \(error)") }
}

// MARK: - Converter: field mappings

func testFacingConversion() {
    expect(approxEqual(TabletopSnapshotConverter.facingRadians(0), 0),
           "facing 0 -> 0 rad")
    expect(approxEqual(TabletopSnapshotConverter.facingRadians(64), .pi / 2),
           "facing 64 -> pi/2")
    expect(approxEqual(TabletopSnapshotConverter.facingRadians(128), .pi),
           "facing 128 -> pi")
    expect(approxEqual(TabletopSnapshotConverter.facingRadians(192), 3 * .pi / 2),
           "facing 192 -> 3pi/2")
}

func testTerrainClassMapping() {
    let cases: [(EngineTerrainClass, TabletopTerrainKind)] = [
        (.grass, .grass), (.dirt, .dirt), (.water, .water), (.rock, .rock),
        (.forest, .forest), (.coast, .water), (.wall, .rock), (.unknown, .grass),
    ]
    for (raw, expected) in cases {
        expectEqual(TabletopSnapshotConverter.terrainKind(raw.rawValue), expected,
                    "terrain class \(raw) -> \(expected)")
    }
    // An out-of-range class value falls back to grass rather than crashing.
    expectEqual(TabletopSnapshotConverter.terrainKind(200), .grass,
                "unknown terrain class byte -> grass")
}

func testFogMapping() {
    expectEqual(TabletopSnapshotConverter.isRevealed(EngineFogState.unseen.rawValue), false,
                "unseen -> not revealed")
    expectEqual(TabletopSnapshotConverter.isRevealed(EngineFogState.explored.rawValue), true,
                "explored -> revealed")
    expectEqual(TabletopSnapshotConverter.isRevealed(EngineFogState.visible.rawValue), true,
                "visible -> revealed")

    // Canonical three-state mapping preserves the explored (dim) state.
    expectEqual(TabletopSnapshotConverter.fogVisibility(EngineFogState.unseen.rawValue), .unexplored,
                "unseen -> unexplored")
    expectEqual(TabletopSnapshotConverter.fogVisibility(EngineFogState.explored.rawValue), .explored,
                "explored -> explored (not collapsed to visible)")
    expectEqual(TabletopSnapshotConverter.fogVisibility(EngineFogState.visible.rawValue), .visible,
                "visible -> visible")
    // An unknown fog byte must hide (safest), never disclose.
    expectEqual(TabletopSnapshotConverter.fogVisibility(200), .unexplored,
                "unknown fog byte -> unexplored (no disclosure)")
}

func testFogThreeStateConversionPreservesExplored() {
    let terrain = [
        EngineTerrainCell(tileIndex: 1, fogState: EngineFogState.visible.rawValue,
                          terrainClass: EngineTerrainClass.grass.rawValue),
        EngineTerrainCell(tileIndex: 2, fogState: EngineFogState.explored.rawValue,
                          terrainClass: EngineTerrainClass.grass.rawValue),
        EngineTerrainCell(tileIndex: 3, fogState: EngineFogState.unseen.rawValue,
                          terrainClass: EngineTerrainClass.grass.rawValue),
    ]
    let snap = EngineSnapshot(abiVersion: kPeonPadTabletopABIVersion, generation: 1,
                              mapWidth: 3, mapHeight: 1, terrain: terrain,
                              units: [], unitTypes: [])
    guard let result = try? TabletopSnapshotConverter.convert(snap) else {
        expect(false, "conversion must succeed"); return
    }
    expectEqual(result.fogVisibility(atTileX: 0, tileZ: 0), .visible, "cell 0 visible")
    expectEqual(result.fogVisibility(atTileX: 1, tileZ: 0), .explored, "cell 1 explored (dim)")
    expectEqual(result.fogVisibility(atTileX: 2, tileZ: 0), .unexplored, "cell 2 unexplored")
}

func testFullConversionUnitsAndSelection() {
    let terrain = [
        EngineTerrainCell(tileIndex: 1, fogState: EngineFogState.visible.rawValue,
                          terrainClass: EngineTerrainClass.forest.rawValue),
        EngineTerrainCell(tileIndex: 2, fogState: EngineFogState.unseen.rawValue,
                          terrainClass: EngineTerrainClass.water.rawValue),
    ]
    let units = [
        EngineUnitRecord(id: 101, owner: 0, alive: 1, selected: 1, facing: 0,
                         hp: 60, maxHP: 60, tileX: 0, tileY: 0, worldX: 0, worldY: 0, typeID: 7),
        EngineUnitRecord(id: 202, owner: 1, alive: 1, selected: 0, facing: 128,
                         hp: 40, maxHP: 100, tileX: 1, tileY: 0, worldX: 0, worldY: 0, typeID: 9),
    ]
    let types = [
        EngineUnitType(typeID: 7, ident: "unit-footman"),
        EngineUnitType(typeID: 9, ident: "unit-grunt"),
    ]
    let snap = EngineSnapshot(abiVersion: kPeonPadTabletopABIVersion, generation: 5,
                              mapWidth: 2, mapHeight: 1, terrain: terrain,
                              units: units, unitTypes: types)
    guard let result = try? TabletopSnapshotConverter.convert(snap) else {
        expect(false, "conversion of a valid snapshot must succeed"); return
    }
    expectEqual(result.mapSize.width, 2, "map width preserved")
    expectEqual(result.mapSize.height, 1, "map height preserved")
    expectEqual(result.terrain.count, 2, "one terrain tile per cell")
    expectEqual(result.terrain(atTileX: 0, tileZ: 0), .forest, "cell 0 forest")
    expectEqual(result.terrain(atTileX: 1, tileZ: 0), .water, "cell 1 water")
    expectEqual(result.fog(atTileX: 0, tileZ: 0), true, "cell 0 revealed")
    expectEqual(result.fog(atTileX: 1, tileZ: 0), false, "cell 1 fogged")
    expectEqual(result.units.count, 2, "both units converted")
    expectEqual(result.units[0].id, "101", "uint32 id -> decimal string")
    expectEqual(result.units[0].kind, "unit-footman", "type id resolved to ident")
    expectEqual(result.units[1].kind, "unit-grunt", "second type id resolved")
    expectEqual(result.selection.selectedUnitID, "101",
                "first selected alive unit becomes the UI selection")
    expect(approxEqual(result.units[1].facingRadians, .pi),
           "unit facing byte converted to radians")
}

func testConversionMapsUnknownTypeToEmptyKind() {
    let units = [EngineUnitRecord(id: 1, owner: 0, alive: 1, selected: 0, facing: 0,
                                  hp: 1, maxHP: 1, tileX: 0, tileY: 0, worldX: 0, worldY: 0,
                                  typeID: 999)]
    let snap = makeEngineSnapshot(width: 1, height: 1, units: units, types: [])
    let result = try? TabletopSnapshotConverter.convert(snap)
    expectEqual(result?.units.first?.kind, "", "unresolved type id -> empty kind")
}

// MARK: - Command encoder

func testCommandEncoding() {
    expectEqual(EngineCommandEncoder.encode(.deselectAll),
                EngineCommand(kind: .deselectAll), "deselectAll always encodes")
    expectEqual(EngineCommandEncoder.encode(.selectUnit(id: "42")),
                EngineCommand(kind: .select, unitID: 42), "select encodes id")
    expectEqual(EngineCommandEncoder.encode(.stopUnit(id: "7")),
                EngineCommand(kind: .stop, unitID: 7), "stop encodes id")
    expectEqual(EngineCommandEncoder.encode(.moveUnit(id: "3", toTileX: 5, toTileZ: 9)),
                EngineCommand(kind: .move, unitID: 3, tileX: 5, tileY: 9), "move encodes")
}

func testCommandEncodingRejectsBadInput() {
    expect(EngineCommandEncoder.encode(.selectUnit(id: "sentry.north")) == nil,
           "non-numeric unit id cannot encode")
    expect(EngineCommandEncoder.encode(.moveUnit(id: "1", toTileX: -1, toTileZ: 0)) == nil,
           "negative tile rejected")
    expect(EngineCommandEncoder.encode(.moveUnit(id: "1", toTileX: 0, toTileZ: 5000)) == nil,
           "tile beyond max map dim rejected")
    expect(EngineCommandEncoder.encode(.moveUnit(id: "1", toTileX: 1023, toTileZ: 0)) != nil,
           "tile at max-1 accepted")
}

// MARK: - Map fit

func testMapFitTileSizeAndCentering() {
    let fit = TabletopMapFit(width: 4, height: 2, boardExtent: 0.8)
    expect(approxEqual(Double(fit.tileSize), 0.2, 1e-5),
           "tileSize = extent / max(dim)")
    // Map is centered: tile (0,0) is at the top-left offset from center.
    let c0 = fit.tileCenter(tileX: 0, tileZ: 0)
    expect(approxEqual(Double(c0.x), -0.3, 1e-5) && approxEqual(Double(c0.z), -0.1, 1e-5),
           "tile (0,0) centered correctly")
    let c3 = fit.tileCenter(tileX: 3, tileZ: 1)
    expect(approxEqual(Double(c3.x), 0.3, 1e-5) && approxEqual(Double(c3.z), 0.1, 1e-5),
           "tile (3,1) centered correctly")
}

func testMapFitRoundTrip() {
    let fit = TabletopMapFit(width: 8, height: 8, boardExtent: 0.84)
    for (tx, tz) in [(0, 0), (3, 5), (7, 7)] {
        let c = fit.tileCenter(tileX: tx, tileZ: tz)
        let back = fit.tile(atX: c.x, z: c.z)
        expectEqual(back.tileX, tx, "round-trip tileX")
        expectEqual(back.tileZ, tz, "round-trip tileZ")
    }
    expect(fit.contains(tileX: 7, tileZ: 7), "in-bounds tile is contained")
    expect(!fit.contains(tileX: 8, tileZ: 0), "out-of-bounds tile is not contained")
    expect(!fit.contains(tileX: -1, tileZ: 0), "negative tile is not contained")
}

func testMapFitDegenerate() {
    let fit = TabletopMapFit(width: 0, height: 0, boardExtent: 0.8)
    expect(fit.tileSize > 0, "degenerate map still yields a positive tile size")
}

// MARK: - Asset resolver

func testAssetResolverGatingAndNames() {
    // Empty catalog behaves like the null resolver.
    let empty = WargusTabletopAssetResolver()
    expect(empty.terrainTexture(for: .grass) == nil, "no terrain art without catalog")
    expect(empty.unitSprite(unitKind: "unit-footman", canonical: .north) == nil,
           "no unit art without catalog")

    // A catalog containing the resource name returns it.
    let terrainName = WargusTabletopAssetResolver.terrainResourceName(for: .water)
    let unitBase = WargusTabletopAssetResolver.unitResourceBase(for: "unit-grunt")!
    let unitName = "\(unitBase).\(WargusTabletopAssetResolver.facingSuffix(.southEast))"
    let resolver = WargusTabletopAssetResolver(catalog: [terrainName, unitName])
    expectEqual(resolver.terrainTexture(for: .water), terrainName, "terrain name gated in")
    expectEqual(resolver.unitSprite(unitKind: "unit-grunt", canonical: .southEast), unitName,
                "unit sprite name gated in")
    // A facing not in the catalog is nil (procedural fallback).
    expect(resolver.unitSprite(unitKind: "unit-grunt", canonical: .north) == nil,
           "missing facing -> nil")
}

func testAssetResolverIdentNormalization() {
    expectEqual(WargusTabletopAssetResolver.unitResourceBase(for: "unit-footman"),
                "wargus/units/footman", "strips unit- prefix")
    expectEqual(WargusTabletopAssetResolver.unitResourceBase(for: "peasant"),
                "wargus/units/peasant", "no prefix passthrough")
    expect(WargusTabletopAssetResolver.unitResourceBase(for: "") == nil,
           "empty ident -> nil")
    expect(WargusTabletopAssetResolver.unitResourceBase(for: "  ") == nil,
           "whitespace ident -> nil")
    expect(WargusTabletopAssetResolver.unitResourceBase(for: "unit-") == nil,
           "bare prefix -> nil")
}

// MARK: - Engine startup planner

func testStartupValidation() {
    let config = EngineLaunchConfig(dataPath: "/data/wargus", userPath: "/user")

    // Happy path.
    expect(EngineStartupPlanner.validate(config,
        directoryExists: { _ in true },
        fileExists: { $0 == "/data/wargus/scripts/stratagus.lua" },
        isWritable: { _ in true }) == nil,
        "valid data + writable user -> no error")

    // Missing data dir.
    expectEqual(EngineStartupPlanner.validate(config,
        directoryExists: { _ in false }, fileExists: { _ in false }, isWritable: { _ in true }),
        .dataPathMissing(path: "/data/wargus"), "missing data dir reported")

    // Data dir present but no entry script.
    expectEqual(EngineStartupPlanner.validate(config,
        directoryExists: { _ in true }, fileExists: { _ in false }, isWritable: { _ in true }),
        .dataPathIncomplete(path: "/data/wargus", missing: "scripts/stratagus.lua"),
        "incomplete data dir reported")

    // User dir not writable.
    expectEqual(EngineStartupPlanner.validate(config,
        directoryExists: { _ in true }, fileExists: { _ in true }, isWritable: { _ in false }),
        .userPathNotWritable(path: "/user"), "non-writable user dir reported")
}

func testStartupArguments() {
    let withScenario = EngineLaunchConfig(dataPath: "/d", userPath: "/u",
                                          scenario: "maps/one.smp", executableName: "peonpad")
    expectEqual(EngineStartupPlanner.arguments(for: withScenario),
                ["peonpad", "-d", "/d", "-u", "/u", "maps/one.smp"],
                "argv includes -d/-u and trailing map")
    let noScenario = EngineLaunchConfig(dataPath: "/d", userPath: "/u", executableName: "peonpad")
    expectEqual(EngineStartupPlanner.arguments(for: noScenario),
                ["peonpad", "-d", "/d", "-u", "/u"],
                "argv omits map when no scenario")
}

// MARK: - Converter: ABI v3 asset descriptors

func testConversionBuildsAssetCatalog() {
    let tileset = EngineTilesetDescriptor(
        imagePath: "tilesets/summer/terrain/summer.png",
        pixelTileWidth: 32, pixelTileHeight: 32, name: "Forest")
    let terrain = [
        EngineTerrainCell(tileIndex: 1, fogState: EngineFogState.visible.rawValue,
                          terrainClass: EngineTerrainClass.grass.rawValue, graphicIndex: 100),
        EngineTerrainCell(tileIndex: 2, fogState: EngineFogState.explored.rawValue,
                          terrainClass: EngineTerrainClass.forest.rawValue, graphicIndex: 329),
    ]
    let units = [
        EngineUnitRecord(id: 7, owner: 1, alive: 1, selected: 0, facing: 64,
                         hp: 60, maxHP: 60, tileX: 0, tileY: 0,
                         worldX: 0, worldY: 0, typeID: 3,
                         spriteFrame: 45, spriteMirror: 1),
    ]
    let types = [
        EngineUnitType(typeID: 3, ident: "unit-footman",
                       spritePath: "human/units/footman.png",
                       frameWidth: 72, frameHeight: 72, numDirections: 5, flip: 1,
                       teamColorStart: 208, teamColorCount: 4),
    ]
    let snap = EngineSnapshot(
        abiVersion: kPeonPadTabletopABIVersion, generation: 5,
        mapWidth: 2, mapHeight: 1,
        terrain: terrain, units: units, unitTypes: types, tileset: tileset)

    guard let ui = try? TabletopSnapshotConverter.convert(snap) else {
        expect(false, "v3 snapshot converts")
        return
    }

    // Terrain graphic_index carried through.
    expectEqual(ui.terrain[0].graphicIndex, 100, "terrain[0] graphic index")
    expectEqual(ui.terrain[1].graphicIndex, 329, "terrain[1] graphic index")

    // Unit sprite frame + mirror carried through.
    expectEqual(ui.units[0].spriteFrame, 45, "unit sprite frame")
    expectEqual(ui.units[0].spriteMirror, true, "unit sprite mirror")

    // Asset catalog present with tileset + sprite descriptor.
    guard let assets = ui.assets else {
        expect(false, "asset catalog present for v3 snapshot")
        return
    }
    expectEqual(assets.tileset?.imagePath, "tilesets/summer/terrain/summer.png",
                "catalog tileset path")
    expectEqual(assets.tileset?.pixelTileWidth, 32, "catalog tileset tile width")
    expectEqual(assets.tileset?.pathRoot, .dataRoot,
                "catalog tileset defaults to the data root (ABI v4-or-earlier / unset pathRoot)")
    let sprite = assets.sprite(forUnitKind: "unit-footman")
    expectEqual(sprite?.spritePath, "human/units/footman.png", "catalog sprite path")
    expectEqual(sprite?.frameWidth, 72, "catalog sprite frame width")
    expectEqual(sprite?.flip, true, "catalog sprite flip")
    expectEqual(sprite?.teamColorCount, 4, "catalog sprite team color span")

    // End-to-end: the staged resolver turns the converted snapshot into a
    // real placement without any bundled art.
    let resolver = WargusStagedAssetResolver()
    let placement = resolver.unitPlacement(unit: ui.units[0], sprite: sprite)
    expectEqual(placement?.relativePath, "human/units/footman.png", "resolved unit path")
    expectEqual(placement?.frame, 45, "resolved unit frame")
    expectEqual(placement?.mirror, true, "resolved unit mirror")
    expect(placement?.teamTint == TabletopTeamPalette.tint(owner: 1),
           "resolved unit team tint for owner 1")
}

// ABI v5: the path-root discriminator round-trips end to end (engine ABI
// byte -> EngineTilesetDescriptor -> TabletopSnapshotConverter ->
// TabletopTilesetInfo -> WargusStagedAssetResolver), and drives the
// generated-cache placement flag rather than any filename convention.
func testConversionCarriesTilesetPathRoot() {
    let generatedTileset = EngineTilesetDescriptor(
        imagePath: "tabletop-generated/forest-v1-abcdef0123456789.png",
        pixelTileWidth: 32, pixelTileHeight: 32, name: "Forest",
        pathRoot: 1) // PEONPAD_TILESET_PATH_ROOT_CACHE
    let snap = EngineSnapshot(
        abiVersion: kPeonPadTabletopABIVersion, generation: 6,
        mapWidth: 1, mapHeight: 1,
        terrain: [EngineTerrainCell(tileIndex: 1, fogState: EngineFogState.visible.rawValue,
                                    terrainClass: EngineTerrainClass.grass.rawValue, graphicIndex: 5)],
        units: [], unitTypes: [], tileset: generatedTileset)

    guard let ui = try? TabletopSnapshotConverter.convert(snap) else {
        expect(false, "v5 snapshot with a cache-root tileset converts")
        return
    }
    expectEqual(ui.assets?.tileset?.pathRoot, .cacheRoot,
                "raw pathRoot byte 1 converts to TabletopTilesetPathRoot.cacheRoot")

    let resolver = WargusStagedAssetResolver()
    let placement = resolver.terrainPlacement(graphicIndex: 5, tileset: ui.assets?.tileset)
    expectEqual(placement?.isGeneratedCache, true,
                "the converted pathRoot — not the filename — drives isGeneratedCache")

    // An unrecognized/future raw pathRoot byte defaults defensively to the
    // data root rather than being misread as some other placement.
    let unknownRoot = EngineTilesetDescriptor(
        imagePath: "tilesets/summer/terrain/summer.png",
        pixelTileWidth: 32, pixelTileHeight: 32, name: "Forest", pathRoot: 200)
    let snap2 = EngineSnapshot(
        abiVersion: kPeonPadTabletopABIVersion, generation: 7,
        mapWidth: 1, mapHeight: 1,
        terrain: [EngineTerrainCell(tileIndex: 1, fogState: EngineFogState.visible.rawValue,
                                    terrainClass: EngineTerrainClass.grass.rawValue, graphicIndex: 5)],
        units: [], unitTypes: [], tileset: unknownRoot)
    guard let ui2 = try? TabletopSnapshotConverter.convert(snap2) else {
        expect(false, "v5 snapshot with an unrecognized pathRoot byte still converts")
        return
    }
    expectEqual(ui2.assets?.tileset?.pathRoot, .dataRoot,
                "an unrecognized pathRoot byte defaults to .dataRoot, never crashes/misreads")
}

// MARK: - ABI v4 render category + footprint

func testRenderCategoryMapping() {
    expectEqual(TabletopSnapshotConverter.renderCategory(EngineRenderCategory.mobile.rawValue), .mobile,
                "mobile maps to mobile")
    expectEqual(TabletopSnapshotConverter.renderCategory(EngineRenderCategory.building.rawValue), .building,
                "building maps to building")
    expectEqual(TabletopSnapshotConverter.renderCategory(EngineRenderCategory.resource.rawValue), .resource,
                "resource maps to resource")
    expectEqual(TabletopSnapshotConverter.renderCategory(200), .mobile,
                "unknown category byte falls back to mobile")
}

func testConversionCarriesCategoryAndFootprint() {
    let types = [
        // A 4×4 human town hall (building), a 3×3 gold mine (resource), and a
        // 1×1 footman (mobile).
        EngineUnitType(typeID: 1, ident: "unit-town-hall",
                       spritePath: "human/buildings/town_hall.png",
                       frameWidth: 128, frameHeight: 128, numDirections: 1, flip: 0,
                       renderCategory: EngineRenderCategory.building.rawValue,
                       tileWidth: 4, tileHeight: 4),
        EngineUnitType(typeID: 2, ident: "unit-gold-mine",
                       spritePath: "neutral/buildings/gold_mine.png",
                       frameWidth: 96, frameHeight: 96, numDirections: 1, flip: 0,
                       renderCategory: EngineRenderCategory.resource.rawValue,
                       tileWidth: 3, tileHeight: 3),
        EngineUnitType(typeID: 3, ident: "unit-footman",
                       spritePath: "human/units/footman.png",
                       frameWidth: 72, frameHeight: 72, numDirections: 5, flip: 1,
                       renderCategory: EngineRenderCategory.mobile.rawValue,
                       tileWidth: 1, tileHeight: 1),
    ]
    let snap = EngineSnapshot(
        abiVersion: kPeonPadTabletopABIVersion, generation: 1,
        mapWidth: 1, mapHeight: 1,
        terrain: [EngineTerrainCell(tileIndex: 0, fogState: 2, terrainClass: 1)],
        units: [], unitTypes: types)
    guard let ui = try? TabletopSnapshotConverter.convert(snap),
          let assets = ui.assets else {
        expect(false, "v4 snapshot converts with a catalog"); return
    }
    let hall = assets.sprite(forUnitKind: "unit-town-hall")
    expectEqual(hall?.renderCategory, .building, "town hall is a building")
    expectEqual(hall?.footprintWidth, 4, "town hall footprint width 4")
    expectEqual(hall?.footprintHeight, 4, "town hall footprint height 4")

    let mine = assets.sprite(forUnitKind: "unit-gold-mine")
    expectEqual(mine?.renderCategory, .resource, "gold mine is a resource")
    expectEqual(mine?.footprintWidth, 3, "gold mine footprint 3×3")

    let footman = assets.sprite(forUnitKind: "unit-footman")
    expectEqual(footman?.renderCategory, .mobile, "footman is mobile")
    expectEqual(footman?.footprintWidth, 1, "footman footprint 1×1")
    // Mobile unit keeps its directional sheet.
    expectEqual(footman?.numDirections, 5, "footman still has 5 directions")

    // Only mobile units billboard toward the viewer; buildings/resources stay
    // map-oriented and never re-yaw as the board is orbited.
    expect(TabletopRenderCategory.mobile.billboardsTowardViewer,
           "mobile units billboard toward the viewer")
    expect(!TabletopRenderCategory.building.billboardsTowardViewer,
           "buildings stay map-oriented (no camera yaw)")
    expect(!TabletopRenderCategory.resource.billboardsTowardViewer,
           "resources stay map-oriented (no camera yaw)")
}

func testConversionOmitsCatalogForProceduralSnapshot() {
    // A snapshot with no tileset and empty sprite paths yields no catalog.
    let snap = makeEngineSnapshot()
    guard let ui = try? TabletopSnapshotConverter.convert(snap) else {
        expect(false, "procedural snapshot converts")
        return
    }
    expect(ui.assets == nil, "no asset catalog without engine art descriptors")
    expectEqual(ui.terrain[0].graphicIndex, 0, "default graphic index is 0")
}

// MARK: - Runner

@main
struct TransportConversionTests {
    static func main() {
        testConversionRejectsABIMismatch()
        testConversionRejectsEmptyMap()
        testConversionRejectsTerrainCountMismatch()
        testFacingConversion()
        testTerrainClassMapping()
        testFogMapping()
        testFogThreeStateConversionPreservesExplored()
        testFullConversionUnitsAndSelection()
        testConversionMapsUnknownTypeToEmptyKind()
        testConversionBuildsAssetCatalog()
        testConversionCarriesTilesetPathRoot()
        testRenderCategoryMapping()
        testConversionCarriesCategoryAndFootprint()
        testConversionOmitsCatalogForProceduralSnapshot()
        testCommandEncoding()
        testCommandEncodingRejectsBadInput()
        testMapFitTileSizeAndCentering()
        testMapFitRoundTrip()
        testMapFitDegenerate()
        testAssetResolverGatingAndNames()
        testAssetResolverIdentNormalization()
        testStartupValidation()
        testStartupArguments()

        if failureCount > 0 {
            print("FAILED: \(failureCount)/\(checkCount) checks failed")
            exit(1)
        }
        print("PASSED: \(checkCount)/\(checkCount) checks")
    }
}
