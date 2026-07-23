// tabletop_layers_test.swift
//
// Host-Mac unit tests for the framework-free 2.5D board-layer layer:
//   • TabletopBoardElevation      — strict, non-coplanar layer separation
//   • TabletopSubstrateLayout     — terrain/substrate footprint math
//   • TabletopSubstrateMeshBuilder— thick slab box geometry
//   • TabletopBoardReadiness      — stable-ready streaming state
//   • TabletopAtlasCompletionGate — stale async-completion rejection
//
// None of these require RealityKit, UIKit, or a Simulator.
//
//   ./scripts/test-visionos-tabletop-layers.sh
import Foundation

// MARK: - Harness

var totalChecks = 0
var failedChecks = 0

func expect(_ condition: Bool, _ message: String,
            file: StaticString = #file, line: Int = #line) {
    totalChecks += 1
    if !condition {
        failedChecks += 1
        fputs("FAIL [\(file):\(line)]: \(message)\n", stderr)
    }
}

func expectEq<T: Equatable>(_ a: T, _ b: T, _ message: String,
                             file: StaticString = #file, line: Int = #line) {
    totalChecks += 1
    if a != b {
        failedChecks += 1
        fputs("FAIL [\(file):\(line)]: \(message) — got \(a), expected \(b)\n", stderr)
    }
}

func expectClose(_ a: Float, _ b: Float, _ eps: Float, _ message: String,
                 file: StaticString = #file, line: Int = #line) {
    totalChecks += 1
    if abs(a - b) > eps {
        failedChecks += 1
        fputs("FAIL [\(file):\(line)]: \(message) — got \(a), expected \(b) ±\(eps)\n", stderr)
    }
}

// MARK: - Elevation separation (no coplanar layers)

func testElevationOrderingStrictlyIncreasing() {
    let e = TabletopBoardElevation.orderedElevations
    expectEq(e.count, 5, "five distinct layer reference elevations")
    for i in 1..<e.count {
        expect(e[i] > e[i - 1],
               "layer \(i) elevation \(e[i]) must be strictly above \(e[i-1]) (no coplanar)")
    }
}

func testTerrainAndFogNotCoplanar() {
    let fogAboveGround = TabletopBoardElevation.terrainSurfaceY + TabletopBoardElevation.fogGap
    expect(fogAboveGround > TabletopBoardElevation.terrainSurfaceY,
           "fog must be elevated above terrain")
    expect(TabletopBoardElevation.fogGap > 0,
           "fog gap must be positive so fog and terrain are never coplanar")
}

func testSubstrateBelowTerrain() {
    expect(TabletopBoardElevation.substrateTopY < TabletopBoardElevation.terrainSurfaceY,
           "substrate top must be below terrain surface (no coplanar)")
    expect(TabletopBoardElevation.substrateThickness > 0,
           "substrate must have positive thickness")
    // A board that reads as 2.5D needs meaningful thickness (> 1 cm).
    expect(TabletopBoardElevation.substrateThickness > 0.01,
           "substrate thickness \(TabletopBoardElevation.substrateThickness) should be visibly thick")
    // The slab must sit below even the lowest (recessed water) terrain.
    expect(TabletopBoardElevation.substrateTopY < TabletopTerrainRelief.minHeight,
           "substrate top must be below the lowest terrain (recessed water)")
}

// MARK: - Terrain relief (per-class height)

func testTerrainReliefOrdering() {
    // Water recessed, ground baseline, forest raised, rock highest.
    expect(TabletopTerrainRelief.height(.water) < 0, "water is recessed")
    expectEq(TabletopTerrainRelief.height(.grass), 0, "grass is the ground baseline")
    expectEq(TabletopTerrainRelief.height(.dirt), 0, "dirt is the ground baseline")
    expect(TabletopTerrainRelief.height(.forest) > TabletopTerrainRelief.height(.grass),
           "forest rises above ground")
    expect(TabletopTerrainRelief.height(.rock) > TabletopTerrainRelief.height(.forest),
           "rock is higher than forest")
}

func testTerrainReliefHasVisibleSpread() {
    // The relief must be large enough (> 1 cm total) to read as depth.
    let spread = TabletopTerrainRelief.maxHeight - TabletopTerrainRelief.minHeight
    expect(spread > 0.01, "relief spread \(spread) must be visibly large")
    expectEq(TabletopTerrainRelief.minHeight, TabletopTerrainRelief.height(.water), "min = water")
    expectEq(TabletopTerrainRelief.maxHeight, TabletopTerrainRelief.height(.rock), "max = rock")
}

func testMixedTransitionTilesPreserveMapPlane() {
    let transitionSlots = [
        (TabletopTerrainKind.coast, 0x200),
        (.rock, 0x400),
        (.forest, 0x700),
    ]
    for (kind, tileIndex) in transitionSlots {
        expectEq(TabletopTerrainRelief.height(kind, tileIndex: tileIndex), 0,
                 "\(kind) mixed slot \(tileIndex) stays on canonical map plane")
        expect(TabletopTerrainRelief.isMixedTransition(tileIndex: tileIndex),
               "\(tileIndex) is recognized as mixed transition art")
    }
    expect(TabletopTerrainRelief.height(.water, tileIndex: 0x010) < 0,
           "solid water retains recessed relief")
    expect(TabletopTerrainRelief.height(.water, tileIndex: 0x100) < 0,
           "water-to-water mixed frames retain the recessed water surface")
    expect(TabletopTerrainRelief.height(.forest, tileIndex: 0x070) > 0,
           "solid forest retains raised relief")
    expect(TabletopTerrainRelief.height(.rock, tileIndex: 0x080) > 0,
           "solid rock retains raised relief")
}

func testForestStandsUp() {
    // Forest tiles get an upright tree billboard; other classes do not.
    expect(TabletopTerrainRelief.standupHeight(.forest) > 0.02,
           "forest has a visible standing (tree) prop")
    for kind in TabletopTerrainKind.allCases where kind != .forest {
        expectEq(TabletopTerrainRelief.standupHeight(kind), 0, "\(kind) has no standing prop")
    }
}

// MARK: - Tree billboard decimation

func testTreeStrideOneWhenUnderCap() {
    expectEq(TabletopTreePlacement.stride(forestTileCount: 100, maxTrees: 700), 1,
             "few forest tiles ⇒ every tile is a tree")
    expectEq(TabletopTreePlacement.stride(forestTileCount: 700, maxTrees: 700), 1,
             "exactly at cap ⇒ stride 1")
}

func testTreeStrideBoundsCount() {
    // 10 000 forest tiles capped at 700 must not exceed the cap after decimation.
    let n = 10_000
    let s = TabletopTreePlacement.stride(forestTileCount: n, maxTrees: 700)
    expect(s > 1, "dense forest decimates (stride > 1)")
    let approx = (n + s * s - 1) / (s * s)
    expect(approx <= 700, "decimated tree count \(approx) stays within the cap")
}

func testTreePlacementIsRegularSubgrid() {
    expect(TabletopTreePlacement.isPlacementTile(tileX: 0, tileZ: 0, stride: 3),
           "(0,0) is on the stride-3 sub-grid")
    expect(TabletopTreePlacement.isPlacementTile(tileX: 3, tileZ: 6, stride: 3),
           "(3,6) is on the stride-3 sub-grid")
    expect(!TabletopTreePlacement.isPlacementTile(tileX: 1, tileZ: 0, stride: 3),
           "(1,0) is not on the stride-3 sub-grid")
    // Stride 1 selects every tile.
    expect(TabletopTreePlacement.isPlacementTile(tileX: 7, tileZ: 4, stride: 1),
           "stride 1 selects every tile")
}

// MARK: - Tree billboard vertical orientation (upside-down-tree regression)

func testTreeCardStandsUpright() {
    // Trees sample the flat forest terrain tile, whose v=0 is the tile's NORTH
    // edge and v=1 its SOUTH edge. An upright standing card must put the SOUTH
    // edge (v=1) at the TOP and the NORTH edge (v=0) at the BOTTOM — the
    // opposite of the flat terrain's north-up mapping. This guards the
    // upside-down-tree bug: a naive v=0-at-top card renders inverted.
    let uv = TabletopTreeCard.cornerUVs()
    expect(uv.tl.y > uv.bl.y, "tree card top samples a higher V than its bottom (upright)")
    expect(uv.tr.y > uv.br.y, "tree card top-right samples a higher V than bottom-right")
    expectEq(uv.tl.y, TabletopTreeCard.topV, "top-left V is the card top V")
    expectEq(uv.bl.y, TabletopTreeCard.bottomV, "bottom-left V is the card bottom V")
    expect(TabletopTreeCard.topV > TabletopTreeCard.bottomV,
           "card top V (\(TabletopTreeCard.topV)) is above bottom V (\(TabletopTreeCard.bottomV))")
    // Horizontal (U) is not mirrored: left column stays left.
    expectEq(uv.tl.x, uv.bl.x, "left corners share U")
    expectEq(uv.tr.x, uv.br.x, "right corners share U")
    expect(uv.tl.x < uv.tr.x, "U increases left→right")
}

func testFogFollowsAboveEveryTerrainHeight() {
    // Fog floats a fixed gap above each tile's own terrain height, so it is
    // above the tallest terrain and never coplanar with any of it.
    for kind in TabletopTerrainKind.allCases {
        let terrainH = TabletopTerrainRelief.height(kind)
        let fogH = terrainH + TabletopBoardElevation.fogGap
        expect(fogH > terrainH, "fog above \(kind) terrain")
    }
}

// MARK: - Substrate footprint

func testTerrainExtent() {
    let fit = TabletopMapFit(width: 128, height: 128, boardExtent: 0.84)
    let (w, d) = TabletopSubstrateLayout.terrainExtent(fit: fit, mapWidth: 128, mapHeight: 128)
    expectClose(w, Float(128) * fit.tileSize, 1e-5, "terrain width = 128 * tileSize")
    expectClose(d, Float(128) * fit.tileSize, 1e-5, "terrain depth = 128 * tileSize")
}

func testSubstrateExtentAddsFrameBorder() {
    let fit = TabletopMapFit(width: 64, height: 96, boardExtent: 0.84)
    let terrain = TabletopSubstrateLayout.terrainExtent(fit: fit, mapWidth: 64, mapHeight: 96)
    let slab    = TabletopSubstrateLayout.substrateExtent(fit: fit, mapWidth: 64, mapHeight: 96)
    let border  = TabletopBoardElevation.frameBorder
    expectClose(slab.width, terrain.width + 2 * border, 1e-5, "slab width adds frame border")
    expectClose(slab.depth, terrain.depth + 2 * border, 1e-5, "slab depth adds frame border")
    expect(slab.width > terrain.width && slab.depth > terrain.depth,
           "slab is strictly larger than the terrain it frames")
}

// MARK: - Substrate mesh geometry

func testSubstrateMeshIsSolidBox() {
    let geo = TabletopSubstrateMeshBuilder.build(width: 0.9, depth: 0.9)
    expectEq(geo.positions.count, 24, "box has 24 vertices (4 per face × 6)")
    expectEq(geo.normals.count, 24, "box has 24 normals")
    expectEq(geo.textureCoordinates.count, 24, "box has 24 uvs")
    expectEq(geo.triangleIndices.count, 36, "box has 36 indices (2 tris × 6 faces)")
    expect(!geo.isEmpty, "box mesh is not empty")
}

func testSubstrateMeshSpansThickness() {
    let top = TabletopBoardElevation.substrateTopY
    let bottom = TabletopBoardElevation.substrateBottomY
    let geo = TabletopSubstrateMeshBuilder.build(width: 0.9, depth: 0.9, topY: top, bottomY: bottom)
    let ys = geo.positions.map { $0.y }
    let minY = ys.min() ?? 0
    let maxY = ys.max() ?? 0
    expectClose(minY, bottom, 1e-6, "lowest vertex at substrate bottom")
    expectClose(maxY, top, 1e-6, "highest vertex at substrate top")
    // Every vertex is within the slab; the terrain plane (y=0) is above the top.
    expect(maxY < TabletopBoardElevation.terrainSurfaceY,
           "entire slab is below the terrain surface (no coplanar top)")
}

func testSubstrateMeshHasUpwardAndDownwardFaces() {
    let geo = TabletopSubstrateMeshBuilder.build(width: 1, depth: 1)
    let hasUp = geo.normals.contains { $0.y > 0.9 }
    let hasDown = geo.normals.contains { $0.y < -0.9 }
    let hasSide = geo.normals.contains { abs($0.x) > 0.9 || abs($0.z) > 0.9 }
    expect(hasUp, "slab has an upward (+Y) top face")
    expect(hasDown, "slab has a downward (−Y) bottom face")
    expect(hasSide, "slab has vertical side faces (visible thickness from the side)")
}

func testSubstrateMeshCentered() {
    let geo = TabletopSubstrateMeshBuilder.build(width: 0.8, depth: 0.6)
    let xs = geo.positions.map { $0.x }
    let zs = geo.positions.map { $0.z }
    expectClose((xs.min() ?? 0) + (xs.max() ?? 0), 0, 1e-6, "slab centered on X")
    expectClose((zs.min() ?? 0) + (zs.max() ?? 0), 0, 1e-6, "slab centered on Z")
    expectClose(xs.max() ?? 0, 0.4, 1e-6, "slab half-width = 0.4")
    expectClose(zs.max() ?? 0, 0.3, 1e-6, "slab half-depth = 0.3")
}

// MARK: - Readiness

func testReadinessNotStableUntilAllChunks() {
    expect(!TabletopBoardReadiness(totalChunks: 16, atlasReadyCount: 0).isStable,
           "0/16 not stable")
    expect(!TabletopBoardReadiness(totalChunks: 16, atlasReadyCount: 15).isStable,
           "15/16 not stable")
    expect(TabletopBoardReadiness(totalChunks: 16, atlasReadyCount: 16).isStable,
           "16/16 stable")
    expect(TabletopBoardReadiness(totalChunks: 16, atlasReadyCount: 99).isStable,
           "over-count still stable")
    expect(!TabletopBoardReadiness(totalChunks: 0, atlasReadyCount: 0).isStable,
           "empty board is not stable")
}

func testReadinessFraction() {
    expectEq(TabletopBoardReadiness(totalChunks: 4, atlasReadyCount: 1).fraction, 0.25,
             "1/4 = 0.25")
    expectEq(TabletopBoardReadiness(totalChunks: 4, atlasReadyCount: 8).fraction, 1.0,
             "fraction clamps to 1")
    expectEq(TabletopBoardReadiness(totalChunks: 0, atlasReadyCount: 3).fraction, 0.0,
             "empty board fraction is 0")
}

// MARK: - Atlas completion gate (stale rejection)

func testAtlasCompletionGate() {
    expect(TabletopAtlasCompletionGate.accepts(requestGeneration: 3, currentGeneration: 3),
           "matching generation accepted")
    expect(!TabletopAtlasCompletionGate.accepts(requestGeneration: 2, currentGeneration: 3),
           "older (stale) generation rejected")
    expect(!TabletopAtlasCompletionGate.accepts(requestGeneration: 4, currentGeneration: 3),
           "mismatched generation rejected")
}

// MARK: - Initial oblique placement

func testInitialPlacementIsBelowEyeLevel() {
    let t = TabletopInitialPlacement.transform
    expect(t.position.y < TabletopInitialPlacement.assumedViewerEyeHeight,
           "board sits below the viewer's eye level (looked down at)")
    expect(t.position.z < 0, "board is placed in front of the viewer (−Z)")
}

func testInitialPlacementIsObliqueNotFaceOn() {
    // A face-on/edge-on board would give a near-zero look-down pitch; an
    // oblique tabletop needs a clearly positive downward angle.
    let pitch = TabletopInitialPlacement.viewerLookDownPitch
    expect(pitch > 0.5, "viewer looks down at the board at an oblique angle (pitch \(pitch) rad)")
    // Not straight down either (that would hide relief); comfortably < 90°.
    expect(pitch < 1.4, "board is not viewed straight down")
}

// MARK: - Run all tests

@main
struct TabletopLayersTests {
    static func main() {
        testElevationOrderingStrictlyIncreasing()
        testTerrainAndFogNotCoplanar()
        testSubstrateBelowTerrain()

        testTerrainReliefOrdering()
        testTerrainReliefHasVisibleSpread()
        testMixedTransitionTilesPreserveMapPlane()
        testForestStandsUp()
        testTreeStrideOneWhenUnderCap()
        testTreeStrideBoundsCount()
        testTreePlacementIsRegularSubgrid()
        testTreeCardStandsUpright()
        testFogFollowsAboveEveryTerrainHeight()

        testTerrainExtent()
        testSubstrateExtentAddsFrameBorder()

        testSubstrateMeshIsSolidBox()
        testSubstrateMeshSpansThickness()
        testSubstrateMeshHasUpwardAndDownwardFaces()
        testSubstrateMeshCentered()

        testReadinessNotStableUntilAllChunks()
        testReadinessFraction()

        testAtlasCompletionGate()
        testInitialPlacementIsBelowEyeLevel()
        testInitialPlacementIsObliqueNotFaceOn()

        print("[\(failedChecks == 0 ? "PASS" : "FAIL")] "
            + "\(totalChecks - failedChecks)/\(totalChecks) checks passed "
            + "(tabletop board layers)")
        if failedChecks > 0 {
            exit(1)
        }
    }
}
