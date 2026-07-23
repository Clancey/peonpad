// tabletop_gesture_state_test.swift
//
// Standalone unit test for the pure tabletop gesture/directional-frame logic
// in platform/apple/visionos/tabletop/TabletopGestureState.swift. It has no
// dependency on RealityKit, SwiftUI, or the visionOS SDK, so it compiles and
// runs directly on the host Mac:
//
//   ./scripts/test-tabletop-gestures.sh
//
// Deliberately does not use Swift's `assert`, which some optimized build
// configurations strip: failures are checked and reported explicitly so the
// test is meaningful regardless of compilation flags.

import Foundation

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
    expect(actual == expected, "\(message) -- expected \(expected), got \(actual)", file: file, line: line)
}

private func expectNear(
    _ actual: Double,
    _ expected: Double,
    tolerance: Double = 1e-6,
    _ message: String,
    file: StaticString = #file,
    line: UInt = #line
) {
    expect(
        abs(actual - expected) <= tolerance,
        "\(message) -- expected \(expected) +/- \(tolerance), got \(actual)",
        file: file,
        line: line
    )
}

// MARK: - WarcraftFacing quantization

func testWarcraftFacingNearest() {
    expectEqual(WarcraftFacing.nearest(toRadians: 0), .north, "zero radians is north")
    expectEqual(WarcraftFacing.nearest(toRadians: .pi / 4), .northEast, "pi/4 is north-east")
    expectEqual(WarcraftFacing.nearest(toRadians: .pi / 2), .east, "pi/2 is east")
    expectEqual(WarcraftFacing.nearest(toRadians: .pi), .south, "pi is south")
    expectEqual(WarcraftFacing.nearest(toRadians: -.pi / 4), .northWest, "negative pi/4 wraps to north-west")
    expectEqual(WarcraftFacing.nearest(toRadians: 2 * .pi), .north, "full turn wraps back to north")
    expectEqual(WarcraftFacing.nearest(toRadians: 2 * .pi + 0.01), .north, "slightly past a full turn stays north")
    // A hair under the NE/E boundary (pi/4 + pi/8) should still read NE.
    expectEqual(
        WarcraftFacing.nearest(toRadians: .pi / 4 + .pi / 8 - 0.001),
        .northEast,
        "just under the NE/E boundary rounds down to NE"
    )
}

// MARK: - WarcraftCanonicalFacing mirroring

func testCanonicalFacingMirroring() {
    let unmirrored: [WarcraftFacing] = [.north, .northEast, .east, .southEast, .south]
    for facing in unmirrored {
        let resolved = WarcraftCanonicalFacing.resolve(facing)
        expect(!resolved.mirrored, "\(facing) should not be mirrored")
    }

    let southWest = WarcraftCanonicalFacing.resolve(.southWest)
    expectEqual(southWest.canonical, .southEast, "south-west mirrors from south-east")
    expect(southWest.mirrored, "south-west must be mirrored")

    let west = WarcraftCanonicalFacing.resolve(.west)
    expectEqual(west.canonical, .east, "west mirrors from east")
    expect(west.mirrored, "west must be mirrored")

    let northWest = WarcraftCanonicalFacing.resolve(.northWest)
    expectEqual(northWest.canonical, .northEast, "north-west mirrors from north-east")
    expect(northWest.mirrored, "north-west must be mirrored")
}

// MARK: - Directional frame (unitFacing - viewerAzimuth)

func testDirectionalFrameResolution() {
    // Unit facing north, viewer standing north of the board looking south at
    // it: the viewer sees the unit's back, so the frame should read south.
    let viewerNorth = TabletopDirectionalFrame.resolve(unitFacingRadians: 0, viewerAzimuthRadians: .pi)
    expectEqual(viewerNorth.facing, .south, "viewer opposite the unit's facing sees its back (south frame)")

    // Unit facing north, viewer also standing north (viewer azimuth 0): the
    // viewer is looking at the unit's front.
    let viewerAligned = TabletopDirectionalFrame.resolve(unitFacingRadians: 0, viewerAzimuthRadians: 0)
    expectEqual(viewerAligned.facing, .north, "viewer aligned with unit facing sees its front (north frame)")
    expect(!viewerAligned.mirrored, "the canonical north frame is never mirrored")

    // Unit facing east, viewer standing so their azimuth is west (-pi/2 i.e.
    // 3pi/2): relative = east(pi/2) - west(3pi/2) = -pi, i.e. south-quantized
    // (opposite side), which mirrors from south-east canonical content.
    let southWestCase = TabletopDirectionalFrame.resolve(
        unitFacingRadians: WarcraftFacing.east.radians,
        viewerAzimuthRadians: 3 * .pi / 2
    )
    expectEqual(southWestCase.facing, .south, "east-facing unit viewed from the west quantizes to south")

    // Sweeping the full circle must always land on a valid canonical frame.
    for degrees in stride(from: 0, to: 360, by: 15) {
        let radians = Double(degrees) * .pi / 180
        let resolution = TabletopDirectionalFrame.resolve(unitFacingRadians: radians, viewerAzimuthRadians: 0)
        expect(
            WarcraftCanonicalFacing.allCases.contains(resolution.canonical),
            "resolution at \(degrees) degrees must be a known canonical facing"
        )
    }
}

// MARK: - Camera-relative directional sprite frame

func testCameraRelativeSpriteDirection() {
    // A flip sheet (Warcraft II convention): 8 directions stored in 5 columns
    // (N, NE, E, SE, S) plus mirroring. animStep 1 => base frame 5.
    let dirs = 8
    let columns = dirs / 2 + 1        // 5

    // Identity at viewer azimuth 0: a north-facing unit whose engine frame is
    // the north column of animation step 1 resolves back to that exact frame.
    let northEngineFrame = 1 * columns + 0   // 5
    let identity = TabletopSpriteDirection.resolve(
        engineFrame: northEngineFrame, engineMirror: false,
        numDirections: dirs, flip: true,
        unitFacingRadians: 0, viewerAzimuthRadians: 0)
    expectEqual(identity.frame, northEngineFrame, "azimuth 0 reproduces the engine map-relative frame")
    expect(!identity.mirror, "north canonical frame is not mirrored")

    // Viewer directly behind the north-facing unit (azimuth pi) sees its back:
    // the south column of the same animation step, animation preserved.
    let behind = TabletopSpriteDirection.resolve(
        engineFrame: northEngineFrame, engineMirror: false,
        numDirections: dirs, flip: true,
        unitFacingRadians: 0, viewerAzimuthRadians: .pi)
    expectEqual(behind.frame, 1 * columns + WarcraftCanonicalFacing.south.rawValue,
                "viewer behind a north-facing unit sees the south column")
    expectEqual(behind.frame / columns, 1, "animation step is preserved across camera reselection")
    expect(!behind.mirror, "south canonical frame is not mirrored")

    // A west-facing view must mirror an eastern column (flip storage). A viewer
    // at azimuth pi/2 sees a north-facing unit's west side.
    let mirroredCase = TabletopSpriteDirection.resolve(
        engineFrame: northEngineFrame, engineMirror: false,
        numDirections: dirs, flip: true,
        unitFacingRadians: 0, viewerAzimuthRadians: .pi / 2)  // viewer east of board
    expect(mirroredCase.mirror, "a west-side view of a flip sheet is drawn mirrored")

    // Non-flip sheet: all 8 directions stored as distinct columns, ordered
    // N..NW clockwise. Identity at azimuth 0; a half-turn shows the south column.
    let nfBase = 1 * dirs + 0        // animStep 1, north column
    let nfIdentity = TabletopSpriteDirection.resolve(
        engineFrame: nfBase, engineMirror: false,
        numDirections: dirs, flip: false,
        unitFacingRadians: 0, viewerAzimuthRadians: 0)
    expectEqual(nfIdentity.frame, nfBase, "non-flip azimuth 0 reproduces the engine frame")
    let nfBehind = TabletopSpriteDirection.resolve(
        engineFrame: nfBase, engineMirror: false,
        numDirections: dirs, flip: false,
        unitFacingRadians: 0, viewerAzimuthRadians: .pi)
    expectEqual(nfBehind.frame, 1 * dirs + WarcraftFacing.south.rawValue,
                "non-flip viewer behind a north-facing unit sees the south column")
    expect(!nfBehind.mirror, "non-flip sheets never mirror")

    // Non-directional sprites (buildings, resources, single-frame effects) must
    // never re-orient with the camera and preserve the engine mirror flag.
    for azimuth in stride(from: 0.0, to: 2 * .pi, by: .pi / 3) {
        let building = TabletopSpriteDirection.resolve(
            engineFrame: 7, engineMirror: true,
            numDirections: 1, flip: false,
            unitFacingRadians: 0, viewerAzimuthRadians: azimuth)
        expectEqual(building.frame, 7, "non-directional sprite frame is camera-invariant")
        expect(building.mirror, "non-directional sprite preserves its engine mirror flag")
    }

    // Orbiting the viewer around a fixed unit must actually change the displayed
    // column (proves camera dependence), and every result is a valid frame.
    var seenColumns = Set<Int>()
    for degrees in stride(from: 0, to: 360, by: 45) {
        let azimuth = Double(degrees) * .pi / 180
        let r = TabletopSpriteDirection.resolve(
            engineFrame: northEngineFrame, engineMirror: false,
            numDirections: dirs, flip: true,
            unitFacingRadians: 0, viewerAzimuthRadians: azimuth)
        expect(r.frame >= 0 && r.frame / columns == 1, "orbiting keeps a valid frame in animation step 1")
        seenColumns.insert(r.frame % columns)
    }
    expect(seenColumns.count > 1, "orbiting the viewer changes the displayed sprite column")
}

// MARK: - Billboard yaw-facing-viewer

func testBillboardOrientationFacesViewer() {
    let unit = TabletopPoint3D(x: 0, y: 0, z: 0)

    let viewerNorth = TabletopPoint3D(x: 0, y: 0, z: 1)
    expectNear(
        TabletopBillboardOrientation.yawFacingViewer(unitBoardPosition: unit, viewerBoardPosition: viewerNorth),
        0,
        "viewer due north of the unit yields zero yaw"
    )

    let viewerEast = TabletopPoint3D(x: 1, y: 0, z: 0)
    expectNear(
        TabletopBillboardOrientation.yawFacingViewer(unitBoardPosition: unit, viewerBoardPosition: viewerEast),
        .pi / 2,
        "viewer due east of the unit yields a quarter-turn yaw"
    )

    let viewerSouth = TabletopPoint3D(x: 0, y: 0, z: -1)
    let southYaw = TabletopBillboardOrientation.yawFacingViewer(unitBoardPosition: unit, viewerBoardPosition: viewerSouth)
    expectNear(abs(southYaw), .pi, tolerance: 1e-6, "viewer due south of the unit yields a half-turn yaw")

    // Height differences must not introduce any tilt/roll -- the function
    // only ever receives X/Z, so it is upright by construction.
    let viewerAbove = TabletopPoint3D(x: 1, y: 5, z: 0)
    expectNear(
        TabletopBillboardOrientation.yawFacingViewer(unitBoardPosition: unit, viewerBoardPosition: viewerAbove),
        .pi / 2,
        "viewer height is ignored; only the board-plane azimuth matters"
    )
}

// MARK: - Board manipulation: one-hand translate/rotate

func testOneHandTranslate() {
    var manipulator = TabletopBoardManipulator()
    let start = TabletopGestureSample(
        id: 1, chirality: .left, phase: .active,
        location3D: TabletopPoint3D(x: 0, y: 0, z: 0)
    )
    _ = manipulator.update(left: start, right: nil)

    let moved = TabletopGestureSample(
        id: 1, chirality: .left, phase: .active,
        location3D: TabletopPoint3D(x: 0.3, y: 0, z: 0.1)
    )
    let transform = manipulator.update(left: moved, right: nil)

    expectNear(transform.position.x, 0.3, "one-hand drag translates X by the hand delta")
    expectNear(transform.position.z, 0.1, "one-hand drag translates Z by the hand delta")
    expectNear(transform.scale, 1, "one-hand drag never changes scale")
}

func testOneHandRotateViaWristTwist() {
    var manipulator = TabletopBoardManipulator()
    let start = TabletopGestureSample(
        id: 2, chirality: .left, phase: .active,
        location3D: .zero, poseAzimuthRadians: 0
    )
    _ = manipulator.update(left: start, right: nil)

    let twisted = TabletopGestureSample(
        id: 2, chirality: .left, phase: .active,
        location3D: .zero, poseAzimuthRadians: .pi / 6
    )
    let transform = manipulator.update(left: twisted, right: nil)

    expectNear(transform.yawRadians, .pi / 6, "wrist twist on the grabbing hand rotates the board")
}

func testRightHandAloneNeverMovesBoard() {
    var manipulator = TabletopBoardManipulator()
    let sample = TabletopGestureSample(
        id: 3, chirality: .right, phase: .active,
        location3D: TabletopPoint3D(x: 1, y: 0, z: 1)
    )
    let transform = manipulator.update(left: nil, right: sample)
    expectEqual(transform, .identity, "a lone right-hand pinch never repositions, rotates, or scales the board")
}

func testReleaseThenRegrabDoesNotJump() {
    var manipulator = TabletopBoardManipulator()
    let start = TabletopGestureSample(id: 4, chirality: .left, phase: .active, location3D: .zero)
    _ = manipulator.update(left: start, right: nil)
    let moved = TabletopGestureSample(id: 4, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: 0.2, y: 0, z: 0))
    let afterFirstDrag = manipulator.update(left: moved, right: nil)
    expectNear(afterFirstDrag.position.x, 0.2, "first drag moves the board")

    let ended = TabletopGestureSample(id: 4, chirality: .left, phase: .ended, location3D: TabletopPoint3D(x: 0.2, y: 0, z: 0))
    _ = manipulator.update(left: ended, right: nil)

    // A fresh grab starting from a different point must not cause a jump:
    // the anchor should reset to the new starting sample.
    let regrabStart = TabletopGestureSample(id: 5, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: 5, y: 0, z: 5))
    let afterRegrabStart = manipulator.update(left: regrabStart, right: nil)
    expectNear(afterRegrabStart.position.x, 0.2, "the instant of re-grab does not itself move the board")

    let regrabMoved = TabletopGestureSample(id: 5, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: 5.1, y: 0, z: 5))
    let afterRegrabMove = manipulator.update(left: regrabMoved, right: nil)
    expectNear(afterRegrabMove.position.x, 0.3, "the second drag continues smoothly from the board's last position")
}

func testTwoHandScaling() {
    var manipulator = TabletopBoardManipulator()
    let leftStart = TabletopGestureSample(id: 10, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: -0.2, y: 0, z: 0))
    let rightStart = TabletopGestureSample(id: 11, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 0.2, y: 0, z: 0))
    _ = manipulator.update(left: leftStart, right: rightStart)

    // Hands spread twice as far apart: scale should double.
    let leftWide = TabletopGestureSample(id: 10, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: -0.4, y: 0, z: 0))
    let rightWide = TabletopGestureSample(id: 11, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 0.4, y: 0, z: 0))
    let widened = manipulator.update(left: leftWide, right: rightWide)
    expectNear(widened.scale, 2.0, "doubling the hand separation doubles the scale")

    // Hands brought far closer than the floor should clamp, not invert/zero.
    let leftClose = TabletopGestureSample(id: 10, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: -0.001, y: 0, z: 0))
    let rightClose = TabletopGestureSample(id: 11, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 0.001, y: 0, z: 0))
    let shrunk = manipulator.update(left: leftClose, right: rightClose)
    expect(shrunk.scale >= TabletopBoardManipulator.minimumScale, "scale never drops below the configured floor")

    var grownManipulator = TabletopBoardManipulator()
    _ = grownManipulator.update(left: leftStart, right: rightStart)
    let leftFar = TabletopGestureSample(id: 10, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: -5, y: 0, z: 0))
    let rightFar = TabletopGestureSample(id: 11, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 5, y: 0, z: 0))
    let grown = grownManipulator.update(left: leftFar, right: rightFar)
    expect(grown.scale <= TabletopBoardManipulator.maximumScale, "scale never exceeds the configured ceiling")
}

func testTwoHandRotationFromHandPairAngle() {
    var manipulator = TabletopBoardManipulator()
    let leftStart = TabletopGestureSample(id: 20, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: -0.2, y: 0, z: 0))
    let rightStart = TabletopGestureSample(id: 21, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 0.2, y: 0, z: 0))
    _ = manipulator.update(left: leftStart, right: rightStart)

    // Rotate the hand pair a quarter turn (right hand moves from due east of
    // left hand to due north of it).
    let leftRotated = TabletopGestureSample(id: 20, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: 0, y: 0, z: -0.2))
    let rightRotated = TabletopGestureSample(id: 21, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 0, y: 0, z: 0.2))
    let transform = manipulator.update(left: leftRotated, right: rightRotated)
    expectNear(abs(transform.yawRadians), .pi / 2, tolerance: 1e-6, "rotating the hand pair a quarter turn yaws the board a quarter turn")
}

// MARK: - Board manipulation: no-jump hand-count transitions

func testTwoHandJoinLeftFirstDoesNotJump() {
    var manipulator = TabletopBoardManipulator()
    let leftStart = TabletopGestureSample(id: 30, chirality: .left, phase: .active, location3D: .zero)
    _ = manipulator.update(left: leftStart, right: nil)

    let leftMoved = TabletopGestureSample(id: 30, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: 0.5, y: 0, z: 0))
    let afterOneHand = manipulator.update(left: leftMoved, right: nil)
    expectNear(afterOneHand.position.x, 0.5, "one-hand drag moves the board before the second hand joins")

    // The right hand joins at its own current location while the left hand
    // sample is unchanged: nothing has moved relative to this instant, so
    // the board must not jump the moment two-hand mode begins.
    let rightJoin = TabletopGestureSample(id: 31, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 1, y: 0, z: 0))
    let atJoin = manipulator.update(left: leftMoved, right: rightJoin)
    expectNear(atJoin.position.x, afterOneHand.position.x, "the instant the second (right) hand joins does not itself move the board")
    expectNear(atJoin.position.z, afterOneHand.position.z, "the instant the second (right) hand joins does not itself move the board (z)")
    expectNear(atJoin.yawRadians, afterOneHand.yawRadians, "the instant the second (right) hand joins does not itself rotate the board")
    expectNear(atJoin.scale, afterOneHand.scale, "the instant the second (right) hand joins does not itself rescale the board")

    // Spreading both hands after the join should scale up smoothly from
    // this fresh anchor, not from the original one-hand start sample.
    let leftWide = TabletopGestureSample(id: 30, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: 0.2, y: 0, z: 0))
    let rightWide = TabletopGestureSample(id: 31, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 1.3, y: 0, z: 0))
    let afterSpread = manipulator.update(left: leftWide, right: rightWide)
    expect(afterSpread.scale > atJoin.scale, "spreading both hands after the join grows the scale smoothly, without a jump")
}

func testTwoHandJoinRightFirstDoesNotJump() {
    var manipulator = TabletopBoardManipulator()
    // A lone right hand never manipulates the board, but its start sample is
    // still tracked once active, and it is free to wander before the left
    // hand joins.
    let rightStart = TabletopGestureSample(id: 40, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 1, y: 0, z: 0))
    let whileRightAlone = manipulator.update(left: nil, right: rightStart)
    expectEqual(whileRightAlone, .identity, "a lone right hand never moves the board even while tracked")

    let rightWandered = TabletopGestureSample(id: 40, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 4, y: 0, z: 3))
    _ = manipulator.update(left: nil, right: rightWandered)

    // The left hand now joins. Even though the right hand's start sample is
    // stale (from far away), the join must re-anchor BOTH hands, so the
    // instant of joining still does not move the board.
    let leftJoin = TabletopGestureSample(id: 41, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: -1, y: 0, z: 0))
    let atJoin = manipulator.update(left: leftJoin, right: rightWandered)
    expectEqual(atJoin, .identity, "the instant the left hand joins a wandered right hand does not itself move the board")

    // Moving both hands further apart should scale up smoothly from this
    // fresh anchor, not blow up from the stale, far-away right-hand start.
    let leftWide = TabletopGestureSample(id: 41, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: -2, y: 0, z: 0))
    let rightWide = TabletopGestureSample(id: 40, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 5, y: 0, z: 3))
    let afterSpread = manipulator.update(left: leftWide, right: rightWide)
    expect(afterSpread.scale > atJoin.scale, "spreading both hands after a right-first join grows the scale smoothly, without a jump")
}

func testTwoHandReleaseRightContinueLeftDoesNotJump() {
    var manipulator = TabletopBoardManipulator()
    let leftStart = TabletopGestureSample(id: 50, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: -0.2, y: 0, z: 0))
    let rightStart = TabletopGestureSample(id: 51, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 0.2, y: 0, z: 0))
    _ = manipulator.update(left: leftStart, right: rightStart)

    let leftMid = TabletopGestureSample(id: 50, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: -0.4, y: 0, z: 0))
    let rightMid = TabletopGestureSample(id: 51, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 0.4, y: 0, z: 0))
    let afterTwoHand = manipulator.update(left: leftMid, right: rightMid)
    expectNear(afterTwoHand.scale, 2.0, "two-hand spreading before release doubles the scale")

    // The right hand releases; the left hand's sample is unchanged. This
    // must not jump: the surviving hand's start sample and the
    // transform-at-start both need to be re-anchored to right now.
    let rightEnded = TabletopGestureSample(id: 51, chirality: .right, phase: .ended, location3D: TabletopPoint3D(x: 0.4, y: 0, z: 0))
    let atRelease = manipulator.update(left: leftMid, right: rightEnded)
    expectNear(atRelease.position.x, afterTwoHand.position.x, "releasing the right hand does not itself move the board")
    expectNear(atRelease.yawRadians, afterTwoHand.yawRadians, "releasing the right hand does not itself rotate the board")
    expectNear(atRelease.scale, afterTwoHand.scale, "releasing the right hand does not itself change the scale")

    // One-hand manipulation with the surviving left hand should continue
    // smoothly from here, on top of the scale two-hand mode left behind.
    let leftFurther = TabletopGestureSample(id: 50, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: -0.5, y: 0, z: 0))
    let afterContinued = manipulator.update(left: leftFurther, right: nil)
    expectNear(afterContinued.position.x, -0.1, "one-hand manipulation continues smoothly from the re-anchored release point")
    expectNear(afterContinued.scale, 2.0, "the scale established during two-hand mode persists through one-hand continuation")
}

func testTwoHandReleaseLeftLeavesRightHandStableDoesNotJump() {
    var manipulator = TabletopBoardManipulator()
    let leftStart = TabletopGestureSample(id: 60, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: -0.2, y: 0, z: 0))
    let rightStart = TabletopGestureSample(id: 61, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 0.2, y: 0, z: 0))
    _ = manipulator.update(left: leftStart, right: rightStart)

    let leftMid = TabletopGestureSample(id: 60, chirality: .left, phase: .active, location3D: TabletopPoint3D(x: -0.4, y: 0, z: 0))
    let rightMid = TabletopGestureSample(id: 61, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 0.4, y: 0, z: 0))
    let afterTwoHand = manipulator.update(left: leftMid, right: rightMid)
    expectNear(afterTwoHand.scale, 2.0, "two-hand spreading before release doubles the scale")

    // The left hand releases; only the right hand remains. A lone right
    // hand never manipulates the board, so this must hold exactly at the
    // two-hand result -- no jump, no drift.
    let leftEnded = TabletopGestureSample(id: 60, chirality: .left, phase: .ended, location3D: TabletopPoint3D(x: -0.4, y: 0, z: 0))
    let atRelease = manipulator.update(left: leftEnded, right: rightMid)
    expectEqual(atRelease, afterTwoHand, "releasing the left hand and continuing with a lone right hand does not jump")

    // Further right-hand-only movement still must not move the board.
    let rightFurther = TabletopGestureSample(id: 61, chirality: .right, phase: .active, location3D: TabletopPoint3D(x: 2, y: 0, z: -1))
    let afterRightAlone = manipulator.update(left: nil, right: rightFurther)
    expectEqual(afterRightAlone, afterTwoHand, "a lone right hand remains inert even after having just been part of a two-hand grab")
}

// MARK: - Unit billboard appearance: selection composes with direction

func testUnitAppearanceQuadAlphaComposesWithSelection() {
    expectNear(TabletopUnitAppearance.quadAlpha(selected: true), 1.0, "a selected unit's directional quad is fully opaque")
    expectNear(TabletopUnitAppearance.quadAlpha(selected: false), 0.22, "a deselected unit's directional quad stays dim")
}

func testUnitAppearanceBodyAlphaComposesWithSelection() {
    expectNear(TabletopUnitAppearance.bodyAlpha(selected: true), 0.5, "a selected unit's cylindrical body brightens")
    expectNear(TabletopUnitAppearance.bodyAlpha(selected: false), 0.22, "a deselected unit's cylindrical body stays dim")
}

func testUnitAppearanceIsIndependentOfDirectionalResolution() {
    // The appearance resolver takes only selection state -- it must never
    // need (or be tempted to fold in) which canonical direction was
    // resolved, so a per-frame directional update can safely reuse whatever
    // alpha the last selection decided without recomputing anything about
    // direction.
    for selected in [true, false] {
        let firstCall = TabletopUnitAppearance.quadAlpha(selected: selected)
        let secondCall = TabletopUnitAppearance.quadAlpha(selected: selected)
        expectNear(firstCall, secondCall, "quad alpha is a pure function of selection state alone")
    }
}

// MARK: - Right-hand command reducer

func testCommandReducerFiresOnceOnEnded() {
    var reducer = TabletopCommandReducer()
    let active = TabletopGestureSample(id: 100, chirality: .right, phase: .active, location3D: .zero, targetedEntityName: "unit.footman.0")
    expectEqual(reducer.update(right: active), .none, "an active pinch does not fire a command yet")

    let ended = TabletopGestureSample(id: 100, chirality: .right, phase: .ended, location3D: .zero, targetedEntityName: "unit.footman.0")
    expectEqual(
        reducer.update(right: ended),
        .tappedEntity(name: "unit.footman.0", boardPoint: .zero),
        "an ended pinch over a named entity fires exactly that selection"
    )

    // The same terminal sample delivered again must not double-fire.
    expectEqual(reducer.update(right: ended), .none, "a repeated ended sample for the same gesture does not re-fire")
}

func testCommandReducerTappedEmptyBoard() {
    var reducer = TabletopCommandReducer()
    let ended = TabletopGestureSample(
        id: 101, chirality: .right, phase: .ended,
        location3D: TabletopPoint3D(x: 0.4, y: 0, z: 0.2), targetedEntityName: nil
    )
    expectEqual(
        reducer.update(right: ended),
        .tappedEmpty(boardPoint: TabletopPoint3D(x: 0.4, y: 0, z: 0.2)),
        "an ended pinch over empty board space fires a move-order style event with no entity name"
    )
}

func testCommandReducerCancelledNeverFires() {
    var reducer = TabletopCommandReducer()
    let cancelled = TabletopGestureSample(id: 102, chirality: .right, phase: .cancelled, location3D: .zero, targetedEntityName: "unit.peasant.0")
    expectEqual(reducer.update(right: cancelled), .none, "a cancelled pinch never fires a command")
}

func testCommandReducerIgnoresLeftHand() {
    var reducer = TabletopCommandReducer()
    let leftEnded = TabletopGestureSample(id: 103, chirality: .left, phase: .ended, location3D: .zero, targetedEntityName: "unit.peasant.0")
    expectEqual(reducer.update(right: leftEnded), .none, "the command reducer ignores non-right-hand samples")
}

// MARK: - Command reducer: two-hand suppression (defect regression)

func testCommandReducerSuppressedIDDoesNotFireOnEnded() {
    var reducer = TabletopCommandReducer()
    reducer.suppressRightHandID(200)

    let ended = TabletopGestureSample(
        id: 200, chirality: .right, phase: .ended,
        location3D: .zero, targetedEntityName: "unit.footman.0"
    )
    expectEqual(
        reducer.update(right: ended),
        .none,
        "a suppressed right-hand event does not fire a command when it ends"
    )
}

func testCommandReducerSuppressedIDClearedAfterTerminalPhase() {
    var reducer = TabletopCommandReducer()
    reducer.suppressRightHandID(201)

    // The suppressed event ends: its ID must be removed from the set.
    let ended = TabletopGestureSample(id: 201, chirality: .right, phase: .ended, location3D: .zero, targetedEntityName: "unit.A")
    _ = reducer.update(right: ended)

    // A fresh, independent event with the same numeric ID must fire normally.
    let freshEnded = TabletopGestureSample(id: 201, chirality: .right, phase: .ended, location3D: .zero, targetedEntityName: "unit.A")
    expectEqual(
        reducer.update(right: freshEnded),
        .tappedEntity(name: "unit.A", boardPoint: .zero),
        "after the suppressed terminal event, a fresh event with the same ID is no longer suppressed"
    )
}

func testCommandReducerSuppressedCancelledAlsoClearsID() {
    var reducer = TabletopCommandReducer()
    reducer.suppressRightHandID(202)

    let cancelled = TabletopGestureSample(id: 202, chirality: .right, phase: .cancelled, location3D: .zero, targetedEntityName: "unit.B")
    expectEqual(reducer.update(right: cancelled), .none, "a suppressed event does not fire on cancel")

    // After cancel the ID should be gone; a fresh ended event fires normally.
    let freshEnded = TabletopGestureSample(id: 202, chirality: .right, phase: .ended, location3D: .zero, targetedEntityName: "unit.B")
    expectEqual(
        reducer.update(right: freshEnded),
        .tappedEntity(name: "unit.B", boardPoint: .zero),
        "after the cancelled suppressed event, a fresh same-ID event fires normally"
    )
}

func testCommandReducerTwoHandStaggeredReleaseDoesNotFireCommand() {
    // Regression: staggered two-hand release must never dispatch an accidental
    // right-hand gameplay command. Scenario:
    //   1. Both hands active → suppress the right-hand event ID.
    //   2. Left hand releases (left disappears from events).
    //   3. Right hand ends → must NOT fire a command.
    var reducer = TabletopCommandReducer()

    let rightID = 203
    reducer.suppressRightHandID(rightID)  // simulates both-hands-active frame

    let rightEnded = TabletopGestureSample(
        id: rightID, chirality: .right, phase: .ended,
        location3D: TabletopPoint3D(x: 0.1, y: 0, z: 0.1),
        targetedEntityName: "unit.sentry.north"
    )
    expectEqual(
        reducer.update(right: rightEnded),
        .none,
        "staggered two-hand release does not fire an accidental gameplay command"
    )
}

func testCommandReducerNonSuppressedRightHandFiresNormally() {
    var reducer = TabletopCommandReducer()

    let ended = TabletopGestureSample(
        id: 204, chirality: .right, phase: .ended,
        location3D: .zero, targetedEntityName: "unit.sentry.north"
    )
    expectEqual(
        reducer.update(right: ended),
        .tappedEntity(name: "unit.sentry.north", boardPoint: .zero),
        "an unsuppressed right-hand event fires a gameplay command normally"
    )
}

@main
struct TabletopGestureStateTestRunner {
    static func main() {
        testWarcraftFacingNearest()
        testCanonicalFacingMirroring()
        testDirectionalFrameResolution()
        testCameraRelativeSpriteDirection()
        testBillboardOrientationFacesViewer()
        testOneHandTranslate()
        testOneHandRotateViaWristTwist()
        testRightHandAloneNeverMovesBoard()
        testReleaseThenRegrabDoesNotJump()
        testTwoHandScaling()
        testTwoHandRotationFromHandPairAngle()
        testTwoHandJoinLeftFirstDoesNotJump()
        testTwoHandJoinRightFirstDoesNotJump()
        testTwoHandReleaseRightContinueLeftDoesNotJump()
        testTwoHandReleaseLeftLeavesRightHandStableDoesNotJump()
        testUnitAppearanceQuadAlphaComposesWithSelection()
        testUnitAppearanceBodyAlphaComposesWithSelection()
        testUnitAppearanceIsIndependentOfDirectionalResolution()
        testCommandReducerFiresOnceOnEnded()
        testCommandReducerTappedEmptyBoard()
        testCommandReducerCancelledNeverFires()
        testCommandReducerIgnoresLeftHand()
        testCommandReducerSuppressedIDDoesNotFireOnEnded()
        testCommandReducerSuppressedIDClearedAfterTerminalPhase()
        testCommandReducerSuppressedCancelledAlsoClearsID()
        testCommandReducerTwoHandStaggeredReleaseDoesNotFireCommand()
        testCommandReducerNonSuppressedRightHandFiresNormally()

        if failureCount > 0 {
            print("FAILED: \(failureCount)/\(checkCount) checks failed")
            exit(1)
        }
        print("PASSED: \(checkCount)/\(checkCount) checks")
    }
}
