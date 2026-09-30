import AppKit
import Foundation

/// Progress UI for MD5 duplicate hashing (port of `run_duplicate_hash_ui`).
@MainActor
enum DuplicateHashUIRunner {
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        func isCancelled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }

    static func run(
        title: String = "Find Duplicate Image Files",
        paths: [String]
    ) async -> (groups: DuplicateHashService.HashGroups?, cancelled: Bool) {
        let count = paths.count
        guard count > 0 else {
            return (DuplicateHashService.HashGroups(hashToFiles: [:], fileToHash: [:]), false)
        }

        let cancelFlag = CancelFlag()
        let progress = CancellableProgressPanelController(
            title: title,
            labelText: "Preparing…",
            maximum: max(1, count),
            showsTimeRemainingEstimate: true
        )
        progress.show()

        let pathsCopy = paths
        let result: (DuplicateHashService.HashGroups, Bool) = await Task.detached {
            DuplicateHashService.buildHashGroups(
                filePaths: pathsCopy,
                shouldCancel: { cancelFlag.isCancelled() },
                progress: { value, maximum, text in
                    Task { @MainActor in
                        if progress.cancelRequested {
                            cancelFlag.cancel()
                        }
                        progress.setMaximum(maximum)
                        progress.update(value: min(value, maximum), label: text.isEmpty ? nil : text)
                    }
                }
            )
        }.value

        if progress.cancelRequested {
            cancelFlag.cancel()
        }
        progress.close()

        if result.1 || cancelFlag.isCancelled() {
            return (nil, true)
        }
        return (result.0, false)
    }
}
