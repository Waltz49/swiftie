import AppKit
import Foundation

/// Progress UI for pixel-MSE similar-image grouping (port of `_run_similar_image_group_pairs_ui`).
@MainActor
enum SimilarImageUIRunner {
    private static let longBucketSeconds: TimeInterval = 10
    private static let minimumNoteDisplaySeconds: TimeInterval = 3
    private static let stallCheckInterval: TimeInterval = 0.5

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

    @MainActor
    private final class LongCompareNoteMonitor {
        private weak var progress: CancellableProgressPanelController?
        private var compareBucketStart: Date?
        private var noteShownAt: Date?
        private var noteLatched = false
        private var timer: Timer?
        private var pendingHideWorkItem: DispatchWorkItem?

        func bind(progress: CancellableProgressPanelController) {
            self.progress = progress
        }

        func handleProgressLabel(_ text: String) {
            guard text.hasPrefix("Comparing similar images") else { return }
            compareBucketStart = Date()
            noteLatched = false
            scheduleHideNoteRespectingMinimumDisplay()
            startTimerIfNeeded()
        }

        func stop() {
            cancelPendingHide()
            timer?.invalidate()
            timer = nil
            compareBucketStart = nil
            noteShownAt = nil
        }

        private func startTimerIfNeeded() {
            guard timer == nil else { return }
            let target = StallCheckTarget()
            target.monitor = self
            let timer = Timer(
                timeInterval: SimilarImageUIRunner.stallCheckInterval,
                target: target,
                selector: #selector(StallCheckTarget.tick),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        fileprivate func tick() {
            guard !noteLatched, let start = compareBucketStart else { return }
            guard Date().timeIntervalSince(start) >= SimilarImageUIRunner.longBucketSeconds else { return }
            noteLatched = true
            cancelPendingHide()
            noteShownAt = Date()
            progress?.setLongCompareNoteVisible(true)
        }

        private func scheduleHideNoteRespectingMinimumDisplay() {
            cancelPendingHide()
            guard let shownAt = noteShownAt else {
                progress?.setLongCompareNoteVisible(false)
                return
            }
            let elapsed = Date().timeIntervalSince(shownAt)
            let remaining = SimilarImageUIRunner.minimumNoteDisplaySeconds - elapsed
            if remaining <= 0 {
                hideNoteNow()
                return
            }
            let work = DispatchWorkItem { [weak self] in
                self?.hideNoteNow()
            }
            pendingHideWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
        }

        private func hideNoteNow() {
            pendingHideWorkItem = nil
            noteShownAt = nil
            progress?.setLongCompareNoteVisible(false)
        }

        private func cancelPendingHide() {
            pendingHideWorkItem?.cancel()
            pendingHideWorkItem = nil
        }
    }

    private final class StallCheckTarget: NSObject {
        weak var monitor: LongCompareNoteMonitor?

        @MainActor @objc func tick() {
            monitor?.tick()
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
            maximum: max(1, n),
            showsLongCompareNoteLine: true,
            showsBucketProgressLine: true
        )
        let noteMonitor = LongCompareNoteMonitor()
        noteMonitor.bind(progress: progress)
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
                    if !text.isEmpty {
                        if text.hasPrefix("Comparing similar images") {
                            progress.setBucketProgressHidden(false)
                        } else {
                            progress.setBucketProgressHidden(true)
                        }
                        noteMonitor.handleProgressLabel(text)
                    }
                }
            }
            let bucketProgressHandler: SimilarImageGroupPairsBuilder.BucketProgressHandler = { value, maximum in
                Task { @MainActor in
                    progress.updateBucket(value: value, maximum: maximum)
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
                bucketProgress: bucketProgressHandler,
                progressTick: tick
            )
            let pairs = built.pairs.map { (groupKey: $0.groupKey, path: $0.path) }
            return (pairs, built.cancelled)
        }.value

        noteMonitor.stop()
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
