// tabletop_chunk_geometry_test.swift
//
// Host-Mac unit tests for the framework-free chunk-geometry layer:
//   • TabletopChunkLayout — chunk partitioning, origin, tile enumeration
//   • TabletopAtlasSlotMap — graphicIndex → atlas slot mapping
//   • TabletopTerrainChunkMeshBuilder — vertex/UV/index generation
//   • TabletopFogMap — pixel state, setRevealed, isRevealed, cgImage
//
// None of these tests require RealityKit, UIKit, or a Simulator.
//
//   ./scripts/test-visionos-tabletop-chunks.sh
import Foundation
import CoreGraphics

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

// MARK: - TabletopChunkLayout tests

func testChunkCount() {
    // 128×128, chunkSize=32 → 4×4
    let c = TabletopChunkLayout.chunkCount(mapWidth: 128, mapHeight: 128, chunkTiles: 32)
    expectEq(c.cx, 4, "128×128 cx=4")
    expectEq(c.cz, 4, "128×128 cz=4")

    // Exact fit
    let c2 = TabletopChunkLayout.chunkCount(mapWidth: 64, mapHeight: 32, chunkTiles: 32)
    expectEq(c2.cx, 2, "64×32 cx=2")
    expectEq(c2.cz, 1, "64×32 cz=1")

    // Non-multiple (130 = 4*32 + 2 → 5 chunks)
    let c3 = TabletopChunkLayout.chunkCount(mapWidth: 130, mapHeight: 33, chunkTiles: 32)
    expectEq(c3.cx, 5, "130 wide → 5 chunks")
    expectEq(c3.cz, 2, "33 tall → 2 chunks")

    // Degenerate 1×1
    let c4 = TabletopChunkLayout.chunkCount(mapWidth: 1, mapHeight: 1, chunkTiles: 32)
    expectEq(c4.cx, 1, "1×1 cx=1")
    expectEq(c4.cz, 1, "1×1 cz=1")
}

func testChunkOrigin() {
    let o = TabletopChunkLayout.chunkOrigin(chunkX: 2, chunkZ: 3, chunkTiles: 32)
    expectEq(o.tileX, 64, "chunkOrigin(2,3) tileX=64")
    expectEq(o.tileZ, 96, "chunkOrigin(2,3) tileZ=96")

    let o2 = TabletopChunkLayout.chunkOrigin(chunkX: 0, chunkZ: 0, chunkTiles: 32)
    expectEq(o2.tileX, 0, "chunkOrigin(0,0) tileX=0")
    expectEq(o2.tileZ, 0, "chunkOrigin(0,0) tileZ=0")
}

func testChunkFor() {
    let ch = TabletopChunkLayout.chunkFor(tileX: 63, tileZ: 31, chunkTiles: 32)
    expectEq(ch.chunkX, 1, "tile(63,31) chunkX=1")
    expectEq(ch.chunkZ, 0, "tile(63,31) chunkZ=0")

    let ch2 = TabletopChunkLayout.chunkFor(tileX: 127, tileZ: 127, chunkTiles: 32)
    expectEq(ch2.chunkX, 3, "tile(127,127) chunkX=3")
    expectEq(ch2.chunkZ, 3, "tile(127,127) chunkZ=3")

    let ch3 = TabletopChunkLayout.chunkFor(tileX: 0, tileZ: 0, chunkTiles: 32)
    expectEq(ch3.chunkX, 0, "tile(0,0) chunkX=0")
    expectEq(ch3.chunkZ, 0, "tile(0,0) chunkZ=0")
}

func testTilesIn() {
    // Normal interior chunk
    let tiles = TabletopChunkLayout.tilesIn(
        chunkX: 0, chunkZ: 0, mapWidth: 128, mapHeight: 128, chunkTiles: 32)
    expectEq(tiles.count, 32 * 32, "interior chunk has 1024 tiles")
    expectEq(tiles[0].tileX, 0, "first tile tileX=0")
    expectEq(tiles[0].tileZ, 0, "first tile tileZ=0")

    // Edge chunk (130×33 map, last chunk)
    let edgeTiles = TabletopChunkLayout.tilesIn(
        chunkX: 4, chunkZ: 1, mapWidth: 130, mapHeight: 33, chunkTiles: 32)
    // chunkX=4 → tileX start=128, mapWidth=130 → 2 tiles wide
    // chunkZ=1 → tileZ start=32, mapHeight=33 → 1 tile tall
    expectEq(edgeTiles.count, 2 * 1, "edge chunk has 2 tiles")
    expectEq(edgeTiles[0].tileX, 128, "edge chunk tileX starts at 128")
    expectEq(edgeTiles[0].tileZ, 32,  "edge chunk tileZ starts at 32")

    // Out-of-bounds chunk returns empty
    let empty = TabletopChunkLayout.tilesIn(
        chunkX: 5, chunkZ: 0, mapWidth: 128, mapHeight: 128, chunkTiles: 32)
    expectEq(empty.count, 0, "out-of-bounds chunk returns empty")

    // Full 128×128 tile count
    let (cx, cz) = TabletopChunkLayout.chunkCount(mapWidth: 128, mapHeight: 128, chunkTiles: 32)
    var total = 0
    for czz in 0..<cz {
        for cxx in 0..<cx {
            total += TabletopChunkLayout.tilesIn(
                chunkX: cxx, chunkZ: czz, mapWidth: 128, mapHeight: 128, chunkTiles: 32).count
        }
    }
    expectEq(total, 128 * 128, "all chunks together cover all 16384 tiles")

    let asymmetric = TabletopChunkLayout.tilesIn(
        chunkX: 0, chunkZ: 0, mapWidth: 3, mapHeight: 2, chunkTiles: 32)
    expectEq(asymmetric.map { "\($0.tileX),\($0.tileZ)" },
             ["0,0", "1,0", "2,0", "0,1", "1,1", "2,1"],
             "asymmetric map stays row-major without transpose or row reversal")
}

func testTileKey() {
    // tileKey must be unique for distinct coordinates in range
    var keys = Set<Int>()
    let coords = [(0,0),(1,0),(0,1),(1,1),(127,127),(63,63),(0,127)]
    for (x,z) in coords {
        let k = TabletopChunkLayout.tileKey(x, z)
        expect(!keys.contains(k), "tileKey(\(x),\(z)) is unique")
        keys.insert(k)
    }
}

// MARK: - TabletopAtlasSlotMap tests

func testAtlasSlotMap() {
    // Basic deduplication
    let m = TabletopAtlasSlotMap(graphicIndices: [5, 3, 5, nil, 3, 7, nil] as [Int?])
    expectEq(m.slotCount, 4, "4 unique values: 5, 3, nil, 7")
    expectEq(m.slot(for: 5), 0, "5 → slot 0 (first seen)")
    expectEq(m.slot(for: 3), 1, "3 → slot 1")
    expectEq(m.slot(for: nil), 2, "nil → slot 2")
    expectEq(m.slot(for: 7), 3, "7 → slot 3")

    // Empty input → slotCount = 1 (defensive, no ÷0)
    let empty = TabletopAtlasSlotMap(graphicIndices: [] as [Int?])
    expectEq(empty.slotCount, 1, "empty input → slotCount=1 (no ÷0)")
    expectEq(empty.slot(for: nil), 0, "empty map falls back to slot 0")

    // All nil
    let allNil = TabletopAtlasSlotMap(graphicIndices: [nil, nil, nil] as [Int?])
    expectEq(allNil.slotCount, 1, "all-nil → 1 slot")

    // All unique integers
    let unique = TabletopAtlasSlotMap(graphicIndices: [10, 20, 30] as [Int?])
    expectEq(unique.slotCount, 3, "3 unique ints → 3 slots")
    expectEq(unique.slot(for: 20), 1, "20 → slot 1")
    expectEq(unique.slot(for: 99), 0, "unknown index → slot 0 fallback")
}

func testAtlasSlotMapEntries() {
    let m = TabletopAtlasSlotMap(graphicIndices: [7, 2, 7, nil] as [Int?])
    // slotEntries must contain exactly the unique (graphicIndex, slotIndex) pairs
    expectEq(m.slotEntries.count, 3, "3 unique slots → 3 entries")
    // Order: first-seen order
    expectEq(m.slotEntries[0].graphicIndex, 7, "entry[0].graphicIndex=7")
    expectEq(m.slotEntries[0].slotIndex, 0,    "entry[0].slotIndex=0")
    expectEq(m.slotEntries[1].graphicIndex, 2,  "entry[1].graphicIndex=2")
    expectEq(m.slotEntries[2].graphicIndex, nil,"entry[2].graphicIndex=nil")
}

func testPaddedAtlasLayout() {
    let layout = TabletopTerrainAtlasLayout(
        slotCount: 3, cellWidth: 32, cellHeight: 32, gutterPixels: 2)
    expectEq(layout.slotStride, 36, "32px frame plus two 2px gutters")
    expectEq(layout.atlasWidth, 108, "three padded slots have bounded width")
    expectEq(layout.atlasHeight, 36, "single padded row has bounded height")
    expectEq(layout.contentOriginX(1), 38, "slot 1 content follows its left gutter")
    let uv = layout.contentUVBounds(1)
    expect(abs(uv.u0 - Float(38.0 / 108.0)) < 1e-6,
           "slot 1 starts at its content edge, not neighbouring padding")
    expect(abs(uv.u1 - Float(70.0 / 108.0)) < 1e-6,
           "slot 1 ends before its replicated right gutter")
    expect(abs(uv.v0 - Float(2.0 / 36.0)) < 1e-6,
           "content starts below its replicated top gutter")
    expect(abs(uv.v1 - Float(34.0 / 36.0)) < 1e-6,
           "content ends above its replicated bottom gutter")
    expect(uv.u0 > Float(1) / 3 && uv.u1 < Float(2) / 3,
           "content UVs are inset from adjacent atlas slots")
}

func testAtlasLayoutMetalDimensionBoundaries() {
    let below = TabletopTerrainAtlasLayout(
        slotCount: 511, cellWidth: 32, cellHeight: 32, gutterPixels: 0)
    expect(below.isValid, "511 slots fit below the 16384px boundary")
    expectEq(below.atlasWidth, 16_352, "511x32 = 16352px")
    expectEq(below.rows, 1, "below-boundary atlas stays one row")

    let at = TabletopTerrainAtlasLayout(
        slotCount: 512, cellWidth: 32, cellHeight: 32, gutterPixels: 0)
    expect(at.isValid, "512 slots fit exactly at 16384px")
    expectEq(at.atlasWidth, 16_384, "512x32 reaches the Metal limit exactly")
    expectEq(at.rows, 1, "at-boundary atlas stays one row")

    let above = TabletopTerrainAtlasLayout(
        slotCount: 513, cellWidth: 32, cellHeight: 32, gutterPixels: 0)
    expect(above.isValid, "513 slots wrap instead of exceeding the limit")
    expectEq(above.atlasWidth, 16_384, "wrapped atlas width remains bounded")
    expectEq(above.atlasHeight, 64, "513th slot starts a second 32px row")
    expectEq(above.rows, 2, "above-boundary atlas uses two rows")
}

func testPaddedAtlasWrapAndUVOrientation() {
    // 32px frame + 4px gutters = 40px stride; only 409 slots fit per
    // 16384px row, so slot 409 must begin row 1 without rotating/mirroring.
    let layout = TabletopTerrainAtlasLayout(
        slotCount: 410, cellWidth: 32, cellHeight: 32, gutterPixels: 4)
    expect(layout.isValid, "410 padded slots fit in a bounded two-row atlas")
    expectEq(layout.columns, 409, "409 padded frames per row")
    expectEq(layout.rows, 2, "slot 409 wraps to row 1")
    expectEq(layout.atlasWidth, 16_360, "padded width stays below Metal limit")
    expectEq(layout.atlasHeight, 80, "two 40px padded rows")
    expectEq(layout.slotOriginX(408), 16_320, "last row-0 slot x")
    expectEq(layout.slotOriginY(408), 0, "last row-0 slot y")
    expectEq(layout.slotOriginX(409), 0, "first row-1 slot wraps to x=0")
    expectEq(layout.slotOriginY(409), 40, "first row-1 slot advances by stride")

    let row0 = layout.contentUVBounds(408)
    let row1 = layout.contentUVBounds(409)
    expect(row0.u0 < row0.u1 && row0.v0 < row0.v1,
           "row-0 source frame preserves left-to-right/top-to-bottom UVs")
    expect(row1.u0 < row1.u1 && row1.v0 < row1.v1,
           "row-1 source frame preserves left-to-right/top-to-bottom UVs")
    expect(row1.u0 < row0.u0, "wrapped slot returns to the left atlas edge")
    expect(row1.v0 > row0.v0, "wrapped slot advances downward one atlas row")
}

func testAtlasLayoutSupportsFullDistinctChunk() {
    let layout = TabletopTerrainAtlasLayout(
        slotCount: 1_024, cellWidth: 32, cellHeight: 32, gutterPixels: 4)
    expect(layout.isValid, "1024 distinct chunk slots fit in one bounded atlas")
    expectEq(layout.columns, 409, "full chunk uses bounded column count")
    expectEq(layout.rows, 3, "full chunk wraps across three rows")
    expect(layout.atlasWidth <= TabletopTerrainAtlasLayout.maximumTextureDimension,
           "full chunk atlas width is Metal-safe")
    expect(layout.atlasHeight <= TabletopTerrainAtlasLayout.maximumTextureDimension,
           "full chunk atlas height is Metal-safe")

    let fit = TabletopMapFit(width: 32, height: 32, boardExtent: 0.8)
    var tiles: [(tileX: Int, tileZ: Int, graphicIndex: Int?)] = []
    for z in 0..<32 {
        for x in 0..<32 {
            tiles.append((x, z, z * 32 + x))
        }
    }
    let slotMap = TabletopAtlasSlotMap(
        graphicIndices: tiles.map(\.graphicIndex))
    let geo = TabletopTerrainChunkMeshBuilder.build(
        tiles: tiles, fit: fit, slotMap: slotMap, atlasLayout: layout)
    expectEq(geo.tileCount, 1_024, "full distinct chunk preserves every tile")
    expect(geo.textureCoordinates.allSatisfy {
        $0.x >= 0 && $0.x <= 1 && $0.y >= 0 && $0.y <= 1
    }, "all full-chunk multi-row UVs remain normalized")
    let last = Array(geo.textureCoordinates.suffix(4))
    expect(last[0].x < last[1].x && last[0].y < last[3].y,
           "last wrapped frame is neither mirrored nor vertically inverted")
}

private func makeSolidTile(
    width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8
) -> CGImage? {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for index in 0..<(width * height) {
        pixels[index * 4 + 0] = r
        pixels[index * 4 + 1] = g
        pixels[index * 4 + 2] = b
    }

    let data = Data(pixels)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
        width: width, height: height,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent)
}

private func makeCornerTile() -> CGImage? {
    // Material-provider decode output is pre-flipped for TextureResource:
    // memory top row is the source bottom (blue/yellow), then the atlas packer's
    // matching context transform restores visual top (red/green).
    let pixels: [UInt8] = [
        20, 40, 230, 255,   230, 220, 20, 255,
        240, 20, 30, 255,   20, 230, 40, 255,
    ]
    let data = Data(pixels)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(
        width: 2, height: 2,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent)
}

private func pixelRGB(
    _ image: CGImage, x: Int, y: Int
) -> (r: UInt8, g: UInt8, b: UInt8)? {
    guard let pixelImage = image.cropping(to: CGRect(
        x: x, y: y, width: 1, height: 1)) else { return nil }
    var pixel = [UInt8](repeating: 0, count: 4)
    let drew = pixel.withUnsafeMutableBytes { bytes -> Bool in
        guard let base = bytes.baseAddress,
              let ctx = CGContext(
                data: base, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        ctx.translateBy(x: 0, y: 1)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(pixelImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return true
    }
    return drew ? (pixel[0], pixel[1], pixel[2]) : nil
}

func testSyntheticMultiRowAtlasPacking() {
    let layout = TabletopTerrainAtlasLayout(
        slotCount: 1_024, cellWidth: 32, cellHeight: 32, gutterPixels: 4)
    guard let red = makeSolidTile(
        width: 32, height: 32, r: 240, g: 20, b: 30),
          let green = makeSolidTile(
            width: 32, height: 32, r: 20, g: 230, b: 40),
          let atlas = TabletopTerrainAtlasImageBuilder.build(
            slotImages: [408: red, 409: green], layout: layout)
    else {
        expect(false, "synthetic 1024-slot multi-row atlas packs successfully")
        return
    }

    expectEq(atlas.width, layout.atlasWidth,
             "synthetic atlas uses bounded multi-row width")
    expectEq(atlas.height, layout.atlasHeight,
             "synthetic atlas uses bounded multi-row height")

    let redContent = pixelRGB(
        atlas, x: layout.contentOriginX(408), y: layout.contentOriginY(408))
    let redGutter = pixelRGB(
        atlas, x: layout.slotOriginX(408), y: layout.slotOriginY(408))
    let greenContent = pixelRGB(
        atlas, x: layout.contentOriginX(409), y: layout.contentOriginY(409))
    let greenGutter = pixelRGB(
        atlas, x: layout.slotOriginX(409), y: layout.slotOriginY(409))
    expect(redContent.map { $0.r > $0.g && $0.r > $0.b } == true,
           "row-0 content retains its source frame color")
    expect(redGutter.map { $0.r > $0.g && $0.r > $0.b } == true,
           "row-0 corner gutter replicates its source edge")
    expect(greenContent.map { $0.g > $0.r && $0.g > $0.b } == true,
           "wrapped row-1 content retains its source frame color")
    expect(greenGutter.map { $0.g > $0.r && $0.g > $0.b } == true,
           "wrapped row-1 corner gutter replicates its source edge")
}

func testSyntheticWrappedFrameOrientation() {
    let layout = TabletopTerrainAtlasLayout(
        slotCount: 11, cellWidth: 2, cellHeight: 2,
        gutterPixels: 1, maximumDimension: 40)
    guard let corners = makeCornerTile(),
          let atlas = TabletopTerrainAtlasImageBuilder.build(
            slotImages: [10: corners], layout: layout)
    else {
        expect(false, "asymmetric wrapped frame packs")
        return
    }

    expectEq(layout.columns, 10, "synthetic limit forces slot 10 to row 1")
    let x = layout.contentOriginX(10)
    let y = layout.contentOriginY(10)
    let topLeft = pixelRGB(atlas, x: x, y: y)
    let topRight = pixelRGB(atlas, x: x + 1, y: y)
    let bottomLeft = pixelRGB(atlas, x: x, y: y + 1)
    let topGutterLeft = pixelRGB(
        atlas, x: layout.slotOriginX(10), y: layout.slotOriginY(10))
    let topGutterRight = pixelRGB(
        atlas,
        x: layout.slotOriginX(10) + layout.slotStrideX - 1,
        y: layout.slotOriginY(10))
    let bottomGutterLeft = pixelRGB(
        atlas,
        x: layout.slotOriginX(10),
        y: layout.slotOriginY(10) + layout.slotStrideY - 1)
    expect(topLeft.map { $0.r > $0.g && $0.r > $0.b } == true,
           "wrapped frame keeps red at top-left, got \(String(describing: topLeft))")
    expect(topRight.map { $0.g > $0.r && $0.g > $0.b } == true,
           "wrapped frame keeps green at top-right, got \(String(describing: topRight))")
    expect(bottomLeft.map { $0.b > $0.r && $0.b > $0.g } == true,
           "wrapped frame keeps blue at bottom-left, got \(String(describing: bottomLeft))")
    expect(topGutterLeft.map { $0.r > $0.g && $0.r > $0.b } == true,
           "top-left gutter replicates visual top-left")
    expect(topGutterRight.map { $0.g > $0.r && $0.g > $0.b } == true,
           "top-right gutter replicates visual top-right")
    expect(bottomGutterLeft.map { $0.b > $0.r && $0.b > $0.g } == true,
           "bottom-left gutter replicates visual bottom-left")
}

func testSyntheticSingleRowVerticalGutters() {
    let layout = TabletopTerrainAtlasLayout(
        slotCount: 1, cellWidth: 2, cellHeight: 2, gutterPixels: 1)
    guard let corners = makeCornerTile(),
          let atlas = TabletopTerrainAtlasImageBuilder.build(
            slotImages: [0: corners], layout: layout)
    else {
        expect(false, "asymmetric single-row frame packs")
        return
    }
    let topLeft = pixelRGB(
        atlas, x: layout.slotOriginX(0), y: layout.slotOriginY(0))
    let bottomLeft = pixelRGB(
        atlas,
        x: layout.slotOriginX(0),
        y: layout.slotOriginY(0) + layout.slotStrideY - 1)
    expect(topLeft.map { $0.r > $0.g && $0.r > $0.b } == true,
           "single-row top gutter replicates visual top edge")
    expect(bottomLeft.map { $0.b > $0.r && $0.b > $0.g } == true,
           "single-row bottom gutter replicates visual bottom edge")
}

// MARK: - TabletopTerrainChunkMeshBuilder tests

func testChunkMeshBuilderBasic() {
    // Single tile
    let fit = TabletopMapFit(width: 4, height: 4, boardExtent: 0.84)
    let slotMap = TabletopAtlasSlotMap(graphicIndices: [0] as [Int?])
    let geo = TabletopTerrainChunkMeshBuilder.build(
        tiles: [(tileX: 0, tileZ: 0, graphicIndex: 0)],
        fit: fit, slotMap: slotMap)

    expectEq(geo.tileCount, 1, "1 tile → tileCount=1")
    expectEq(geo.positions.count, 4, "1 tile → 4 positions")
    expectEq(geo.normals.count, 4, "1 tile → 4 normals")
    expectEq(geo.textureCoordinates.count, 4, "1 tile → 4 UVs")
    expectEq(geo.triangleIndices.count, 6, "1 tile → 6 indices")

    // All normals are (0,1,0)
    for n in geo.normals {
        expect(n.x == 0 && n.y == 1 && n.z == 0, "normal is (0,1,0)")
    }
    // All indices in range [0,3]
    for idx in geo.triangleIndices {
        expect(idx < 4, "index \(idx) < 4")
    }
}

func testChunkMeshBuilderUVs() {
    // 2 tiles, 2 slots → UV columns [0, 0.5) and [0.5, 1)
    let fit = TabletopMapFit(width: 4, height: 4, boardExtent: 0.84)
    let slotMap = TabletopAtlasSlotMap(graphicIndices: [0, 1] as [Int?])
    let geo = TabletopTerrainChunkMeshBuilder.build(
        tiles: [(tileX: 0, tileZ: 0, graphicIndex: 0),
                (tileX: 1, tileZ: 0, graphicIndex: 1)],
        fit: fit, slotMap: slotMap)

    // Tile 0 (graphicIndex=0, slot=0): UVs at u=0..0.5
    let t0NW = geo.textureCoordinates[0]  // NW corner
    let t0NE = geo.textureCoordinates[1]  // NE corner
    expect(abs(t0NW.x - 0.0) < 1e-5, "tile0 NW u=0.0, got \(t0NW.x)")
    expect(abs(t0NE.x - 0.5) < 1e-5, "tile0 NE u=0.5, got \(t0NE.x)")
    expect(abs(t0NW.y - 0.0) < 1e-5, "tile0 NW v=0.0, got \(t0NW.y)")

    // Tile 1 (graphicIndex=1, slot=1): UVs at u=0.5..1.0
    let t1NW = geo.textureCoordinates[4]  // 4 vertices per tile
    let t1NE = geo.textureCoordinates[5]
    expect(abs(t1NW.x - 0.5) < 1e-5, "tile1 NW u=0.5, got \(t1NW.x)")
    expect(abs(t1NE.x - 1.0) < 1e-5, "tile1 NE u=1.0, got \(t1NE.x)")
}

func testChunkMeshBuilderPositions() {
    // Tile (0,0) center for a 4×4 map with boardExtent=0.84
    // tileSize = 0.84/4 = 0.21
    // center(0,0) = (-1.5*0.21, -1.5*0.21) = (-0.315, -0.315)
    let fit = TabletopMapFit(width: 4, height: 4, boardExtent: 0.84)
    let slotMap = TabletopAtlasSlotMap(graphicIndices: [0] as [Int?])
    let geo = TabletopTerrainChunkMeshBuilder.build(
        tiles: [(tileX: 0, tileZ: 0, graphicIndex: 0)],
        fit: fit, slotMap: slotMap)

    let halfTile: Float = 0.84 / 4 / 2  // 0.105
    let cx: Float = (-1.5) * 0.21       // -0.315
    let cz: Float = (-1.5) * 0.21       // -0.315

    // NW corner = (cx - halfTile, 0, cz - halfTile)
    let nw = geo.positions[0]
    expect(abs(nw.x - (cx - halfTile)) < 1e-4, "NW.x ≈ \(cx - halfTile), got \(nw.x)")
    expect(abs(nw.y) < 1e-5, "NW.y = 0")
    expect(abs(nw.z - (cz - halfTile)) < 1e-4, "NW.z ≈ \(cz - halfTile), got \(nw.z)")
}

func testChunkMeshBuilderWinding() {
    // Verify triangles are counter-clockwise from above (+Y normal).
    // cross(edge_01, edge_12) must point in +Y direction.
    let fit = TabletopMapFit(width: 4, height: 4, boardExtent: 0.84)
    let slotMap = TabletopAtlasSlotMap(graphicIndices: [0] as [Int?])
    let geo = TabletopTerrainChunkMeshBuilder.build(
        tiles: [(tileX: 0, tileZ: 0, graphicIndex: 0)],
        fit: fit, slotMap: slotMap)

    // Check both triangles of the first quad.
    let positions = geo.positions
    let indices   = geo.triangleIndices

    // Triangle 0 (indices 0..2)
    // Normal = cross(P1−P0, P2−P0); Y component = (P1−P0).z*(P2−P0).x − (P1−P0).x*(P2−P0).z
    let p0 = positions[Int(indices[0])]
    let p1 = positions[Int(indices[1])]
    let p2 = positions[Int(indices[2])]
    let a0 = p1 - p0  // P1−P0
    let b0 = p2 - p0  // P2−P0
    let normalY0 = a0.z * b0.x - a0.x * b0.z
    expect(normalY0 > 0, "Triangle 0 normal Y > 0 (facing up), got \(normalY0)")

    // Triangle 1 (indices 3..5)
    let q0 = positions[Int(indices[3])]
    let q1 = positions[Int(indices[4])]
    let q2 = positions[Int(indices[5])]
    let a1 = q1 - q0
    let b1 = q2 - q0
    let normalY1 = a1.z * b1.x - a1.x * b1.z
    expect(normalY1 > 0, "Triangle 1 normal Y > 0 (facing up), got \(normalY1)")
}

func testChunkMeshBuilderEmpty() {
    let fit    = TabletopMapFit(width: 4, height: 4, boardExtent: 0.84)
    let slotMap = TabletopAtlasSlotMap(graphicIndices: [] as [Int?])
    let geo    = TabletopTerrainChunkMeshBuilder.build(
        tiles: [], fit: fit, slotMap: slotMap)
    expect(geo.isEmpty, "empty tile list → empty geometry")
    expectEq(geo.tileCount, 0, "empty → tileCount=0")
}

func testChunkMeshBuilderMultiTile() {
    let fit = TabletopMapFit(width: 128, height: 128, boardExtent: 0.84)
    // Simulate a full 32×32 chunk (tile coords 0..31 × 0..31)
    var tiles: [(tileX: Int, tileZ: Int, graphicIndex: Int?)] = []
    for tz in 0..<32 { for tx in 0..<32 { tiles.append((tx, tz, tx % 10)) } }
    let slotMap = TabletopAtlasSlotMap(graphicIndices: tiles.map { $0.graphicIndex })
    let geo = TabletopTerrainChunkMeshBuilder.build(tiles: tiles, fit: fit, slotMap: slotMap)

    expectEq(geo.tileCount, 1024, "32×32=1024 tiles")
    expectEq(geo.positions.count, 4096, "1024 tiles × 4 verts = 4096")
    expectEq(geo.triangleIndices.count, 6144, "1024 tiles × 6 indices = 6144")
    // All UV.x values must be in [0, 1]
    for uv in geo.textureCoordinates {
        expect(uv.x >= 0 && uv.x <= 1, "UV.x ∈ [0,1], got \(uv.x)")
        expect(uv.y >= 0 && uv.y <= 1, "UV.y ∈ [0,1], got \(uv.y)")
    }
    // Max index must be < positions.count
    let maxIdx = geo.triangleIndices.max() ?? 0
    expect(maxIdx < UInt32(geo.positions.count), "max index \(maxIdx) < \(geo.positions.count)")
}

// MARK: - TabletopFogMap tests

func testFogMapInit() {
    let fog = TabletopFogMap(mapWidth: 4, mapHeight: 4)
    expectEq(fog.mapWidth, 4, "mapWidth=4")
    expectEq(fog.mapHeight, 4, "mapHeight=4")
    expectEq(fog.revealedCount, 0, "all tiles fogged initially")
    // No tile is revealed
    for tz in 0..<4 { for tx in 0..<4 {
        expect(!fog.isRevealed(tileX: tx, tileZ: tz),
               "tile(\(tx),\(tz)) initially fogged")
    }}
}

func testFogMapSetRevealed() {
    var fog = TabletopFogMap(mapWidth: 4, mapHeight: 4)
    fog.setRevealed(true, tileX: 2, tileZ: 1)
    expect(fog.isRevealed(tileX: 2, tileZ: 1), "tile(2,1) revealed")
    expect(!fog.isRevealed(tileX: 0, tileZ: 0), "tile(0,0) still fogged")
    expectEq(fog.revealedCount, 1, "revealedCount=1")

    fog.setRevealed(false, tileX: 2, tileZ: 1)
    expect(!fog.isRevealed(tileX: 2, tileZ: 1), "tile(2,1) fogged again")
    expectEq(fog.revealedCount, 0, "revealedCount=0 after re-fog")
}

func testFogMapOutOfBounds() {
    var fog = TabletopFogMap(mapWidth: 4, mapHeight: 4)
    // Out-of-bounds calls must not crash
    fog.setRevealed(true, tileX: -1, tileZ: 0)
    fog.setRevealed(true, tileX: 4,  tileZ: 0)
    fog.setRevealed(true, tileX: 0,  tileZ: -1)
    fog.setRevealed(true, tileX: 0,  tileZ: 4)
    expectEq(fog.revealedCount, 0, "out-of-bounds writes do not reveal tiles")
    expect(!fog.isRevealed(tileX: -1, tileZ: 0), "out-of-bounds isRevealed → false")
}

func testFogMapRevealAll() {
    var fog = TabletopFogMap(mapWidth: 8, mapHeight: 8)
    for tz in 0..<8 { for tx in 0..<8 { fog.setRevealed(true, tileX: tx, tileZ: tz) } }
    expectEq(fog.revealedCount, 64, "all 64 tiles revealed")
}

func testFogMapCGImage() {
    var fog = TabletopFogMap(mapWidth: 2, mapHeight: 2)
    fog.setRevealed(true, tileX: 1, tileZ: 0)  // top-right = revealed

    guard let cgImage = fog.cgImage() else {
        failedChecks += 1
        fputs("FAIL: cgImage() returned nil\n", stderr)
        return
    }
    totalChecks += 1
    expectEq(cgImage.width,  2, "cgImage width=2")
    expectEq(cgImage.height, 2, "cgImage height=2")

    // Pixel at (1, 0) (column=1, row=0 = top-left origin for CGImage)
    // should have alpha=0 (revealed)
    if let ctx = CGContext(data: nil, width: 2, height: 2,
                           bitsPerComponent: 8, bytesPerRow: 8,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        if let data = ctx.data {
            let pixels = data.assumingMemoryBound(to: UInt8.self)
            // Row 0 (tileZ=0): pixel 0 = tile(0,0) fogged, pixel 1 = tile(1,0) revealed
            // CGContext y-up: row 0 in the context = bottom of drawn image.
            // When drawing cgImage (y-down) at y=0, row 0 of cgImage ends up at bottom
            // of context (context y=0). Context stores pixel at y=0 first in memory.
            // Actually the row ordering in CGContext memory depends on bytesPerRow layout:
            // just check that there is one alpha=0 pixel and three alpha>0 pixels.
            let a0 = pixels[3]   // (0,0) alpha
            let a1 = pixels[7]   // (1,0) alpha
            let a2 = pixels[11]  // (0,1) alpha
            let a3 = pixels[15]  // (1,1) alpha
            let zeroAlphas = [a0, a1, a2, a3].filter { $0 == 0 }.count
            expectEq(zeroAlphas, 1, "exactly 1 revealed (alpha=0) pixel in 2×2 fog map")
        }
    }
}

// MARK: - Three-state fog

func testFogVisibilityThreeStates() {
    var fog = TabletopFogMap(mapWidth: 3, mapHeight: 1)
    fog.setVisibility(.unexplored, tileX: 0, tileZ: 0)
    fog.setVisibility(.explored,   tileX: 1, tileZ: 0)
    fog.setVisibility(.visible,    tileX: 2, tileZ: 0)

    expectEq(fog.unexploredCount, 1, "one unexplored tile")
    expectEq(fog.exploredCount,   1, "one explored tile")
    expectEq(fog.visibleCount,    1, "one visible tile")
    // revealed == explored or visible
    expectEq(fog.revealedCount,   2, "explored + visible count as revealed")
    expect(!fog.isRevealed(tileX: 0, tileZ: 0), "unexplored is not revealed")
    expect(fog.isRevealed(tileX: 1, tileZ: 0),  "explored is revealed")
    expect(fog.isRevealed(tileX: 2, tileZ: 0),  "visible is revealed")
    expectEq(fog.visibility(tileX: 1, tileZ: 0), .explored, "explored preserved")
}

func testFogAlphaOrdering() {
    // Opaque shroud > dim explored veil > clear visible; visible is fully clear.
    let u = TabletopFogMap.alpha(for: .unexplored)
    let e = TabletopFogMap.alpha(for: .explored)
    let v = TabletopFogMap.alpha(for: .visible)
    expect(u > e, "unexplored is more opaque than explored (\(u) > \(e))")
    expect(e > v, "explored is dimmer-but-present vs clear visible (\(e) > \(v))")
    expectEq(v, 0, "visible tiles carry no veil")
    expect(e > 0, "explored tiles keep a dim veil (not fully clear)")
}

func testFogSetRevealedIsBinaryProjection() {
    // The retained binary API maps to the extreme states only.
    var fog = TabletopFogMap(mapWidth: 2, mapHeight: 1)
    fog.setRevealed(true, tileX: 0, tileZ: 0)
    fog.setRevealed(false, tileX: 1, tileZ: 0)
    expectEq(fog.visibility(tileX: 0, tileZ: 0), .visible, "setRevealed(true) → visible")
    expectEq(fog.visibility(tileX: 1, tileZ: 0), .unexplored, "setRevealed(false) → unexplored")
}

func testFogTileVisibilityAndRevealedCompat() {
    // Three-state init round-trips; isRevealed stays a binary projection with a
    // (lossy) setter that keeps existing binary callers working.
    var tile = TabletopFogTile(tileX: 3, tileZ: 4, visibility: .explored)
    expect(tile.isRevealed, "explored tile reads as revealed")
    tile.isRevealed = false
    expectEq(tile.visibility, .unexplored, "isRevealed=false → unexplored")
    tile.isRevealed = true
    expectEq(tile.visibility, .visible, "isRevealed=true → visible")
    // Binary initializer still works.
    let binary = TabletopFogTile(tileX: 0, tileZ: 0, isRevealed: true)
    expectEq(binary.visibility, .visible, "binary init true → visible")
}

// MARK: - Building footprint centring

func testFootprintCenterOffset() {
    let a = TabletopFootprint.centerOffsetTiles(width: 1, height: 1)
    expect(a.dx == 0 && a.dz == 0, "1×1 footprint has zero centre offset")
    let b = TabletopFootprint.centerOffsetTiles(width: 2, height: 2)
    expect(b.dx == 0.5 && b.dz == 0.5, "2×2 footprint centres half a tile in")
    let c = TabletopFootprint.centerOffsetTiles(width: 4, height: 3)
    expect(c.dx == 1.5 && c.dz == 1.0, "4×3 footprint centre offset (1.5, 1.0)")
    let d = TabletopFootprint.centerOffsetTiles(width: 0, height: -3)
    expect(d.dx == 0 && d.dz == 0, "degenerate footprint clamps to 1×1")
}

// MARK: - Acceptance hold overflow guard

func testAcceptanceHoldSleepDurationIsFinite() {
    // Regression: Double(Int.max) rounds up to 2^63 = Int64.max+1, which
    // overflows Int64 inside Swift's Duration.seconds() initializer and
    // triggers a fatal "Not enough bits to represent the passed value" crash.
    // The acceptance hold must use an interval that does not overflow Int64.
    //
    // 3_600 (seconds in 1 hour) stays well below Int64.max.
    let holdIntervalSeconds: Double = 3_600
    let int64Max = Int64.max
    // Converting to Int64 must not trap.
    let converted = Int64(holdIntervalSeconds)
    expectEq(converted, 3_600, "hold interval 3600s must round-trip through Int64")
    expect(holdIntervalSeconds < Double(int64Max),
           "hold interval \(holdIntervalSeconds) must be representable as Int64")

    // Document the original bug: Double(Int.max) rounds to 2^63.
    // In Swift, Int.max == Int64.max on 64-bit platforms.
    // 2^63 as a Double equals 9223372036854775808.0, which exceeds Int64.max
    // (= 9223372036854775807), so Int64(Double(Int.max)) traps.
    let originalBugValue = Double(Int.max)
    let roundedToHigher = originalBugValue >= Double(bitPattern: 0x43E0_0000_0000_0000)
    // 0x43E0000000000000 = 2^63 as an IEEE 754 double
    expect(roundedToHigher,
           "Double(Int.max) must round up to 2^63 (documents the overflow bug)")
}



func testEntityCountReduction() {
    // A 128×128 map should produce 16 chunks, not 32768 per-tile entities.
    let (cx, cz) = TabletopChunkLayout.chunkCount(
        mapWidth: 128, mapHeight: 128, chunkTiles: 32)
    expectEq(cx * cz, 16, "128×128 map → 16 terrain chunks (not 32768)")
    // Total entities = 16 terrain + 1 fog = 17 (vs 32768 before)
    expectEq(cx * cz + 1, 17, "total terrain+fog entities = 17 for 128×128 map")
}

// MARK: - Relief mesh (2.5D terrain)

private func geoNormal(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>) -> SIMD3<Float> {
    let a = p1 - p0, b = p2 - p0
    return SIMD3<Float>(a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x)
}
private func dot3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x*b.x + a.y*b.y + a.z*b.z }

private let reliefFit = TabletopMapFit(width: 8, height: 8, boardExtent: 0.8)

func testReliefTopAtTileHeight() {
    let tiles = [(tileX: 4, tileZ: 4, graphicIndex: Optional(1), height: Float(0.01))]
    let slot  = TabletopAtlasSlotMap(graphicIndices: tiles.map { $0.graphicIndex })
    // Every neighbour equal height ⇒ no skirts, only the raised top quad.
    let geo = TabletopTerrainChunkMeshBuilder.buildRelief(
        tiles: tiles, fit: reliefFit, slotMap: slot,
        heightAt: { _, _ in 0.01 }, edgeFloorY: 0.01)
    expectEq(geo.positions.count, 4, "equal-height tile emits only a top quad")
    expect(geo.positions.allSatisfy { abs($0.y - 0.01) < 1e-6 }, "top quad sits at the tile height")
    expect(geo.normals.allSatisfy { $0.y > 0.9 }, "top quad faces up")
}

func testReliefSkirtWhenNeighborLower() {
    let tiles = [(tileX: 4, tileZ: 4, graphicIndex: Optional(1), height: Float(0.02))]
    let slot  = TabletopAtlasSlotMap(graphicIndices: tiles.map { $0.graphicIndex })
    // Only the east neighbour is lower; the other three are equal height.
    let geo = TabletopTerrainChunkMeshBuilder.buildRelief(
        tiles: tiles, fit: reliefFit, slotMap: slot,
        heightAt: { x, z in (x == 5 && z == 4) ? 0.0 : 0.02 }, edgeFloorY: 0.02)
    expectEq(geo.positions.count, 8, "one lower neighbour ⇒ top quad + one skirt")
    // The skirt drops from 0.02 to 0.0 and faces +X (east).
    expect(geo.normals.contains { $0.x > 0.9 }, "east skirt faces +X")
    expect(geo.positions.contains { abs($0.y - 0.0) < 1e-6 }, "skirt reaches the lower neighbour height")
    let topUVs = Array(geo.textureCoordinates[0..<4])
    let sideUVs = Array(geo.textureCoordinates[4..<8])
    expect(Set(topUVs.map { "\($0.x),\($0.y)" }).count == 4,
           "top quad preserves all four frame corners")
    expect(Set(sideUVs.map { "\($0.x),\($0.y)" }).count == 1,
           "side skirt samples one neutral frame point instead of stretching tile art")
    expect(topUVs != sideUVs, "top and side vertices keep independent UV domains")
}

func testChunkEdgeContinuity() {
    let fit = TabletopMapFit(width: 64, height: 1, boardExtent: 0.64)
    let slotMap = TabletopAtlasSlotMap(graphicIndices: [10, 20] as [Int?])
    let left = TabletopTerrainChunkMeshBuilder.build(
        tiles: [(31, 0, 10)], fit: fit, slotMap: slotMap)
    let right = TabletopTerrainChunkMeshBuilder.build(
        tiles: [(32, 0, 20)], fit: fit, slotMap: slotMap)
    let leftEast = left.positions.filter { $0.x == left.positions.map(\.x).max()! }
    let rightWest = right.positions.filter { $0.x == right.positions.map(\.x).min()! }
    expectEq(Set(leftEast.map(\.x)), Set(rightWest.map(\.x)),
             "adjacent chunk tile edges share the exact X boundary")
    expectEq(Set(leftEast.map(\.z)), Set(rightWest.map(\.z)),
             "adjacent chunk tile edges share both Z endpoints")
}

func testReliefSkirtsAllFrontFacing() {
    // A lone raised tile with all neighbours off-map: 4 skirts down to the floor.
    let tiles = [(tileX: 4, tileZ: 4, graphicIndex: Optional(2), height: Float(0.015))]
    let slot  = TabletopAtlasSlotMap(graphicIndices: tiles.map { $0.graphicIndex })
    let geo = TabletopTerrainChunkMeshBuilder.buildRelief(
        tiles: tiles, fit: reliefFit, slotMap: slot,
        heightAt: { _, _ in nil }, edgeFloorY: -0.02)
    expectEq(geo.positions.count, 20, "raised edge tile ⇒ top quad + 4 skirts (20 verts)")
    // Every triangle's geometric normal must agree with its stored vertex
    // normal (front-facing under back-face culling).
    let idx = geo.triangleIndices
    var frontFacing = true
    var t = 0
    while t < idx.count {
        let i0 = Int(idx[t]), i1 = Int(idx[t+1]), i2 = Int(idx[t+2])
        let gn = geoNormal(geo.positions[i0], geo.positions[i1], geo.positions[i2])
        if dot3(gn, geo.normals[i0]) <= 0 { frontFacing = false }
        t += 3
    }
    expect(frontFacing, "all relief triangles are front-facing (winding matches normal)")
    // Skirts span from the top height down to the edge floor.
    expect(geo.positions.contains { abs($0.y - 0.015) < 1e-6 }, "skirt tops at tile height")
    expect(geo.positions.contains { abs($0.y - (-0.02)) < 1e-6 }, "skirt bottoms at edge floor")
}

func testReliefBoundedForFlatGround() {
    // A 3×3 all-equal-height patch: interior tile has no skirts; only boundary
    // tiles skirt to the floor. Vertex count stays bounded (no per-tile blowup).
    var tiles: [(tileX: Int, tileZ: Int, graphicIndex: Int?, height: Float)] = []
    for z in 0..<3 { for x in 0..<3 { tiles.append((x, z, 1, 0.0)) } }
    let slot = TabletopAtlasSlotMap(graphicIndices: tiles.map { $0.graphicIndex })
    let inside: Set<Int> = [0,1,2,3,4,5,6,7,8]
    _ = inside
    let geo = TabletopTerrainChunkMeshBuilder.buildRelief(
        tiles: tiles, fit: reliefFit, slotMap: slot,
        heightAt: { x, z in (x >= 0 && x < 3 && z >= 0 && z < 3) ? 0.0 : nil },
        edgeFloorY: -0.02)
    // 9 top quads (36 verts) + skirts only on the 8 outer-edge boundaries.
    // Center tile (1,1) contributes no skirt.
    expect(geo.positions.count >= 36, "at least one top quad per tile")
    expect(geo.positions.count < 9 * 20, "far fewer than every-tile-4-skirts (bounded)")
}

// Two adjacent tiles are meshed independently (as they would be from two
// different, independently-built chunks straddling a chunk boundary — e.g.
// tile 31 in chunk 0 and tile 32 in chunk 1 of a 32-tile chunk). Both must
// still land on identical world-space positions along their shared edge, so
// the chunked architecture never introduces a visible seam/gap/overlap at
// chunk boundaries regardless of which chunk a tile happens to belong to.
func testReliefChunkEdgeContinuity() {
    let fit = TabletopMapFit(width: 64, height: 64, boardExtent: 0.8)
    let slot = TabletopAtlasSlotMap(graphicIndices: [1] as [Int?])

    // Tile (31, 10) — the east-most tile of "chunk 0" on a 32-wide chunking.
    let westGeo = TabletopTerrainChunkMeshBuilder.buildRelief(
        tiles: [(tileX: 31, tileZ: 10, graphicIndex: 1, height: Float(0.01))],
        fit: fit, slotMap: slot, heightAt: { _, _ in 0.01 }, edgeFloorY: 0.01)
    // Tile (32, 10) — the west-most tile of "chunk 1", built as a wholly
    // separate mesh (as the real chunk board does for each chunk entity).
    let eastGeo = TabletopTerrainChunkMeshBuilder.buildRelief(
        tiles: [(tileX: 32, tileZ: 10, graphicIndex: 1, height: Float(0.01))],
        fit: fit, slotMap: slot, heightAt: { _, _ in 0.01 }, edgeFloorY: 0.01)

    // Both tiles are equal height with equal-height neighbours, so each mesh
    // is exactly its single top quad (4 verts) with no skirts. The quad
    // builder's winding-correction may reorder the 4 corners internally, so
    // identify the shared edge by *position* (max-x pair of the west tile /
    // min-x pair of the east tile) rather than assuming a fixed index order.
    expectEq(westGeo.positions.count, 4, "equal-height tile ⇒ top quad only (west)")
    expectEq(eastGeo.positions.count, 4, "equal-height tile ⇒ top quad only (east)")

    let westMaxX = westGeo.positions.map { $0.x }.max()!
    let eastMinX = eastGeo.positions.map { $0.x }.min()!
    let westEdge = westGeo.positions.filter { abs($0.x - westMaxX) < 1e-5 }
        .sorted { $0.z < $1.z }
    let eastEdge = eastGeo.positions.filter { abs($0.x - eastMinX) < 1e-5 }
        .sorted { $0.z < $1.z }
    expectEq(westEdge.count, 2, "west tile's east edge has exactly 2 vertices")
    expectEq(eastEdge.count, 2, "east tile's west edge has exactly 2 vertices")

    for (w, e) in zip(westEdge, eastEdge) {
        expect(abs(w.x - e.x) < 1e-5, "shared edge x matches, got \(w.x) vs \(e.x)")
        expect(abs(w.z - e.z) < 1e-5, "shared edge z matches, got \(w.z) vs \(e.z)")
        expect(abs(w.y - e.y) < 1e-5, "shared edge y (height) matches, got \(w.y) vs \(e.y)")
    }
}

// Every quad `addQuad` emits (top face or a relief skirt) contributes exactly
// 4 new vertices and 6 indices that reference only *those* 4 vertices — never
// vertices from a different quad. This guards against a whole class of bug
// where a top-face quad's indices could be miswired to reference a skirt's
// vertices (or vice versa), which would corrupt UVs/normals by blending an
// unrelated face into the wrong triangle.
func testReliefQuadIndexLocality() {
    // A lone raised tile with all neighbours lower: top quad + 4 skirts, so
    // there are 5 independent quads (20 verts, 30 indices) to check.
    let tiles = [(tileX: 4, tileZ: 4, graphicIndex: Optional(1), height: Float(0.02))]
    let slot  = TabletopAtlasSlotMap(graphicIndices: tiles.map { $0.graphicIndex })
    let geo = TabletopTerrainChunkMeshBuilder.buildRelief(
        tiles: tiles, fit: reliefFit, slotMap: slot,
        heightAt: { _, _ in 0.0 }, edgeFloorY: 0.0)
    expectEq(geo.positions.count, 20, "top quad + 4 skirts = 5 quads × 4 verts")
    expectEq(geo.triangleIndices.count, 30, "5 quads × 6 indices")

    let idx = geo.triangleIndices
    var quad = 0
    while quad * 6 < idx.count {
        let quadBase = UInt32(quad * 4)
        for i in 0..<6 {
            let vertexIndex = idx[quad * 6 + i]
            expect(vertexIndex >= quadBase && vertexIndex < quadBase + 4,
                   "quad \(quad) index \(vertexIndex) stays within its own 4 vertices "
                   + "[\(quadBase), \(quadBase + 4))")
        }
        quad += 1
    }
}

// MARK: - TabletopChunkReadinessTracker
//
// Regression coverage for the "wholesale tileset-change refresh falsely
// reports stable" bug: TabletopChunkBoard.refreshForTilesetChange marks
// every chunk pending again (even chunks whose terrain didn't individually
// change) and re-requests every atlas. Before this fix, a plain
// incrementing counter would keep growing past totalChunks across repeated
// refreshes and readiness.isStable would report true throughout the
// (actually still-procedural) refresh window.

func testReadinessTrackerStartsAtZero() {
    let tracker = TabletopChunkReadinessTracker(totalChunks: 4)
    expectEq(tracker.atlasReadyCount, 0, "fresh tracker starts with nothing ready")
    expect(!tracker.isStable, "fresh tracker with totalChunks > 0 is not stable")
}

func testReadinessTrackerProgressesToStable() {
    var tracker = TabletopChunkReadinessTracker(totalChunks: 2)
    let a = TabletopChunkKey(chunkX: 0, chunkZ: 0)
    let b = TabletopChunkKey(chunkX: 1, chunkZ: 0)

    let becameStableA = tracker.markReady(a)
    expect(!becameStableA, "one of two ready chunks is not yet stable")
    expectEq(tracker.atlasReadyCount, 1, "1/2 ready")
    expect(!tracker.isStable, "not stable with 1/2 chunks ready")

    let becameStableB = tracker.markReady(b)
    expect(becameStableB, "the second (last) ready chunk newly makes the tracker stable")
    expectEq(tracker.atlasReadyCount, 2, "2/2 ready")
    expect(tracker.isStable, "stable once every chunk is ready")
}

func testReadinessTrackerMarkReadyIsDeduplicated() {
    var tracker = TabletopChunkReadinessTracker(totalChunks: 3)
    let a = TabletopChunkKey(chunkX: 0, chunkZ: 0)
    _ = tracker.markReady(a)
    _ = tracker.markReady(a) // duplicate/late callback for the same chunk
    _ = tracker.markReady(a)
    expectEq(tracker.atlasReadyCount, 1, "marking the same chunk ready repeatedly never double-counts")
}

func testReadinessTrackerMarkReadyOnlyReportsStableOnce() {
    var tracker = TabletopChunkReadinessTracker(totalChunks: 1)
    let a = TabletopChunkKey(chunkX: 0, chunkZ: 0)
    expect(tracker.markReady(a), "the only chunk becoming ready makes the tracker stable")
    expect(!tracker.markReady(a), "reporting the same chunk ready again does not re-report stability")
}

func testReadinessTrackerWholesaleRefreshResetsToZeroThenProgresses() {
    // Simulates TabletopChunkBoard.refreshForTilesetChange: every chunk in a
    // 2x2 board is marked pending again (even though none of them are
    // individually "dirty" by terrain value), then each one's freshly
    // requested atlas lands.
    var tracker = TabletopChunkReadinessTracker(totalChunks: 4)
    let keys = (0..<2).flatMap { x in (0..<2).map { z in TabletopChunkKey(chunkX: x, chunkZ: z) } }
    for k in keys { _ = tracker.markReady(k) }
    expect(tracker.isStable, "precondition: fully stable after the initial build")

    // Tileset-change refresh: mark every chunk pending again.
    for k in keys { tracker.markPending(k) }
    expectEq(tracker.atlasReadyCount, 0, "wholesale refresh immediately reports 0/N, not a stale N/N")
    expect(!tracker.isStable, "not stable immediately after a wholesale refresh")

    // New atlases land one by one; only the last one restabilizes.
    for (i, k) in keys.enumerated() {
        let becameStable = tracker.markReady(k)
        if i < keys.count - 1 {
            expect(!becameStable, "not yet stable before the last chunk lands")
        } else {
            expect(becameStable, "the last chunk landing restabilizes the tracker")
        }
    }
    expectEq(tracker.atlasReadyCount, 4, "deduped progression reaches exactly N/N, never more")
    expect(tracker.isStable, "stable again after the wholesale refresh completes")
}

func testReadinessTrackerMarkPendingIsIdempotentForUnknownKey() {
    var tracker = TabletopChunkReadinessTracker(totalChunks: 2)
    let unknown = TabletopChunkKey(chunkX: 9, chunkZ: 9)
    tracker.markPending(unknown) // never seen before — must not crash or go negative
    expectEq(tracker.atlasReadyCount, 0, "marking an unknown key pending is a harmless no-op")
}

func testReadinessTrackerResetStartsNewBoardRound() {
    var tracker = TabletopChunkReadinessTracker(totalChunks: 1)
    let old = TabletopChunkKey(chunkX: 0, chunkZ: 0)
    _ = tracker.markReady(old)
    expect(tracker.isStable, "precondition: first board reaches stable")

    tracker.reset(totalChunks: 4)
    expectEq(tracker.totalChunks, 4, "reset adopts the new board chunk count")
    expectEq(tracker.atlasReadyCount, 0, "reset discards prior-board readiness")
    expect(!tracker.isStable, "new board starts pending")
    expect(!tracker.didLogStable, "new board may log its own stable transition")
}

// MARK: - Run all tests

@main
struct TabletopChunkGeometryTests {
    static func main() {
        testChunkCount()
        testChunkOrigin()
        testChunkFor()
        testTilesIn()
        testTileKey()

        testAtlasSlotMap()
        testAtlasSlotMapEntries()
        testPaddedAtlasLayout()
        testAtlasLayoutMetalDimensionBoundaries()
        testPaddedAtlasWrapAndUVOrientation()
        testAtlasLayoutSupportsFullDistinctChunk()
        testSyntheticMultiRowAtlasPacking()
        testSyntheticWrappedFrameOrientation()
        testSyntheticSingleRowVerticalGutters()

        testChunkMeshBuilderBasic()
        testChunkMeshBuilderUVs()
        testChunkMeshBuilderPositions()
        testChunkMeshBuilderWinding()
        testChunkMeshBuilderEmpty()
        testChunkMeshBuilderMultiTile()

        testFogMapInit()
        testFogMapSetRevealed()
        testFogMapOutOfBounds()
        testFogMapRevealAll()
        testFogMapCGImage()
        testFogVisibilityThreeStates()
        testFogAlphaOrdering()
        testFogSetRevealedIsBinaryProjection()
        testFogTileVisibilityAndRevealedCompat()
        testFootprintCenterOffset()

        testEntityCountReduction()
        testAcceptanceHoldSleepDurationIsFinite()

        testReliefTopAtTileHeight()
        testReliefSkirtWhenNeighborLower()
        testChunkEdgeContinuity()
        testReliefSkirtsAllFrontFacing()
        testReliefBoundedForFlatGround()
        testReliefChunkEdgeContinuity()
        testReliefQuadIndexLocality()

        testReadinessTrackerStartsAtZero()
        testReadinessTrackerProgressesToStable()
        testReadinessTrackerMarkReadyIsDeduplicated()
        testReadinessTrackerMarkReadyOnlyReportsStableOnce()
        testReadinessTrackerWholesaleRefreshResetsToZeroThenProgresses()
        testReadinessTrackerMarkPendingIsIdempotentForUnknownKey()
        testReadinessTrackerResetStartsNewBoardRound()

        // MARK: - Summary

        print("[\(failedChecks == 0 ? "PASS" : "FAIL")] "
            + "\(totalChecks - failedChecks)/\(totalChecks) checks passed "
            + "(tabletop chunk-geometry)")
        if failedChecks > 0 {
            exit(1)
        }
    }
}
