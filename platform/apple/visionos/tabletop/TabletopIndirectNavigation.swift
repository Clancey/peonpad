// TabletopIndirectNavigation.swift
//
// Framework-free reducer that maps indirect pointer input (a mouse/trackpad
// drag, magnify and rotate — the only way to manipulate the board in the
// visionOS *Simulator*, which has no hand tracking) onto the same
// `TabletopBoardTransform` the physical two-hand manipulation produces.
//
// Keeping this pure means the simulator-navigation math (pan sensitivity,
// scale clamping, rotation mapping, position bounds) is deterministic and
// host-testable, and the RealityView glue only has to translate SwiftUI
// gesture values into these calls.  It never touches the hand-gesture
// manipulator's in-flight state, so device hand gestures keep working
// untouched.
//
//   ./scripts/test-visionos-tabletop-navigation.sh
import Foundation

/// Deterministically maps indirect-pointer gesture deltas onto a board
/// transform.  Every function takes the transform captured at the gesture's
/// *start* plus the gesture's cumulative value, so repeated `.onChanged`
/// callbacks are idempotent (they always recompute from the same base) and a
/// zero delta is exactly the identity.
public enum TabletopIndirectNavigationReducer {

    // MARK: Tuning

    /// Board-plane meters moved per point of pointer drag translation.
    public static let panMetersPerPoint: Double = 0.0016

    /// Scale bounds — identical to the hand manipulator's, so indirect and
    /// direct manipulation can never drive the board to different limits.
    public static let minScale: Double = TabletopBoardManipulator.minimumScale
    public static let maxScale: Double = TabletopBoardManipulator.maximumScale

    /// Board is kept within this horizontal half-range (meters) of the
    /// origin so a fast drag can never fling it out of reach.
    public static let positionHalfRange: Double = 1.5

    // MARK: Operations

    /// Pans the board in the parent-space XZ plane.  A drag to the right
    /// (`translation.width > 0`) moves the board right; a drag downward
    /// (`translation.height > 0`, SwiftUI's +Y is downward) pulls the board
    /// toward the viewer (+Z).  Height (Y) is preserved.
    public static func pan(
        from base: TabletopBoardTransform,
        translationWidth: Double,
        translationHeight: Double
    ) -> TabletopBoardTransform {
        var next = base
        next.position = TabletopPoint3D(
            x: clampPosition(base.position.x + translationWidth * panMetersPerPoint),
            y: base.position.y,
            z: clampPosition(base.position.z + translationHeight * panMetersPerPoint)
        )
        return next
    }

    /// Scales the board by the pointer magnification ratio (1.0 = unchanged),
    /// clamped to `[minScale, maxScale]`.
    public static func zoom(
        from base: TabletopBoardTransform,
        magnification: Double
    ) -> TabletopBoardTransform {
        var next = base
        let ratio = magnification.isFinite && magnification > 0 ? magnification : 1
        next.scale = min(maxScale, max(minScale, base.scale * ratio))
        return next
    }

    /// Rotates the board about its vertical axis by `radians`.
    public static func rotate(
        from base: TabletopBoardTransform,
        radians: Double
    ) -> TabletopBoardTransform {
        var next = base
        next.yawRadians = base.yawRadians + (radians.isFinite ? radians : 0)
        return next
    }

    /// Applies a combined pan + zoom + rotate in one deterministic step, in a
    /// fixed order (pan, then zoom, then rotate), so a single drag that carries
    /// all three cumulative values maps to exactly one resulting transform.
    public static func apply(
        base: TabletopBoardTransform,
        translationWidth: Double = 0,
        translationHeight: Double = 0,
        magnification: Double = 1,
        rotationRadians: Double = 0
    ) -> TabletopBoardTransform {
        var next = pan(from: base,
                       translationWidth: translationWidth,
                       translationHeight: translationHeight)
        next = zoom(from: next, magnification: magnification)
        next = rotate(from: next, radians: rotationRadians)
        return next
    }

    private static func clampPosition(_ value: Double) -> Double {
        min(positionHalfRange, max(-positionHalfRange, value))
    }
}
