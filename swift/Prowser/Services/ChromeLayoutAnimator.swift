import Foundation

/// Animated chrome layout snapshot (sidebar widths + status bar height).
struct ChromeLayoutSnapshot: Equatable {
    var leftWidth: CGFloat
    var rightWidth: CGFloat
    var statusBarHeight: CGFloat

    static func lerp(_ from: ChromeLayoutSnapshot, _ to: ChromeLayoutSnapshot, _ t: CGFloat) -> ChromeLayoutSnapshot {
        ChromeLayoutSnapshot(
            leftWidth: from.leftWidth + (to.leftWidth - from.leftWidth) * t,
            rightWidth: from.rightWidth + (to.rightWidth - from.rightWidth) * t,
            statusBarHeight: from.statusBarHeight + (to.statusBarHeight - from.statusBarHeight) * t
        )
    }
}

/// 250ms ease-out cubic layout animation (Python `STATUS_BAR_ANIM_MS` / `OutCubic`).
@MainActor
enum ChromeLayoutAnimator {
    static let statusBarHeight: CGFloat = 24
    static let duration: TimeInterval = 0.25

    private static var activeTimer: Timer?

    static func stop() {
        activeTimer?.invalidate()
        activeTimer = nil
    }

    static func animate(
        from: ChromeLayoutSnapshot,
        to: ChromeLayoutSnapshot,
        onUpdate: @escaping (ChromeLayoutSnapshot) -> Void,
        onComplete: @escaping () -> Void
    ) {
        stop()
        let start = Date()
        activeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            Task { @MainActor in
                let elapsed = Date().timeIntervalSince(start)
                let t = min(1, elapsed / duration)
                let eased = 1 - pow(1 - t, 3)
                let current = ChromeLayoutSnapshot.lerp(from, to, eased)
                onUpdate(current)
                if t >= 1 {
                    activeTimer?.invalidate()
                    activeTimer = nil
                    onComplete()
                }
            }
        }
    }
}
