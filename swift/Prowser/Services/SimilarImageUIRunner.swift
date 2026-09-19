import AppKit
import Foundation

/// Progress UI for pixel-MSE similar-image grouping (port of `_run_similar_image_group_pairs_ui`).
@MainActor
enum SimilarImageUIRunner {
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
        title: String = "Find Similar Image Files",
        paths: [String]
    ) async -> (pairs: [SimilarImageGroupPairsBuilder.GroupPair], cancelled: Bool) {
        let n = paths.count
        guard n > 0 else { return ([], false) }

        let cancelFlag = CancelFlag()
        let progress = CancellableProgressPanelController(
            title: title,
            labelText: "Analyzing images...",
            maximum: max(1, n)
        )
        progress.show()

        let pathsCopy = paths
        let useWorker = n >= SimilarImageGroupPairsBuilder.workerThreadMinPaths

        let result: ([SimilarImageGroupPairsBuilder.GroupPair], Bool) = await Task.detached {
            let shouldCancel: @Sendable () -> Bool = { cancelFlag.isCancelled() }
            let progressHandler: SimilarImageGroupPairsBuilder.ProgressHandler = { value, maximum, text in
                Task { @MainActor in
                    if progress.cancelRequested {
                        cancelFlag.cancel()
                    }
                    if useWorker, value == -1, maximum == -1 {
                        return
                    }
                    progress.setMaximum(maximum)
                    progress.update(value: min(value, maximum), label: text.isEmpty ? nil : text)
                }
            }
            let tick: SimilarImageGroupPairsBuilder.TickHandler = {
                if useWorker {
                    progressHandler(-1, -1, "")
                }
            }

            let built = SimilarImageGroupPairsBuilder.buildGroupPairs(
                imagePaths: pathsCopy,
                shouldCancel: shouldCancel,
                progress: progressHandler,
                progressTick: tick
            )
            let pairs = built.pairs.map { (groupKey: $0.groupKey, path: $0.path) }
            return (pairs, built.cancelled)
        }.value

        if progress.cancelRequested {
            cancelFlag.cancel()
        }
        progress.close()

        if result.1 || cancelFlag.isCancelled() {
            return ([], true)
        }
        return (result.0, false)
    }
}
