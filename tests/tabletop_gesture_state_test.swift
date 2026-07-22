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

@main
struct TabletopGestureStateTestRunner {
    static func main() {
        testWarcraftFacingNearest()
        testCanonicalFacingMirroring()
        testDirectionalFrameResolution()
        testBillboardOrientationFacesViewer()
        testOneHandTranslate()
        testOneHandRotateViaWristTwist()
        testRightHandAloneNeverMovesBoard()
        testReleaseThenRegrabDoesNotJump()
        testTwoHandScaling()
        testTwoHandRotationFromHandPairAngle()
        testCommandReducerFiresOnceOnEnded()
        testCommandReducerTappedEmptyBoard()
        testCommandReducerCancelledNeverFires()
        testCommandReducerIgnoresLeftHand()

        if failureCount > 0 {
            print("FAILED: \(failureCount)/\(checkCount) checks failed")
            exit(1)
        }
        print("PASSED: \(checkCount)/\(checkCount) checks")
    }
}
