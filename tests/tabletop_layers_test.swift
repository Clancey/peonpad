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

func testForestStandsUp() {
    // Forest tiles get an upright standing prop; other classes do not.
    expect(TabletopTerrainRelief.standupHeight(.forest) > 0.02,
           "forest has a visible standing (tree) prop")
    for kind in TabletopTerrainKind.allCases where kind != .forest {
        expectEq(TabletopTerrainRelief.standupHeight(kind), 0, "\(kind) has no standing prop")
    }
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
        testForestStandsUp()
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
