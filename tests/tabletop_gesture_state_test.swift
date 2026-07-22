import Foundation

@main
struct TabletopGestureStateTest {
    static func main() {
        testRightHandCommandIsEdgeTriggered()
        testLeftHandMovesBoard()
        testTwoHandsScaleAndRebase()
        testScaleClamps()
        testCancellationAndRecenter()
        print("tabletop gesture state tests passed")
    }

    private static func testRightHandCommandIsEdgeTriggered() {
        var state = TabletopGestureState()
        let point = TabletopPoint(x: 10, y: 0, z: 20)
        let first = state.process(.init(hand: .right, phase: .active, point: point))
        check(first == [.commandSelect(point)], "right pinch should emit one command")
        let held = state.process(.init(
            hand: .right,
            phase: .active,
            point: .init(x: 12, y: 0, z: 22)
        ))
        check(held.isEmpty, "held right pinch repeated its command")
        _ = state.process(.init(hand: .right, phase: .ended, point: point))
        let second = state.process(.init(hand: .right, phase: .active, point: point))
        check(second == [.commandSelect(point)], "new right pinch did not emit")
    }

    private static func testLeftHandMovesBoard() {
        var state = TabletopGestureState()
        _ = state.process(.init(
            hand: .left,
            phase: .active,
            point: .init(x: 100, y: 0, z: 100)
        ))
        _ = state.process(.init(
            hand: .left,
            phase: .active,
            point: .init(x: 160, y: 0, z: 70)
        ))
        check(approximately(state.boardPose.x, 0.06), "left x movement is wrong")
        check(approximately(state.boardPose.z, -0.03), "left z movement is wrong")
    }

    private static func testTwoHandsScaleAndRebase() {
        var state = TabletopGestureState()
        _ = state.process(.init(
            hand: .left,
            phase: .active,
            point: .init(x: 0, y: 0, z: 0)
        ))
        _ = state.process(.init(
            hand: .right,
            phase: .active,
            point: .init(x: 100, y: 0, z: 0)
        ))
        _ = state.process(.init(
            hand: .right,
            phase: .active,
            point: .init(x: 150, y: 0, z: 0)
        ))
        check(approximately(state.boardPose.scale, 1.5), "two-hand scale is wrong")

        _ = state.process(.init(
            hand: .right,
            phase: .ended,
            point: .init(x: 150, y: 0, z: 0)
        ))
        let before = state.boardPose
        _ = state.process(.init(
            hand: .left,
            phase: .active,
            point: .init(x: 0, y: 0, z: 0)
        ))
        check(state.boardPose == before, "ending scale jumped the board")
    }

    private static func testScaleClamps() {
        var state = TabletopGestureState()
        _ = state.process(.init(
            hand: .left,
            phase: .active,
            point: .init(x: 0, y: 0, z: 0)
        ))
        _ = state.process(.init(
            hand: .right,
            phase: .active,
            point: .init(x: 100, y: 0, z: 0)
        ))
        _ = state.process(.init(
            hand: .right,
            phase: .active,
            point: .init(x: 1000, y: 0, z: 0)
        ))
        check(approximately(state.boardPose.scale, 1.8), "upper scale clamp failed")
        _ = state.process(.init(
            hand: .right,
            phase: .active,
            point: .init(x: 1, y: 0, z: 0)
        ))
        check(approximately(state.boardPose.scale, 0.55), "lower scale clamp failed")
    }

    private static func testCancellationAndRecenter() {
        var state = TabletopGestureState()
        _ = state.process(.init(
            hand: .left,
            phase: .active,
            point: .init(x: 0, y: 0, z: 0)
        ))
        _ = state.process(.init(
            hand: .left,
            phase: .active,
            point: .init(x: 100, y: 0, z: 100)
        ))
        _ = state.process(.init(
            hand: .left,
            phase: .cancelled,
            point: .init(x: 100, y: 0, z: 100)
        ))
        check(state.activeHandCount == 0, "cancelled pinch remained active")
        state.recenter()
        check(state.boardPose == TabletopBoardPose(), "recenter did not reset pose")
    }

    private static func approximately(
        _ lhs: Double,
        _ rhs: Double,
        tolerance: Double = 0.000_001
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private static func check(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            FileHandle.standardError.write(Data("failure: \(message)\n".utf8))
            Foundation.exit(1)
        }
    }
}
