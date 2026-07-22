// TabletopGestureState.swift
//
// Framework-independent tabletop gesture and directional-frame logic.
//
// Nothing in this file imports SwiftUI, RealityKit, or UIKit. The native
// tabletop app's RealityView/gesture glue maps real
// `SwiftUI.SpatialEventCollection.Event` values into the plain
// `TabletopGestureSample` struct defined here, then feeds them through the
// deterministic reducers below. Keeping this layer pure lets the important
// interaction rules -- which hand does what, how two-hand scaling is
// clamped, and how a unit's world-facing direction maps onto a
// viewer-facing billboard -- be unit tested on the host Mac with a plain
// `swiftc`/`swift` invocation, without booting the visionOS Simulator.
import Foundation

/// A plain 3D point in the board's local meter space, independent of any UI
/// or rendering framework's vector type.
public struct TabletopPoint3D: Equatable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = TabletopPoint3D(x: 0, y: 0, z: 0)

    public static func + (lhs: TabletopPoint3D, rhs: TabletopPoint3D) -> TabletopPoint3D {
        TabletopPoint3D(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    public static func - (lhs: TabletopPoint3D, rhs: TabletopPoint3D) -> TabletopPoint3D {
        TabletopPoint3D(x: lhs.x - rhs.x, y: lhs.y - rhs.y, z: lhs.z - rhs.z)
    }

    /// Midpoint on the board's horizontal (X/Z) plane, ignoring height.
    public static func midpointXZ(_ a: TabletopPoint3D, _ b: TabletopPoint3D) -> TabletopPoint3D {
        TabletopPoint3D(x: (a.x + b.x) / 2, y: 0, z: (a.z + b.z) / 2)
    }

    /// Horizontal-plane (board plane, X/Z) distance, ignoring height.
    public func planarDistance(to other: TabletopPoint3D) -> Double {
        let dx = x - other.x
        let dz = z - other.z
        return (dx * dx + dz * dz).squareRoot()
    }
}

/// Which hand produced a gesture sample. The tabletop's fixed convention:
/// the right hand is the command/selection hand, the left hand grabs and
/// manipulates the board.
public enum TabletopChirality: Equatable {
    case left
    case right
}

/// Mirrors `SwiftUI.SpatialEventCollection.Event.Phase`.
public enum TabletopGesturePhase: Equatable {
    case active
    case ended
    case cancelled
}

/// Mirrors the subset of `SwiftUI.SpatialEventCollection.Event.Kind` the
/// tabletop cares about.
public enum TabletopGestureKind: Equatable {
    case directPinch
    case indirectPinch
    case touch
    case pointer
}

/// A framework-independent snapshot of one `SpatialEventCollection.Event`.
/// The RealityView gesture glue is responsible for producing one of these
/// per hand, per frame, from the real SwiftUI event (reading its `chirality`,
/// `location3D`, `targetedEntity.name`, and `inputDevicePose.azimuth`).
public struct TabletopGestureSample: Equatable {
    public var id: Int
    public var chirality: TabletopChirality
    public var kind: TabletopGestureKind
    public var phase: TabletopGesturePhase
    public var location3D: TabletopPoint3D
    /// The input device's azimuth (radians) at the moment of this sample,
    /// derived from `SpatialEventCollection.Event.InputDevicePose.azimuth`.
    /// Used to let a single grabbing hand twist the board without needing a
    /// second hand.
    public var poseAzimuthRadians: Double
    /// The stable name of the RealityKit entity this event targeted, if any.
    public var targetedEntityName: String?

    public init(
        id: Int,
        chirality: TabletopChirality,
        kind: TabletopGestureKind = .directPinch,
        phase: TabletopGesturePhase,
        location3D: TabletopPoint3D,
        poseAzimuthRadians: Double = 0,
        targetedEntityName: String? = nil
    ) {
        self.id = id
        self.chirality = chirality
        self.kind = kind
        self.phase = phase
        self.location3D = location3D
        self.poseAzimuthRadians = poseAzimuthRadians
        self.targetedEntityName = targetedEntityName
    }
}

/// The board's deterministic placement: position (meters, board-parent
/// space), yaw around the vertical/board-normal axis (radians), and uniform
/// scale.
public struct TabletopBoardTransform: Equatable {
    public var position: TabletopPoint3D
    public var yawRadians: Double
    public var scale: Double

    public init(position: TabletopPoint3D = .zero, yawRadians: Double = 0, scale: Double = 1) {
        self.position = position
        self.yawRadians = yawRadians
        self.scale = scale
    }

    public static let identity = TabletopBoardTransform()
}

/// Deterministically reduces left-hand (and, for two-hand scaling,
/// right-hand) gesture samples into a board transform. The right hand alone
/// never manipulates the board -- it is reserved for command intents, see
/// `TabletopCommandReducer`.
public struct TabletopBoardManipulator: Equatable {
    public private(set) var transform: TabletopBoardTransform

    private var leftStart: TabletopGestureSample?
    private var rightStart: TabletopGestureSample?
    private var transformAtGestureStart: TabletopBoardTransform

    public static let minimumScale = 0.25
    public static let maximumScale = 3.0

    public init(initial: TabletopBoardTransform = .identity) {
        transform = initial
        transformAtGestureStart = initial
    }

    /// Feed this frame's latest left/right-hand sample. Pass `nil` for a
    /// hand that has no active direct pinch this frame. Returns the updated
    /// transform. Deterministic: the same ordered sequence of calls always
    /// produces the same result.
    @discardableResult
    public mutating func update(left: TabletopGestureSample?, right: TabletopGestureSample?) -> TabletopBoardTransform {
        let activeLeft = left.flatMap { $0.phase == .active ? $0 : nil }
        let activeRight = right.flatMap { $0.phase == .active ? $0 : nil }

        // Capture the mode we were in *before* this frame's phase changes
        // are applied, so the transitions below can tell a hand joining/
        // leaving two-hand mode apart from ordinary within-mode continuation.
        let wasTwoHand = leftStart != nil && rightStart != nil

        if activeLeft == nil {
            leftStart = nil
        }
        if activeRight == nil {
            rightStart = nil
        }

        guard activeLeft != nil || activeRight != nil else {
            return transform
        }

        let isTwoHand = activeLeft != nil && activeRight != nil

        if isTwoHand, !wasTwoHand {
            // Entering two-hand mode this frame -- regardless of which hand
            // was already down and which just joined (left-first or
            // right-first), re-anchor BOTH hands' start samples and the
            // transform-at-start to right now. Otherwise two-hand math would
            // measure against whichever hand's stale one-hand start sample
            // is furthest away, and the board would jump the instant the
            // second hand joins.
            leftStart = activeLeft
            rightStart = activeRight
            transformAtGestureStart = transform
        } else if wasTwoHand, !isTwoHand {
            // Leaving two-hand mode this frame -- re-anchor the surviving
            // hand's start sample and the transform-at-start to right now,
            // so one-hand manipulation resumes smoothly from where two-hand
            // math left off, regardless of which hand released.
            transformAtGestureStart = transform
            leftStart = activeLeft ?? leftStart
            rightStart = activeRight ?? rightStart
        } else {
            // Ordinary within-mode continuation: (re)anchor a hand the
            // instant it newly becomes active (zero-hand -> one-hand) so
            // manipulation always starts from the board's current
            // transform, never a stale one.
            if activeLeft != nil, leftStart == nil {
                leftStart = activeLeft
                transformAtGestureStart = transform
            }
            if activeRight != nil, rightStart == nil {
                rightStart = activeRight
                transformAtGestureStart = transform
            }
        }

        if let l0 = leftStart, let r0 = rightStart, let l1 = activeLeft, let r1 = activeRight {
            transform = Self.twoHand(from: transformAtGestureStart, start: (l0, r0), current: (l1, r1))
        } else if let l0 = leftStart, let l1 = activeLeft {
            transform = Self.oneHand(from: transformAtGestureStart, start: l0, current: l1)
        }
        // A lone right hand never repositions, rotates, or scales the board.

        return transform
    }

    private static func oneHand(
        from start: TabletopBoardTransform,
        start l0: TabletopGestureSample,
        current l1: TabletopGestureSample
    ) -> TabletopBoardTransform {
        let delta = l1.location3D - l0.location3D
        let yawDelta = l1.poseAzimuthRadians - l0.poseAzimuthRadians
        return TabletopBoardTransform(
            position: start.position + TabletopPoint3D(x: delta.x, y: 0, z: delta.z),
            yawRadians: start.yawRadians + yawDelta,
            scale: start.scale
        )
    }

    private static func twoHand(
        from start: TabletopBoardTransform,
        start startPair: (left: TabletopGestureSample, right: TabletopGestureSample),
        current currentPair: (left: TabletopGestureSample, right: TabletopGestureSample)
    ) -> TabletopBoardTransform {
        let startMid = TabletopPoint3D.midpointXZ(startPair.left.location3D, startPair.right.location3D)
        let currentMid = TabletopPoint3D.midpointXZ(currentPair.left.location3D, currentPair.right.location3D)
        let translation = currentMid - startMid

        let startDistance = max(
            startPair.left.location3D.planarDistance(to: startPair.right.location3D),
            0.001
        )
        let currentDistance = currentPair.left.location3D.planarDistance(to: currentPair.right.location3D)
        let ratio = currentDistance / startDistance
        let scale = min(maximumScale, max(minimumScale, start.scale * ratio))

        let startAngle = handPairAngle(startPair.left.location3D, startPair.right.location3D)
        let currentAngle = handPairAngle(currentPair.left.location3D, currentPair.right.location3D)
        let yaw = start.yawRadians + (currentAngle - startAngle)

        return TabletopBoardTransform(
            position: start.position + TabletopPoint3D(x: translation.x, y: 0, z: translation.z),
            yawRadians: yaw,
            scale: scale
        )
    }

    /// Angle (radians, board convention: 0 = north/+Z, increasing clockwise)
    /// of the vector from the left hand to the right hand, in the board's
    /// horizontal plane.
    private static func handPairAngle(_ left: TabletopPoint3D, _ right: TabletopPoint3D) -> Double {
        let dx = right.x - left.x
        let dz = right.z - left.z
        return atan2(dx, dz)
    }
}

/// The right hand's outcome for one completed gesture: either it landed on a
/// named entity (a unit, the palette, etc.) or on empty board space.
public enum TabletopRightHandEvent: Equatable {
    case none
    case tappedEntity(name: String, boardPoint: TabletopPoint3D)
    case tappedEmpty(boardPoint: TabletopPoint3D)
}

/// Deterministically turns right-hand samples into edge-triggered command
/// events, firing exactly once per completed (`.ended`) gesture.
public struct TabletopCommandReducer: Equatable {
    private var lastFiredID: Int?

    public init() {}

    @discardableResult
    public mutating func update(right: TabletopGestureSample?) -> TabletopRightHandEvent {
        guard let right, right.chirality == .right else {
            return .none
        }
        switch right.phase {
        case .active:
            return .none
        case .cancelled:
            return .none
        case .ended:
            guard lastFiredID != right.id else {
                return .none
            }
            lastFiredID = right.id
            if let name = right.targetedEntityName {
                return .tappedEntity(name: name, boardPoint: right.location3D)
            }
            return .tappedEmpty(boardPoint: right.location3D)
        }
    }
}

/// The eight logical directions a Warcraft-style sprite unit can face,
/// listed clockwise starting at board/map north (+Z in board-local space).
public enum WarcraftFacing: Int, CaseIterable, Equatable {
    case north = 0
    case northEast = 1
    case east = 2
    case southEast = 3
    case south = 4
    case southWest = 5
    case west = 6
    case northWest = 7

    public var radians: Double {
        Double(rawValue) * (.pi / 4)
    }

    /// The nearest logical facing for an arbitrary world-space angle
    /// (radians, 0 = north, increasing clockwise), wrapping correctly for
    /// negative and multi-turn inputs.
    public static func nearest(toRadians angle: Double) -> WarcraftFacing {
        let twoPi = Double.pi * 2
        var normalized = angle.truncatingRemainder(dividingBy: twoPi)
        if normalized < 0 {
            normalized += twoPi
        }
        let step = Double.pi / 4
        let index = Int((normalized / step).rounded()) % 8
        return WarcraftFacing(rawValue: index) ?? .north
    }
}

/// Warcraft II's sprite sheets store only five unique facings (N, NE, E, SE,
/// S) and mirror them horizontally for the remaining three (NW, W, SW).
/// This models that storage convention for the procedural billboard
/// content, without embedding any actual sprite data.
public enum WarcraftCanonicalFacing: Int, CaseIterable, Equatable {
    case north
    case northEast
    case east
    case southEast
    case south

    /// Resolves any of the eight logical facings to its canonical stored
    /// direction and whether it must be mirrored horizontally to represent
    /// that facing.
    public static func resolve(_ facing: WarcraftFacing) -> (canonical: WarcraftCanonicalFacing, mirrored: Bool) {
        switch facing {
        case .north: return (.north, false)
        case .northEast: return (.northEast, false)
        case .east: return (.east, false)
        case .southEast: return (.southEast, false)
        case .south: return (.south, false)
        case .southWest: return (.southEast, true)
        case .west: return (.east, true)
        case .northWest: return (.northEast, true)
        }
    }
}

/// The pure math behind the board's directional billboard content: which
/// canonical sprite direction a unit should display, given its own
/// world-fixed facing and the viewer's current azimuth around the board.
public enum TabletopDirectionalFrame {
    public struct Resolution: Equatable {
        public var canonical: WarcraftCanonicalFacing
        public var mirrored: Bool
        public var facing: WarcraftFacing
    }

    /// - Parameters:
    ///   - unitFacingRadians: The unit's true facing in board/world space
    ///     (0 = board north, increasing clockwise), independent of the
    ///     viewer.
    ///   - viewerAzimuthRadians: The viewer's azimuth around the board (0 =
    ///     north, clockwise), i.e. the angle from the board center to the
    ///     viewer's head position projected onto the board plane.
    public static func resolve(unitFacingRadians: Double, viewerAzimuthRadians: Double) -> Resolution {
        let relative = unitFacingRadians - viewerAzimuthRadians
        let facing = WarcraftFacing.nearest(toRadians: relative)
        let (canonical, mirrored) = WarcraftCanonicalFacing.resolve(facing)
        return Resolution(canonical: canonical, mirrored: mirrored, facing: facing)
    }
}

/// The pure math behind orienting a billboard's own quad so it always faces
/// the viewer while rotating strictly around the board's vertical normal
/// (units stay upright; they never tilt or roll).
public enum TabletopBillboardOrientation {
    /// Yaw (radians, 0 = board north, increasing clockwise) the billboard
    /// should use so its face turns toward the viewer.
    public static func yawFacingViewer(unitBoardPosition: TabletopPoint3D, viewerBoardPosition: TabletopPoint3D) -> Double {
        let dx = viewerBoardPosition.x - unitBoardPosition.x
        let dz = viewerBoardPosition.z - unitBoardPosition.z
        if dx == 0 && dz == 0 {
            return 0
        }
        // atan2(dx, dz) so 0 radians = north (+Z), increasing clockwise,
        // matching WarcraftFacing's convention.
        return atan2(dx, dz)
    }
}

/// The viewer's azimuth around the board center, expressed with the same
/// convention `TabletopDirectionalFrame` and `WarcraftFacing` use.
public enum TabletopViewerAzimuth {
    public static func aroundBoardCenter(viewerBoardPosition: TabletopPoint3D, boardCenter: TabletopPoint3D = .zero) -> Double {
        TabletopBillboardOrientation.yawFacingViewer(unitBoardPosition: boardCenter, viewerBoardPosition: viewerBoardPosition)
    }
}

/// The pure alpha math behind a unit billboard's appearance. The per-frame
/// directional-frame update (which re-tints the quad to the resolved
/// canonical hue) and the right-hand selection highlight (which dims/
/// brightens that same quad, and the cylindrical body) both need to compose
/// into a single material rather than each independently overwriting the
/// other -- otherwise whichever one last touched the material wins and the
/// other's visual state silently disappears. Centralizing the alpha
/// resolution here keeps it framework-independent and unit testable, and
/// keeps the two call sites (selection changes, once per frame) from ever
/// fighting over the same material again.
public enum TabletopUnitAppearance: Equatable {
    public static let quadSelectedAlpha: Double = 1.0
    public static let quadDeselectedAlpha: Double = 0.22

    public static let bodySelectedAlpha: Double = 0.5
    public static let bodyDeselectedAlpha: Double = 0.22

    /// Alpha for the small directional-facing quad, given only the current
    /// selection state -- independent of, and composable with, whatever
    /// canonical hue the current directional-frame resolution has picked.
    public static func quadAlpha(selected: Bool) -> Double {
        selected ? quadSelectedAlpha : quadDeselectedAlpha
    }

    /// Alpha for the translucent cylindrical body, given only the current
    /// selection state.
    public static func bodyAlpha(selected: Bool) -> Double {
        selected ? bodySelectedAlpha : bodyDeselectedAlpha
    }
}
