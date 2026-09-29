import CoreGraphics
import Foundation

enum SlideshowTransitionMath {
    struct EntryVectors {
        let incomingStart: CGSize
        let outgoingEnd: CGSize
    }

    static func entryVectors(direction: String, containerSize: CGSize) -> EntryVectors {
        let w = max(containerSize.width, 1)
        let h = max(containerSize.height, 1)

        switch direction {
        case "left":
            return EntryVectors(
                incomingStart: CGSize(width: -w, height: 0),
                outgoingEnd: CGSize(width: w, height: 0)
            )
        case "right":
            return EntryVectors(
                incomingStart: CGSize(width: w, height: 0),
                outgoingEnd: CGSize(width: -w, height: 0)
            )
        case "top":
            return EntryVectors(
                incomingStart: CGSize(width: 0, height: -h),
                outgoingEnd: CGSize(width: 0, height: h)
            )
        case "bottom":
            return EntryVectors(
                incomingStart: CGSize(width: 0, height: h),
                outgoingEnd: CGSize(width: 0, height: -h)
            )
        case "random":
            let angle = Double.random(in: 0 ..< (2 * Double.pi))
            let dx = cos(angle)
            let dy = sin(angle)
            return EntryVectors(
                incomingStart: CGSize(width: dx * w, height: dy * h),
                outgoingEnd: CGSize(width: -dx * w, height: -dy * h)
            )
        default:
            return EntryVectors(
                incomingStart: CGSize(width: w, height: 0),
                outgoingEnd: CGSize(width: -w, height: 0)
            )
        }
    }

    static func resolvedDirection(_ raw: String) -> String {
        if raw == "random" {
            return ["left", "right", "top", "bottom"].randomElement() ?? "right"
        }
        return raw
    }

    /// Random entry uses a free angle; orthogonals use `entryVectors`.
    static func entryVectorsForTransition(direction raw: String, containerSize: CGSize) -> (vectors: EntryVectors, isOpacityOnly: Bool) {
        if raw == "none" {
            return (EntryVectors(incomingStart: .zero, outgoingEnd: .zero), true)
        }
        if raw == "random" {
            return (entryVectors(direction: "random", containerSize: containerSize), false)
        }
        let resolved = resolvedDirection(raw)
        return (entryVectors(direction: resolved, containerSize: containerSize), false)
    }

    static func rotationPair(maxRotation: Int) -> (outgoingEnd: Double, incomingStart: Double) {
        guard maxRotation != 0 else { return (0, 0) }

        let minRotation = max(5, maxRotation / 10)

        func randomAngle() -> Int {
            let base: Int
            if Double.random(in: 0 ..< 1) < 0.7 {
                base = Int.random(in: minRotation ... maxRotation)
            } else {
                let moderateMax = max(minRotation, Int(Double(maxRotation) * 0.6))
                base = Int.random(in: minRotation ... moderateMax)
            }
            return max(base, minRotation)
        }

        var current = randomAngle()
        var next = randomAngle()
        if abs(current - next) < minRotation {
            if Bool.random() {
                next = current + Int.random(in: minRotation ... (minRotation * 2))
            } else {
                next = current - Int.random(in: minRotation ... (minRotation * 2))
            }
        }
        if Bool.random() { current = -current }
        if Bool.random() { next = -next }

        func clampSignificant(_ value: Int) -> Double {
            let v = abs(value) < minRotation ? (value >= 0 ? minRotation : -minRotation) : value
            return Double(v)
        }

        return (clampSignificant(current), clampSignificant(next))
    }

    static func overlapIncomingProgress(
        linearProgress: Double,
        overlapDelayMs: Int,
        duration: TimeInterval
    ) -> Double {
        guard duration > 0 else { return 1 }
        let delay = Double(overlapDelayMs) / 1000.0
        if overlapDelayMs > 0 {
            let cappedDelay = min(delay, duration * 0.5)
            let elapsed = linearProgress * duration
            if elapsed <= cappedDelay { return 0 }
            let remain = max(0.001, duration - cappedDelay)
            return min(1, (elapsed - cappedDelay) / remain)
        }
        if overlapDelayMs < 0 {
            let early = min(abs(delay), duration * 0.3)
            let elapsed = linearProgress * duration
            if elapsed <= early {
                return min(1, elapsed / max(0.001, early))
            }
            return 1
        }
        return linearProgress
    }

    static func overlapOutgoingProgress(
        linearProgress: Double,
        overlapDelayMs: Int,
        duration: TimeInterval
    ) -> Double {
        guard duration > 0 else { return 1 }
        let delay = Double(overlapDelayMs) / 1000.0
        if overlapDelayMs < 0 {
            let cappedDelay = min(abs(delay), duration * 0.3)
            let elapsed = linearProgress * duration
            if elapsed <= cappedDelay { return 0 }
            let remain = max(0.001, duration - cappedDelay)
            return min(1, (elapsed - cappedDelay) / remain)
        }
        return linearProgress
    }

    static func easeInQuad(_ t: Double) -> Double { t * t }
    static func easeOutQuad(_ t: Double) -> Double { t * (2 - t) }
    static func easeInCubic(_ t: Double) -> Double { t * t * t }

    static func outgoingOpacityDirectional(positionProgress: Double) -> Double {
        if positionProgress < 0.4 { return 1 }
        let fadeT = (positionProgress - 0.4) / 0.6
        return 1 - easeInCubic(fadeT)
    }

    static func lerpSize(_ from: CGSize, _ to: CGSize, t: Double) -> CGSize {
        CGSize(
            width: from.width + (to.width - from.width) * t,
            height: from.height + (to.height - from.height) * t
        )
    }
}
