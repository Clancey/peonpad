// tabletop_navigation_test.swift
//
// Host-Mac unit tests for the framework-free indirect (mouse/trackpad)
// navigation reducer and its interaction with the physical-hand manipulator:
//   • TabletopIndirectNavigationReducer — pan/zoom/rotate mapping + clamping
//   • TabletopBoardManipulator.setTransform — transform persistence + no jump
//     when a hand gesture resumes after indirect navigation
//
// None of these require SwiftUI, RealityKit, or a Simulator.
//
//   ./scripts/test-visionos-tabletop-navigation.sh
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

func expectClose(_ a: Double, _ b: Double, _ eps: Double, _ message: String,
                 file: StaticString = #file, line: Int = #line) {
    totalChecks += 1
    if abs(a - b) > eps {
        failedChecks += 1
        fputs("FAIL [\(file):\(line)]: \(message) — got \(a), expected \(b) ±\(eps)\n", stderr)
    }
}

private let base = TabletopBoardTransform(
    position: TabletopPoint3D(x: 0, y: 1.1, z: -1.15),
    yawRadians: 0,
    scale: 1)

// MARK: - Pan

func testPanZeroIsIdentity() {
    let out = TabletopIndirectNavigationReducer.pan(from: base, translationWidth: 0, translationHeight: 0)
    expect(out == base, "zero drag is the identity transform")
}

func testPanMapsTranslationToBoardPlane() {
    let out = TabletopIndirectNavigationReducer.pan(from: base, translationWidth: 100, translationHeight: 40)
    let k = TabletopIndirectNavigationReducer.panMetersPerPoint
    expectClose(out.position.x, base.position.x + 100 * k, 1e-9, "drag right moves +X")
    expectClose(out.position.z, base.position.z + 40 * k, 1e-9, "drag down moves +Z (toward viewer)")
    expectClose(out.position.y, base.position.y, 1e-9, "pan preserves height")
    expectClose(out.scale, base.scale, 1e-9, "pan preserves scale")
    expectClose(out.yawRadians, base.yawRadians, 1e-9, "pan preserves yaw")
}

func testPanClampsToReach() {
    let far = TabletopIndirectNavigationReducer.pan(
        from: base, translationWidth: 1_000_000, translationHeight: -1_000_000)
    let r = TabletopIndirectNavigationReducer.positionHalfRange
    expectClose(far.position.x, r, 1e-9, "runaway +X drag clamps to +halfRange")
    expectClose(far.position.z, -r, 1e-9, "runaway -Z drag clamps to -halfRange")
}

// MARK: - Zoom

func testZoomUnitMagnificationIsIdentity() {
    let out = TabletopIndirectNavigationReducer.zoom(from: base, magnification: 1)
    expect(out == base, "magnification 1.0 leaves the transform unchanged")
}

func testZoomScalesAndClamps() {
    let inZoom = TabletopIndirectNavigationReducer.zoom(from: base, magnification: 2)
    expectClose(inZoom.scale, 2, 1e-9, "2× magnification doubles scale")

    let over = TabletopIndirectNavigationReducer.zoom(from: base, magnification: 999)
    expectClose(over.scale, TabletopIndirectNavigationReducer.maxScale, 1e-9, "scale clamps to max")

    let under = TabletopIndirectNavigationReducer.zoom(from: base, magnification: 0.0001)
    expectClose(under.scale, TabletopIndirectNavigationReducer.minScale, 1e-9, "scale clamps to min")
}

func testZoomRejectsInvalidMagnification() {
    let zero = TabletopIndirectNavigationReducer.zoom(from: base, magnification: 0)
    expectClose(zero.scale, base.scale, 1e-9, "zero magnification is ignored")
    let neg = TabletopIndirectNavigationReducer.zoom(from: base, magnification: -3)
    expectClose(neg.scale, base.scale, 1e-9, "negative magnification is ignored")
    let nan = TabletopIndirectNavigationReducer.zoom(from: base, magnification: Double.nan)
    expectClose(nan.scale, base.scale, 1e-9, "NaN magnification is ignored")
}

func testZoomLimitsMatchHandManipulator() {
    expectClose(TabletopIndirectNavigationReducer.minScale, TabletopBoardManipulator.minimumScale, 1e-12,
                "indirect min scale == hand min scale")
    expectClose(TabletopIndirectNavigationReducer.maxScale, TabletopBoardManipulator.maximumScale, 1e-12,
                "indirect max scale == hand max scale")
}

// MARK: - Rotate

func testRotateAddsYaw() {
    let out = TabletopIndirectNavigationReducer.rotate(from: base, radians: 0.5)
    expectClose(out.yawRadians, base.yawRadians + 0.5, 1e-9, "rotate adds to yaw")
    let out2 = TabletopIndirectNavigationReducer.rotate(from: out, radians: -0.2)
    expectClose(out2.yawRadians, 0.3, 1e-9, "rotations compose")
}

func testRotateRejectsNaN() {
    let out = TabletopIndirectNavigationReducer.rotate(from: base, radians: Double.nan)
    expectClose(out.yawRadians, base.yawRadians, 1e-9, "NaN rotation is ignored")
}

// MARK: - Combined apply

func testApplyCombinesAllChannels() {
    let k = TabletopIndirectNavigationReducer.panMetersPerPoint
    let out = TabletopIndirectNavigationReducer.apply(
        base: base, translationWidth: 50, translationHeight: 10,
        magnification: 1.5, rotationRadians: 0.25)
    expectClose(out.position.x, base.position.x + 50 * k, 1e-9, "combined pan X")
    expectClose(out.position.z, base.position.z + 10 * k, 1e-9, "combined pan Z")
    expectClose(out.scale, 1.5, 1e-9, "combined zoom")
    expectClose(out.yawRadians, 0.25, 1e-9, "combined rotate")
}

func testApplyDefaultsAreIdentity() {
    let out = TabletopIndirectNavigationReducer.apply(base: base)
    expect(out == base, "apply with no deltas is the identity")
}

// MARK: - Transform persistence across modalities

func testSetTransformPersists() {
    var m = TabletopBoardManipulator(initial: base)
    let navigated = TabletopIndirectNavigationReducer.apply(
        base: base, translationWidth: 80, magnification: 1.4, rotationRadians: 0.3)
    m.setTransform(navigated)
    expect(m.transform == navigated, "manipulator adopts the navigated transform")
}

func testHandGestureResumesFromNavigatedTransformWithoutJump() {
    // Simulate: user pans/zooms with the trackpad, then grabs with one hand.
    var m = TabletopBoardManipulator(initial: base)
    let navigated = TabletopIndirectNavigationReducer.apply(
        base: base, translationWidth: 120, magnification: 1.8, rotationRadians: 0.4)
    m.setTransform(navigated)

    // A one-hand grab begins; the board must NOT jump on the first active
    // sample (it re-anchors to the navigated transform).
    let start = TabletopGestureSample(id: 1, chirality: .left, phase: .active,
                                      location3D: TabletopPoint3D(x: 0.10, y: 0, z: 0.10))
    let afterGrab = m.update(left: start, right: nil)
    expect(afterGrab == navigated, "first grab sample does not move the board (no jump)")

    // Dragging the hand +0.05 in X/Z translates the navigated transform by
    // exactly that delta, and preserves the navigated scale.
    let moved = TabletopGestureSample(id: 1, chirality: .left, phase: .active,
                                      location3D: TabletopPoint3D(x: 0.15, y: 0, z: 0.15))
    let afterMove = m.update(left: moved, right: nil)
    expectClose(afterMove.position.x, navigated.position.x + 0.05, 1e-9, "hand translate continues from navigated X")
    expectClose(afterMove.position.z, navigated.position.z + 0.05, 1e-9, "hand translate continues from navigated Z")
    expectClose(afterMove.scale, navigated.scale, 1e-9, "hand translate preserves navigated scale")
}

// MARK: - Run all tests

@main
struct TabletopNavigationTests {
    static func main() {
        testPanZeroIsIdentity()
        testPanMapsTranslationToBoardPlane()
        testPanClampsToReach()

        testZoomUnitMagnificationIsIdentity()
        testZoomScalesAndClamps()
        testZoomRejectsInvalidMagnification()
        testZoomLimitsMatchHandManipulator()

        testRotateAddsYaw()
        testRotateRejectsNaN()

        testApplyCombinesAllChannels()
        testApplyDefaultsAreIdentity()

        testSetTransformPersists()
        testHandGestureResumesFromNavigatedTransformWithoutJump()

        print("[\(failedChecks == 0 ? "PASS" : "FAIL")] "
            + "\(totalChecks - failedChecks)/\(totalChecks) checks passed "
            + "(tabletop indirect navigation)")
        if failedChecks > 0 {
            exit(1)
        }
    }
}
