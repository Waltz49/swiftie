import AppKit
import Foundation
import Observation

/// Idle CLIP/CNN cache warming for favorites, recent, and current directory (in-process).
@Observable
@MainActor
final class BackgroundImageRecognitionController {
    private weak var appState: AppState?
    private var schedulerTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private var lastUserActivity = Date()
    private var monitor: Any?
    private var eventBag: EventBusSubscriptionBag?

    private var priorityDirectory: String?
    private var cyclePhase: CyclePhase = .clip
    private var foregroundSuspendDepth = 0
    private var batchGeneration = 0

    private(set) var isProcessing = false

    private enum CyclePhase {
        case clip
        case cnn
    }

    func bind(_ appState: AppState) {
        self.appState = appState
        installActivityMonitor()
        let bag = EventBusSubscriptionBag(bus: appState.eventBus)
        bag.subscribe(.directoryChanged) { [weak self] event in
            guard let self, case .string(let path) = event.payload else { return }
            self.notePriorityDirectory(path)
        }
        eventBag = bag

        applyEnabledFromSettings()
    }

    static func indexingAvailable(appState: AppState) -> Bool {
        ImageRecognitionPaths.backgroundIndexingAvailable(
            profile: appState.config.profilePaths,
            config: appState.config
        )
    }

    var isIndexingEnabled: Bool {
        guard let appState else { return false }
        return appState.config.bool(forKey: "background_clip_enabled", default: false)
    }

    /// Status bar prefix (Python `background_indicator`).
    func fileCountIndicatorPrefix() -> String {
        guard let appState, Self.indexingAvailable(appState: appState) else { return "" }
        guard isIndexingEnabled else { return "" }
        if isProcessing { return "● " }
        return "○ "
    }

    func applyEnabledFromSettings() {
        guard let appState else { return }
        let wantsOn = appState.config.bool(forKey: "background_clip_enabled", default: false)
        if wantsOn, Self.indexingAvailable(appState: appState) {
            startSchedulerIfNeeded()
        } else {
            stopAll()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard let appState else { return }
        appState.config.updateSetting("background_clip_enabled", value: enabled)
        applyEnabledFromSettings()
        appState.eventBus.emit(.backgroundIndexingStateChanged)
    }

    func notePriorityDirectory(_ path: String) {
        priorityDirectory = path
        cancelBatch()
        cyclePhase = .clip
    }

    /// Call when CLIP/ResNet settings change or models are installed (rebinds feature cache + restarts idle cycles).
    func noteSearchModelsChanged() {
        cancelBatch()
        cyclePhase = .clip
        applyEnabledFromSettings()
        appState?.eventBus.emit(.backgroundIndexingStateChanged)
    }

    func suspendForForegroundSearch() {
        foregroundSuspendDepth += 1
        cancelBatch()
    }

    func resumeAfterForegroundSearch() {
        foregroundSuspendDepth = max(0, foregroundSuspendDepth - 1)
    }

    private func installActivityMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        ) { [weak self] event in
            self?.noteUserActivity()
            return event
        }
    }

    private func noteUserActivity() {
        lastUserActivity = Date()
        cancelBatch()
    }

    private func startSchedulerIfNeeded() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self?.schedulerTick()
            }
        }
    }

    private func stopAll() {
        cancelBatch()
        schedulerTask?.cancel()
        schedulerTask = nil
    }

    private func cancelBatch() {
        batchGeneration += 1
        batchTask?.cancel()
        batchTask = nil
        setProcessing(false)
    }

    private func setProcessing(_ processing: Bool) {
        guard isProcessing != processing else { return }
        isProcessing = processing
        appState?.eventBus.emit(.backgroundIndexingStateChanged)
    }

    private func isIdle() -> Bool {
        Date().timeIntervalSince(lastUserActivity) >= TimingConstants.backgroundClipIdleSeconds
    }

    private func schedulerTick() async {
        guard let appState else { return }
        guard appState.config.bool(forKey: "background_clip_enabled", default: false) else {
            stopAll()
            return
        }
        guard Self.indexingAvailable(appState: appState) else {
            stopAll()
            return
        }
        guard foregroundSuspendDepth == 0 else { return }
        guard batchTask == nil else { return }
        guard isIdle() else { return }

        let directories = targetDirectories(appState: appState)
        guard !directories.isEmpty else { return }

        guard let batch = collectBatch(appState: appState, directories: directories) else {
            flipCyclePhase()
            return
        }

        let generation = batchGeneration
        let phase = cyclePhase
        let paths = batch
        batchTask = Task { [weak self] in
            await self?.runBatch(appState: appState, paths: paths, phase: phase, generation: generation)
        }
    }

    private func flipCyclePhase() {
        switch cyclePhase {
        case .clip:
            cyclePhase = .cnn
        case .cnn:
            cyclePhase = .clip
        }
    }

    private func collectBatch(appState: AppState, directories: [String]) -> [String]? {
        let batchSize = TimingConstants.backgroundClipBatchSize
        var collected: [String] = []
        for directory in directories {
            if !isIdle() { break }
            let paths = DirectoryScanner.scanDirectory(
                at: directory,
                extensions: appState.config.imageExtensions,
                filterPattern: "*"
            )
            guard !paths.isEmpty else { continue }
            let needing: [String]
            switch cyclePhase {
            case .clip:
                needing = appState.imageRecognition.pathsNeedingCLIP(paths: paths, config: appState.config)
            case .cnn:
                needing = appState.imageRecognition.pathsNeedingCNN(paths: paths, config: appState.config)
            }
            for path in needing {
                collected.append(path)
                if collected.count >= batchSize { return collected }
            }
        }
        return collected.isEmpty ? nil : collected
    }

    private func runBatch(
        appState: AppState,
        paths: [String],
        phase: CyclePhase,
        generation: Int
    ) async {
        setProcessing(true)
        defer {
            if generation == batchGeneration {
                setProcessing(false)
                batchTask = nil
            }
        }

        let shouldCancel: () -> Bool = { [weak self] in
            guard let self else { return true }
            return generation != self.batchGeneration
                || self.foregroundSuspendDepth > 0
                || !self.isIdle()
                || Task.isCancelled
        }

        do {
            switch phase {
            case .clip:
                _ = try await appState.imageRecognition.clipImageFeatures(
                    for: paths,
                    config: appState.config,
                    progress: { _, _, _ in },
                    shouldCancel: shouldCancel,
                    allowDownloadPrompt: false
                )
            case .cnn:
                _ = try await appState.imageRecognition.cnnFeatures(
                    for: paths,
                    config: appState.config,
                    progress: { _, _, _ in },
                    shouldCancel: shouldCancel,
                    allowDownloadPrompt: false
                )
            }
        } catch {
            return
        }

        guard !shouldCancel() else { return }
        if appState.config.bool(forKey: "background_clip_gather_thumbnails", default: true) {
            for path in paths {
                if shouldCancel() { return }
                _ = await appState.thumbnailCache.generateThumbnail(
                    for: path,
                    size: 256,
                    priority: .background
                )
            }
        }
    }

    private func targetDirectories(appState: AppState) -> [String] {
        var directories: [String] = []
        if let priority = priorityDirectory,
           FileManager.default.fileExists(atPath: priority) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: priority, isDirectory: &isDir), isDir.boolValue {
                directories.append(priority)
            }
        } else if let current = appState.fileData.currentDirectory,
                  FileManager.default.fileExists(atPath: current) {
            directories.append(current)
        }

        for optional in appState.config.favoriteDirectories() {
            guard let path = optional, !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else { continue }
            if !directories.contains(path) { directories.append(path) }
        }

        for path in appState.config.recentDirectories() {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            if !directories.contains(path) { directories.append(path) }
        }

        return directories
    }
}
