import Foundation

enum TabletopHand: Int, Comparable, Sendable {
    case left
    case right

    static func < (lhs: TabletopHand, rhs: TabletopHand) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum TabletopPinchPhase: Sendable {
    case active
    case ended
    case cancelled
}

struct TabletopPoint: Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    func distance(to other: TabletopPoint) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        let dz = z - other.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}

struct TabletopPinchEvent: Sendable {
    var hand: TabletopHand
    var phase: TabletopPinchPhase
    var point: TabletopPoint
}

struct TabletopBoardPose: Equatable, Sendable {
    var x: Double = 0
    var z: Double = 0
    var scale: Double = 1
}

enum TabletopIntent: Equatable, Sendable {
    case commandSelect(TabletopPoint)
    case boardPoseChanged(TabletopBoardPose)
}

struct TabletopGestureState {
    private struct ActivePinch {
        var point: TabletopPoint
        var anchorPoint: TabletopPoint
        var anchorPose: TabletopBoardPose
    }

    private struct ScaleBaseline {
        var distance: Double
        var scale: Double
    }

    private(set) var boardPose = TabletopBoardPose()
    private var activePinches: [TabletopHand: ActivePinch] = [:]
    private var scaleBaseline: ScaleBaseline?

    var activeHandCount: Int {
        activePinches.count
    }

    var activeHandsDescription: String {
        switch (activePinches[.left] != nil, activePinches[.right] != nil) {
        case (true, true): "Two-hand scale"
        case (true, false): "Left-hand board move"
        case (false, true): "Right-hand command"
        case (false, false): "Ready"
        }
    }

    mutating func process(_ event: TabletopPinchEvent) -> [TabletopIntent] {
        switch event.phase {
        case .active:
            return processActive(event)
        case .ended, .cancelled:
            finish(event.hand)
            return []
        }
    }

    mutating func recenter() {
        boardPose = TabletopBoardPose()
        activePinches.removeAll()
        scaleBaseline = nil
    }

    private mutating func processActive(
        _ event: TabletopPinchEvent
    ) -> [TabletopIntent] {
        let isNewPinch = activePinches[event.hand] == nil
        if var active = activePinches[event.hand] {
            active.point = event.point
            activePinches[event.hand] = active
        } else {
            activePinches[event.hand] = ActivePinch(
                point: event.point,
                anchorPoint: event.point,
                anchorPose: boardPose
            )
        }

        var intents: [TabletopIntent] = []
        if event.hand == .right && isNewPinch {
            intents.append(.commandSelect(event.point))
        }

        let previousPose = boardPose
        updateLeftHandTranslation()
        updateTwoHandScale()
        if boardPose != previousPose {
            intents.append(.boardPoseChanged(boardPose))
        }
        return intents
    }

    private mutating func updateLeftHandTranslation() {
        guard let left = activePinches[.left] else {
            return
        }

        // SwiftUI spatial coordinates are points; convert their delta to meters.
        let pointsToMeters = 0.001
        boardPose.x = left.anchorPose.x
            + (left.point.x - left.anchorPoint.x) * pointsToMeters
        boardPose.z = left.anchorPose.z
            + (left.point.z - left.anchorPoint.z) * pointsToMeters
    }

    private mutating func updateTwoHandScale() {
        guard let left = activePinches[.left],
              let right = activePinches[.right] else {
            scaleBaseline = nil
            return
        }

        let distance = left.point.distance(to: right.point)
        if scaleBaseline == nil {
            scaleBaseline = ScaleBaseline(
                distance: max(distance, 0.001),
                scale: boardPose.scale
            )
        }
        guard let baseline = scaleBaseline else {
            return
        }

        let scaled = baseline.scale * distance / baseline.distance
        boardPose.scale = min(max(scaled, 0.55), 1.8)
    }

    private mutating func finish(_ hand: TabletopHand) {
        activePinches.removeValue(forKey: hand)
        scaleBaseline = nil

        // Rebase the remaining left pinch so ending a two-hand scale cannot jump.
        if var left = activePinches[.left] {
            left.anchorPoint = left.point
            left.anchorPose = boardPose
            activePinches[.left] = left
        }
    }
}
