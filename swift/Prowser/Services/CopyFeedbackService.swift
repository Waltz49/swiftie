import Foundation

/// Brief “✓ Copied!” toast (Python `copy_feedback.py`).
@Observable
@MainActor
final class CopyFeedbackService {
    private(set) var isVisible = false
    private var hideTask: Task<Void, Never>?

    func show(duration: TimeInterval = 1.5) {
        hideTask?.cancel()
        isVisible = true
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }
}
