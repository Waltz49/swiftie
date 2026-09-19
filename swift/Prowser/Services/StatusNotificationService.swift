import Foundation
import SwiftUI

struct StatusBubble: Identifiable, Equatable {
    let id = UUID()
    let message: String
    var opacity: Double = 0
}

/// Floating notification bubbles above the status bar. Port of `status_notification.py`.
@Observable
@MainActor
final class StatusNotificationService {
    private(set) var bubbles: [StatusBubble] = []
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]
    private var lastShownMessage = ""

    func show(_ text: String, duration: TimeInterval = 3.0, alwaysShow: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !alwaysShow && trimmed == lastShownMessage { return }
        lastShownMessage = trimmed
        addBubble(trimmed, duration: duration)
    }

    func showFileOperation(_ text: String, duration: TimeInterval = 3.0) {
        show(text, duration: duration, alwaysShow: true)
    }

    func clear() {
        dismissTasks.values.forEach { $0.cancel() }
        dismissTasks.removeAll()
        bubbles.removeAll()
        lastShownMessage = ""
    }

    private func addBubble(_ message: String, duration: TimeInterval) {
        let bubble = StatusBubble(message: message, opacity: 0)
        bubbles.append(bubble)

        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.25)) {
                setBubbleOpacity(id: bubble.id, opacity: 0.9)
            }
        }

        let dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await fadeOutAndRemove(bubble.id)
        }
        dismissTasks[bubble.id] = dismissTask
    }

    /// Reassign `bubbles` so `@Observable` publishes (in-place struct mutation does not refresh SwiftUI).
    private func setBubbleOpacity(id: UUID, opacity: Double) {
        guard let index = bubbles.firstIndex(where: { $0.id == id }) else { return }
        var next = bubbles
        next[index].opacity = opacity
        bubbles = next
    }

    private func fadeOutAndRemove(_ id: UUID) async {
        withAnimation(.easeInOut(duration: 0.35)) {
            setBubbleOpacity(id: id, opacity: 0)
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        bubbles.removeAll { $0.id == id }
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
    }
}
