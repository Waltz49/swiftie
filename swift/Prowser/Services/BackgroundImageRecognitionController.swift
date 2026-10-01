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
    private var workKindRotation = 0
    private var foregroundSuspendDepth = 0
    private var batchGeneration = 0

    private(set) var isProcessing = false

    private enum BackgroundWorkKind {
        case thumbnail
        case clip
        case cnn
        case face

        var logKind: BackgroundIdleProcessingLogKind {
            switch self {
            case .thumbnail: return .thumbnails
            case .clip: return .clip
            case .cnn: return .cnn
            case .face: return .face
            }
        }
    }

    private static let backgroundGatherThumbnailSize = ThumbnailGridLayoutService.minThumbnailSize

    /// Round-robin offset so idle gather does not always retry the same scan prefix.
    private var thumbnailGatherScanOffset = 0
    private var faceGatherScanOffset = 0
    private var clipGatherScanOffset = 0
    private var cnnGatherScanOffset = 0
    private static let maxFaceScanPathsPerSchedulerTick = 800
    private static let maxThumbnailScanPathsPerSchedulerTick = 800
    private static let maxFeatureScanPathsPerSchedulerTick = 800
    private var idleScanPathList: [String] = []
    private var idleScanPathListKey: String?
    private var thumbnailDirectoryFullyWarm = false
    private var faceDirectoryFullyWarm = false
    private var clipDirectoryFullyWarm = false
    private var cnnDirectoryFullyWarm = false
    private var thumbnailPathsExaminedSinceFind = 0
    private var facePathsExaminedSinceFind = 0
    private var clipPathsExaminedSinceFind = 0
    private var cnnPathsExaminedSinceFind = 0
    private static let idleScanBackoffSeconds: UInt64 = 30
    private var lastIdleSkipLogTime: Date?
    private var pendingThumbnailBatchStartOffset = 0
    private var pendingThumbnailBatchPathCount = 0
    private var pendingFaceBatchStartOffset = 0
    private var pendingFaceBatchPathCount = 0

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

    private func isAnyBackgroundGatheringEnabled(appState: AppState) -> Bool {
        shouldRunBackgroundProcessing(appState: appState)
    }

    /// Status bar prefix (Python `background_indicator`).
    func fileCountIndicatorPrefix() -> String {
        guard let appState else { return "" }
        guard isAnyBackgroundGatheringEnabled(appState: appState) else { return "" }
        if isProcessing { return "● " }
        return "○ "
    }

    func applyEnabledFromSettings() {
        guard let appState else { return }
        if shouldRunBackgroundProcessing(appState: appState) {
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

    func setGatherThumbnails(_ enabled: Bool) {
        guard let appState else { return }
        appState.config.updateSetting("background_clip_gather_thumbnails", value: enabled)
        applyEnabledFromSettings()
        appState.thumbnailGridHost?.startBackgroundThumbnailLoadingIfNeeded()
    }

    func setExtractFaces(_ enabled: Bool) {
        guard let appState else { return }
        appState.config.updateSetting("background_clip_extract_faces", value: enabled)
        applyEnabledFromSettings()
        appState.eventBus.emit(.backgroundIndexingStateChanged)
    }

    private func shouldRunBackgroundProcessing(appState: AppState) -> Bool {
        if gatherThumbnailsActive(appState: appState) { return true }
        if clipIndexingActive(appState: appState) { return true }
        if faceIndexingActive(appState: appState) { return true }
        return false
    }

    private func clipIndexingActive(appState: AppState) -> Bool {
        appState.config.bool(forKey: "background_clip_enabled", default: false)
            && Self.indexingAvailable(appState: appState)
    }

    private func gatherThumbnailsActive(appState: AppState) -> Bool {
        appState.config.bool(forKey: "background_clip_gather_thumbnails", default: true)
    }

    private func faceIndexingActive(appState: AppState) -> Bool {
        guard FaceRecognitionCapabilities.facesUIEnabled(launchOptions: appState.launchOptions) else {
            return false
        }
        guard appState.config.bool(forKey: "background_clip_extract_faces", default: false) else {
            return false
        }
        return FaceRecognitionCapabilities.faceFeaturesAvailable(profile: appState.config.profilePaths)
    }

    private func enabledWorkKinds(appState: AppState) -> [BackgroundWorkKind] {
        var kinds: [BackgroundWorkKind] = []
        if gatherThumbnailsActive(appState: appState) { kinds.append(.thumbnail) }
        if clipIndexingActive(appState: appState) {
            kinds.append(.clip)
            kinds.append(.cnn)
        }
        if faceIndexingActive(appState: appState) { kinds.append(.face) }
        return kinds
    }

    func notePriorityDirectory(_ path: String) {
        priorityDirectory = path
        cancelBatch()
        workKindRotation = 0
        noteIdleScanScopeChanged()
    }

    /// Reset idle scan cursors when the on-disk image set changes without a full directory load.
    func noteIdleScanScopeChanged() {
        idleScanPathList = []
        idleScanPathListKey = nil
        thumbnailGatherScanOffset = 0
        faceGatherScanOffset = 0
        clipGatherScanOffset = 0
        cnnGatherScanOffset = 0
        resetIdleWarmScanState()
    }

    /// Thumbnail disk/memory invalidation for specific paths — do not reset scan cursors.
    func noteThumbnailDiskCacheInvalidated() {
        thumbnailDirectoryFullyWarm = false
        thumbnailPathsExaminedSinceFind = 0
    }

    private func resetIdleWarmScanState() {
        thumbnailDirectoryFullyWarm = false
        faceDirectoryFullyWarm = false
        clipDirectoryFullyWarm = false
        cnnDirectoryFullyWarm = false
        thumbnailPathsExaminedSinceFind = 0
        facePathsExaminedSinceFind = 0
        clipPathsExaminedSinceFind = 0
        cnnPathsExaminedSinceFind = 0
    }

    /// Call when CLIP/ResNet settings change or models are installed (rebinds feature cache + restarts idle cycles).
    func noteSearchModelsChanged() {
        cancelBatch()
        workKindRotation = 0
        noteIdleScanScopeChanged()
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

    /// Match Python `IdleDetector.eventFilter` (key/mouse press only — not scroll).
    private func installActivityMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
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
        if let appState {
            BackgroundIdleProcessingLog.logEvent(
                logFileURL: appState.sessionViewLogURL,
                "Background - Scheduler started"
            )
        }
        schedulerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.schedulerTick()
                let delay: UInt64
                if self?.shouldBackoffIdleScheduler() == true {
                    delay = Self.idleScanBackoffSeconds * 1_000_000_000
                } else {
                    delay = 1_000_000_000
                }
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private func shouldBackoffIdleScheduler() -> Bool {
        guard let appState else { return false }
        if batchTask != nil || isProcessing { return false }
        if clipIndexingActive(appState: appState) {
            if !clipDirectoryFullyWarm || !cnnDirectoryFullyWarm { return false }
        }
        if gatherThumbnailsActive(appState: appState), !thumbnailDirectoryFullyWarm { return false }
        if faceIndexingActive(appState: appState), !faceDirectoryFullyWarm { return false }
        if !gatherThumbnailsActive(appState: appState),
           !faceIndexingActive(appState: appState),
           !clipIndexingActive(appState: appState) {
            return false
        }
        return true
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

    private func idleBackgroundDuration() -> TimeInterval {
        Date().timeIntervalSince(lastUserActivity)
    }

    private func idleBackgroundBatchSize() -> Int {
        if idleBackgroundDuration() >= TimingConstants.backgroundClipExtendedIdleSeconds {
            return TimingConstants.backgroundClipExtendedIdleBatchSize
        }
        return TimingConstants.backgroundClipBatchSize
    }

    private func schedulerTick() async {
        guard let appState else { return }
        guard shouldRunBackgroundProcessing(appState: appState) else {
            stopAll()
            return
        }
        let directories = targetDirectories(appState: appState)

        guard foregroundSuspendDepth == 0 else {
            await maybeLogIdleSkip(
                appState: appState,
                directories: directories,
                reason: "foreground search active"
            )
            return
        }
        guard batchTask == nil else { return }
        guard isIdle() else {
            await maybeLogIdleSkip(
                appState: appState,
                directories: directories,
                reason: "waiting for user idle (\(Int(TimingConstants.backgroundClipIdleSeconds))s)"
            )
            return
        }

        guard !directories.isEmpty else {
            await maybeLogIdleSkip(
                appState: appState,
                directories: directories,
                reason: "no target directories"
            )
            return
        }

        let kinds = enabledWorkKinds(appState: appState)
        guard !kinds.isEmpty else { return }

        let generation = batchGeneration

        for offset in 0..<kinds.count {
            let kind = kinds[(workKindRotation + offset) % kinds.count]
            switch kind {
            case .thumbnail:
                guard let batch = await collectThumbnailBatch(appState: appState, directories: directories) else {
                    continue
                }
                workKindRotation = (workKindRotation + offset + 1) % kinds.count
                let logKind = kind.logKind
                batchTask = Task { @MainActor [weak self] in
                    await self?.runThumbnailBatch(
                        appState: appState,
                        paths: batch,
                        logKind: logKind,
                        generation: generation
                    )
                }
                return
            case .clip, .cnn:
                guard let batch = collectFeatureBatch(
                    appState: appState,
                    directories: directories,
                    kind: kind
                ) else {
                    continue
                }
                workKindRotation = (workKindRotation + offset + 1) % kinds.count
                let logKind = kind.logKind
                batchTask = Task { @MainActor [weak self] in
                    await self?.runFeatureBatch(
                        appState: appState,
                        paths: batch,
                        logKind: logKind,
                        generation: generation
                    )
                }
                return
            case .face:
                guard let batch = collectFaceBatch(appState: appState, directories: directories) else {
                    continue
                }
                workKindRotation = (workKindRotation + offset + 1) % kinds.count
                let logKind = kind.logKind
                batchTask = Task { @MainActor [weak self] in
                    await self?.runFaceBatch(
                        appState: appState,
                        paths: batch,
                        logKind: logKind,
                        generation: generation
                    )
                }
                return
            }
        }

        workKindRotation = (workKindRotation + 1) % kinds.count
        let skipDetail = await idleSkipDetail(appState: appState, directories: directories)
        await maybeLogIdleSkip(
            appState: appState,
            directories: directories,
            reason: skipDetail.summary,
            imagePaths: skipDetail.imagePaths
        )
    }

    private struct IdleSkipDetail {
        let summary: String
        let imagePaths: [String]
    }

    private func idleSkipDetail(appState: AppState, directories: [String]) async -> IdleSkipDetail {
        let folderCount = directories.count
        var detail = "no uncached work in scan scope (\(folderCount) folders)"
        let paths = cachedIdleScanPaths(appState: appState, directories: directories)
        guard !paths.isEmpty else {
            return IdleSkipDetail(summary: detail + "; 0 image paths in scope", imagePaths: [])
        }
        detail += "; \(paths.count) image paths (scan cursor \(thumbnailGatherScanOffset % paths.count)/\(paths.count))"
        if gatherThumbnailsActive(appState: appState), thumbnailDirectoryFullyWarm {
            detail += "; thumbnail scan marked fully warm"
        }
        return IdleSkipDetail(summary: detail, imagePaths: paths)
    }

    private func maybeLogIdleSkip(
        appState: AppState,
        directories: [String],
        reason: String,
        imagePaths: [String]? = nil
    ) async {
        guard appState.config.bool(forKey: "debug_mode") else { return }
        let now = Date()
        if let lastIdleSkipLogTime, now.timeIntervalSince(lastIdleSkipLogTime) < 30 {
            return
        }
        lastIdleSkipLogTime = now
        BackgroundIdleProcessingLog.logEvent(
            logFileURL: appState.sessionViewLogURL,
            "Background - Idle skip - \(reason)"
        )
        await logScanDirectoriesReport(
            appState: appState,
            directories: directories,
            imagePaths: imagePaths
        )
    }

    private func logScanDirectoriesReport(
        appState: AppState,
        directories: [String],
        imagePaths: [String]?
    ) async {
        guard appState.config.bool(forKey: "debug_mode") else { return }
        guard !directories.isEmpty else {
            BackgroundIdleProcessingLog.logEvent(
                logFileURL: appState.sessionViewLogURL,
                "Background - Scan scope — (no directories)"
            )
            return
        }

        let scanRoots = deduplicatedScanRoots(directories)
        BackgroundIdleProcessingLog.logEvent(
            logFileURL: appState.sessionViewLogURL,
            "Background - Scan scope — \(scanRoots.count) folders (includes subfolders depth \(TimingConstants.backgroundIdleScanSubfolderDepth)):"
        )

        let paths = imagePaths ?? cachedIdleScanPaths(appState: appState, directories: directories)
        let thumbSize = Self.backgroundGatherThumbnailSize
        let countThumbnails = gatherThumbnailsActive(appState: appState)
        let diskIndex = countThumbnails && !paths.isEmpty
            ? await appState.thumbnailCache.diskThumbnailIndex()
            : nil
        var totalMissing = 0

        for directory in scanRoots {
            let line: String
            if let diskIndex, countThumbnails {
                let dirPaths = pathsAssigned(toScanRoot: directory, from: paths, scanRoots: scanRoots)
                var missing = 0
                for path in dirPaths {
                    if await appState.thumbnailCache.isThumbnailSatisfiedOnDisk(
                        for: path,
                        size: thumbSize,
                        diskIndex: diskIndex
                    ) {
                        continue
                    }
                    missing += 1
                }
                totalMissing += missing
                line = "  \(directory) — \(dirPaths.count) images, \(missing) missing thumbs"
            } else if !paths.isEmpty {
                let dirPaths = pathsAssigned(toScanRoot: directory, from: paths, scanRoots: scanRoots)
                line = "  \(directory) — \(dirPaths.count) images"
            } else {
                line = "  \(directory)"
            }
            BackgroundIdleProcessingLog.logEvent(logFileURL: appState.sessionViewLogURL, line)
            if let diskIndex, countThumbnails {
                let dirPaths = pathsAssigned(toScanRoot: directory, from: paths, scanRoots: scanRoots)
                await logImmediateSubfolderBreakdown(
                    appState: appState,
                    root: directory,
                    dirPaths: dirPaths,
                    scanRoots: scanRoots,
                    thumbSize: thumbSize,
                    diskIndex: diskIndex
                )
            }
        }

        if totalMissing > 0 {
            thumbnailDirectoryFullyWarm = false
            thumbnailPathsExaminedSinceFind = 0
        }
    }

    private func deduplicatedScanRoots(_ directories: [String]) -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        for directory in directories {
            let norm = Self.standardizedDirectoryPath(directory)
            guard seen.insert(norm).inserted else { continue }
            roots.append(norm)
        }
        return roots
    }

    private func pathsAssigned(toScanRoot root: String, from paths: [String], scanRoots: [String]) -> [String] {
        let rootNorm = Self.standardizedDirectoryPath(root)
        return paths.filter { owningScanRoot(for: $0, scanRoots: scanRoots) == rootNorm }
    }

    private func owningScanRoot(for path: String, scanRoots: [String]) -> String? {
        let pathNorm = URL(fileURLWithPath: path).standardizedFileURL.path
        var best: String?
        var bestLength = -1
        for root in scanRoots {
            if pathNorm == root || pathNorm.hasPrefix(root + "/") {
                if root.count > bestLength {
                    best = root
                    bestLength = root.count
                }
            }
        }
        return best
    }

    private static func standardizedDirectoryPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Log `↳ /Volumes/MiscFS/bg` style lines when images live in subfolders of a scan root.
    private func logImmediateSubfolderBreakdown(
        appState: AppState,
        root: String,
        dirPaths: [String],
        scanRoots: [String],
        thumbSize: Int,
        diskIndex: ThumbnailCache.DiskThumbnailIndex
    ) async {
        guard appState.config.bool(forKey: "debug_mode") else { return }
        let rootNorm = Self.standardizedDirectoryPath(root)
        let prefix = rootNorm + "/"
        let explicitSubfolderRoots = Set(
            scanRoots.map { Self.standardizedDirectoryPath($0) }.filter { $0 != rootNorm && $0.hasPrefix(prefix) }
        )
        var groups: [String: [String]] = [:]
        for path in dirPaths {
            guard path.hasPrefix(prefix) else { continue }
            let remainder = String(path.dropFirst(prefix.count))
            guard let slash = remainder.firstIndex(of: "/") else { continue }
            let subName = String(remainder[..<slash])
            groups[subName, default: []].append(path)
        }
        for subName in groups.keys.sorted() {
            let subPaths = groups[subName] ?? []
            guard !subPaths.isEmpty else { continue }
            let subDir = rootNorm + "/" + subName
            if explicitSubfolderRoots.contains(subDir) { continue }
            var missing = 0
            for path in subPaths {
                if await appState.thumbnailCache.isThumbnailSatisfiedOnDisk(
                    for: path,
                    size: thumbSize,
                    diskIndex: diskIndex
                ) {
                    continue
                }
                missing += 1
            }
            guard missing > 0 else { continue }
            BackgroundIdleProcessingLog.logEvent(
                logFileURL: appState.sessionViewLogURL,
                "    ↳ \(subDir) — \(subPaths.count) images, \(missing) missing thumbs"
            )
        }
    }

    private func collectThumbnailBatch(appState: AppState, directories: [String]) async -> [String]? {
        let batchSize = idleBackgroundBatchSize()
        let thumbSize = Self.backgroundGatherThumbnailSize
        let allPaths = cachedIdleScanPaths(appState: appState, directories: directories)
        guard !allPaths.isEmpty else { return nil }
        let diskIndex = await appState.thumbnailCache.diskThumbnailIndex()

        var collected: [String] = []
        collected.reserveCapacity(batchSize)
        var examined = 0
        let startOffset = thumbnailGatherScanOffset % allPaths.count
        var index = startOffset
        while collected.count < batchSize, examined < Self.maxThumbnailScanPathsPerSchedulerTick {
            let path = allPaths[index]
            if !(await appState.thumbnailCache.isThumbnailSatisfiedOnDisk(
                for: path,
                size: thumbSize,
                diskIndex: diskIndex
            )) {
                collected.append(path)
            }
            index = (index + 1) % allPaths.count
            examined += 1
            if examined >= allPaths.count, collected.isEmpty {
                break
            }
        }
        thumbnailGatherScanOffset = index

        if collected.isEmpty {
            thumbnailPathsExaminedSinceFind += examined
            if thumbnailPathsExaminedSinceFind >= allPaths.count {
                thumbnailDirectoryFullyWarm = true
                thumbnailPathsExaminedSinceFind = 0
            }
        } else {
            thumbnailPathsExaminedSinceFind = 0
            thumbnailDirectoryFullyWarm = false
            pendingThumbnailBatchStartOffset = startOffset
            pendingThumbnailBatchPathCount = allPaths.count
        }

        return collected.isEmpty ? nil : collected
    }

    private func collectFeatureBatch(
        appState: AppState,
        directories: [String],
        kind: BackgroundWorkKind
    ) -> [String]? {
        let isClip = kind == .clip
        if isClip {
            if clipDirectoryFullyWarm { return nil }
        } else if kind == .cnn {
            if cnnDirectoryFullyWarm { return nil }
        } else {
            return nil
        }

        let batchSize = idleBackgroundBatchSize()
        let allPaths = cachedIdleScanPaths(appState: appState, directories: directories)
        guard !allPaths.isEmpty else { return nil }

        var collected: [String] = []
        collected.reserveCapacity(batchSize)
        var examined = 0
        var index = (isClip ? clipGatherScanOffset : cnnGatherScanOffset) % allPaths.count
        let maxExamined = Self.maxFeatureScanPathsPerSchedulerTick
        while collected.count < batchSize, examined < maxExamined {
            if !isIdle() { break }
            let path = allPaths[index]
            let needsWork = isClip
                ? appState.imageRecognition.pathNeedsCLIP(path: path, config: appState.config)
                : appState.imageRecognition.pathNeedsCNN(path: path, config: appState.config)
            if needsWork {
                collected.append(path)
            }
            index = (index + 1) % allPaths.count
            examined += 1
            if examined >= allPaths.count, collected.isEmpty {
                break
            }
        }

        if isClip {
            clipGatherScanOffset = index
            if collected.isEmpty {
                clipPathsExaminedSinceFind += examined
                if clipPathsExaminedSinceFind >= allPaths.count {
                    clipDirectoryFullyWarm = true
                    clipPathsExaminedSinceFind = 0
                }
            } else {
                clipPathsExaminedSinceFind = 0
                clipDirectoryFullyWarm = false
            }
        } else {
            cnnGatherScanOffset = index
            if collected.isEmpty {
                cnnPathsExaminedSinceFind += examined
                if cnnPathsExaminedSinceFind >= allPaths.count {
                    cnnDirectoryFullyWarm = true
                    cnnPathsExaminedSinceFind = 0
                }
            } else {
                cnnPathsExaminedSinceFind = 0
                cnnDirectoryFullyWarm = false
            }
        }

        return collected.isEmpty ? nil : collected
    }

    private func collectFaceBatch(appState: AppState, directories: [String]) -> [String]? {
        if faceDirectoryFullyWarm {
            return nil
        }
        let batchSize = idleBackgroundBatchSize()
        let allPaths = cachedIdleScanPaths(appState: appState, directories: directories)
        guard !allPaths.isEmpty else { return nil }

        var collected: [String] = []
        collected.reserveCapacity(batchSize)
        var examined = 0
        let startOffset = faceGatherScanOffset % allPaths.count
        var index = startOffset
        while collected.count < batchSize, examined < Self.maxFaceScanPathsPerSchedulerTick {
            let path = allPaths[index]
            if !appState.faceCache.hasCachedFaces(imagePath: path) {
                collected.append(path)
            }
            index = (index + 1) % allPaths.count
            examined += 1
            if examined >= allPaths.count, collected.isEmpty {
                break
            }
        }
        faceGatherScanOffset = index

        if collected.isEmpty {
            facePathsExaminedSinceFind += examined
            if facePathsExaminedSinceFind >= allPaths.count {
                faceDirectoryFullyWarm = true
                facePathsExaminedSinceFind = 0
            }
        } else {
            facePathsExaminedSinceFind = 0
            faceDirectoryFullyWarm = false
            pendingFaceBatchStartOffset = startOffset
            pendingFaceBatchPathCount = allPaths.count
        }

        return collected.isEmpty ? nil : collected
    }

    private func idleScanDirectoriesCacheKey(directories: [String]) -> String {
        deduplicatedScanRoots(directories).sorted().joined(separator: "\u{0}")
    }

    private func cachedIdleScanPaths(appState: AppState, directories: [String]) -> [String] {
        let key = idleScanDirectoriesCacheKey(directories: directories)
        if key == idleScanPathListKey {
            return idleScanPathList
        }
        var allPaths: [String] = []
        var seenPaths = Set<String>()
        let subfolderDepth = TimingConstants.backgroundIdleScanSubfolderDepth
        for directory in directories {
            let scanned = DirectoryScanner.scanDirectoryRecursive(
                at: directory,
                extensions: appState.config.imageExtensions,
                filterPattern: "*",
                maxDepth: subfolderDepth
            )
            for path in scanned {
                let norm = URL(fileURLWithPath: path).standardizedFileURL.path
                guard seenPaths.insert(norm).inserted else { continue }
                allPaths.append(norm)
            }
        }
        idleScanPathList = allPaths
        idleScanPathListKey = key
        faceGatherScanOffset = 0
        thumbnailGatherScanOffset = 0
        clipGatherScanOffset = 0
        cnnGatherScanOffset = 0
        resetIdleWarmScanState()
        return allPaths
    }

    private func finishBackgroundBatch(
        appState: AppState,
        logKind: BackgroundIdleProcessingLogKind,
        newCount: Int,
        generation: Int,
        batchSize: Int
    ) {
        BackgroundIdleProcessingLog.logFinish(
            logFileURL: appState.sessionViewLogURL,
            kind: logKind,
            newCount: newCount,
            batchSize: batchSize
        )
        if generation == batchGeneration {
            setProcessing(false)
            batchTask = nil
        }
    }

    private func logBackgroundStart(appState: AppState, kind: BackgroundIdleProcessingLogKind) {
        BackgroundIdleProcessingLog.logStart(
            logFileURL: appState.sessionViewLogURL,
            kind: kind
        )
    }

    private func runThumbnailBatch(
        appState: AppState,
        paths: [String],
        logKind: BackgroundIdleProcessingLogKind,
        generation: Int
    ) async {
        logBackgroundStart(appState: appState, kind: logKind)
        setProcessing(true)
        var processedCount = 0
        defer {
            finishBackgroundBatch(
                appState: appState,
                logKind: logKind,
                newCount: processedCount,
                generation: generation,
                batchSize: paths.count
            )
        }

        let shouldCancel: () -> Bool = { [weak self] in
            guard let self else { return true }
            return generation != self.batchGeneration
                || self.foregroundSuspendDepth > 0
                || !self.isIdle()
                || Task.isCancelled
        }

        let thumbSize = Self.backgroundGatherThumbnailSize
        var skippedAlreadyCached = 0
        var failed = 0
        let diskIndex = await appState.thumbnailCache.diskThumbnailIndex()
        for path in paths {
            if shouldCancel() { return }
            if await appState.thumbnailCache.isThumbnailSatisfiedOnDisk(
                for: path,
                size: thumbSize,
                diskIndex: diskIndex
            ) {
                skippedAlreadyCached += 1
                continue
            }
            let newlyCached = await appState.thumbnailCache.warmIdleBackgroundThumbnail(
                for: path,
                size: thumbSize
            )
            if newlyCached {
                processedCount += 1
            } else {
                failed += 1
            }
        }
        if appState.config.bool(forKey: "debug_mode") {
            let endOffset = pendingThumbnailBatchPathCount > 0
                ? thumbnailGatherScanOffset % pendingThumbnailBatchPathCount
                : 0
            BackgroundIdleProcessingLog.logEvent(
                logFileURL: appState.sessionViewLogURL,
                "Background - Thumbnail batch cursor \(pendingThumbnailBatchStartOffset)→\(endOffset) of \(pendingThumbnailBatchPathCount); \(processedCount) new, \(skippedAlreadyCached) already on disk, \(failed) failed"
            )
        }
    }

    private func runFeatureBatch(
        appState: AppState,
        paths: [String],
        logKind: BackgroundIdleProcessingLogKind,
        generation: Int
    ) async {
        logBackgroundStart(appState: appState, kind: logKind)
        setProcessing(true)
        var processedCount = 0
        defer {
            finishBackgroundBatch(
                appState: appState,
                logKind: logKind,
                newCount: processedCount,
                generation: generation,
                batchSize: paths.count
            )
        }

        let shouldCancel: () -> Bool = { [weak self] in
            guard let self else { return true }
            return generation != self.batchGeneration
                || self.foregroundSuspendDepth > 0
                || !self.isIdle()
                || Task.isCancelled
        }

        let workKind: BackgroundWorkKind = logKind == .clip ? .clip : .cnn
        do {
            switch workKind {
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
            default:
                return
            }
            if !shouldCancel() {
                processedCount = paths.count
            }
        } catch {
            return
        }
    }

    private func runFaceBatch(
        appState: AppState,
        paths: [String],
        logKind: BackgroundIdleProcessingLogKind,
        generation: Int
    ) async {
        logBackgroundStart(appState: appState, kind: logKind)
        setProcessing(true)
        var processedCount = 0
        defer {
            if generation == batchGeneration {
                appState.faceCache.flushIndex()
            }
            finishBackgroundBatch(
                appState: appState,
                logKind: logKind,
                newCount: processedCount,
                generation: generation,
                batchSize: paths.count
            )
        }

        let shouldCancel: () -> Bool = { [weak self] in
            guard let self else { return true }
            return generation != self.batchGeneration
                || self.foregroundSuspendDepth > 0
                || !self.isIdle()
                || Task.isCancelled
        }

        let profile = appState.config.profilePaths
        guard FaceEngine.loadModelsIfNeeded(profile: profile) else { return }

        var skippedAlreadyCached = 0
        for path in paths {
            if shouldCancel() { return }
            if appState.faceCache.hasCachedFaces(imagePath: path) {
                skippedAlreadyCached += 1
                continue
            }
            let detections = FaceEngine.encodeFacesFromPath(path, profile: profile)
            let encodings = detections.map(\.encoding)
            var fileMtime: Double?
            var fileSize: Int?
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let modified = attrs[.modificationDate] as? Date,
               let size = attrs[.size] as? Int {
                fileMtime = modified.timeIntervalSince1970
                fileSize = size
            }
            appState.faceCache.setEncodings(
                imagePath: path,
                encodings: encodings,
                mtime: fileMtime,
                size: fileSize
            )
            processedCount += 1
        }
        if appState.config.bool(forKey: "debug_mode") {
            let endOffset = pendingFaceBatchPathCount > 0
                ? faceGatherScanOffset % pendingFaceBatchPathCount
                : 0
            BackgroundIdleProcessingLog.logEvent(
                logFileURL: appState.sessionViewLogURL,
                "Background - Face batch cursor \(pendingFaceBatchStartOffset)→\(endOffset) of \(pendingFaceBatchPathCount); \(processedCount) new, \(skippedAlreadyCached) already cached"
            )
        }
    }

    private func targetDirectories(appState: AppState) -> [String] {
        var directories: [String] = []
        var seen = Set<String>()

        func appendDirectoryIfValid(_ path: String) {
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
            let norm = Self.standardizedDirectoryPath(path)
            guard seen.insert(norm).inserted else { return }
            directories.append(norm)
        }

        if let priority = priorityDirectory {
            appendDirectoryIfValid(priority)
        }
        if let current = appState.fileData.currentDirectory {
            appendDirectoryIfValid(current)
        }
        for optional in appState.config.favoriteDirectories() {
            guard let path = optional else { continue }
            appendDirectoryIfValid(path)
        }
        for path in appState.config.recentDirectories() {
            appendDirectoryIfValid(path)
        }

        return directories
    }
}
