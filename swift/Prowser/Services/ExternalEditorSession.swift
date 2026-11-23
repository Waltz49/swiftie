import AppKit
import Foundation

/// Port of Python ``files/external_editor.py`` ``TimestampPreservingEditor`` (per-file edit sessions).
@MainActor
final class ExternalEditorSession {
    static let shared = ExternalEditorSession()

    private struct MonitoredEdit {
        let path: String
        let editorAppName: String
        var anchorPID: pid_t?
        var anchorBundleID: String?
        var originalAccessDate: Date?
        var originalModDate: Date?
        var originalFileSize: Int64?
        /// Raw EXIF UserComment bytes (Python ``get_usercomment_from_path``).
        var originalUserCommentPayload: Data?
        /// Set when the anchor editor app is no longer running (per-session, not global).
        var editorQuitAt: Date?
    }

    private let checkIntervalSeconds: TimeInterval = 2.0
    /// Pixelmator often saves (and strips EXIF) after the app process exits; keep watching briefly.
    private let postEditorGraceSeconds: TimeInterval = 8.0
    private var monitorTask: Task<Void, Never>?
    private var sessions: [String: MonitoredEdit] = [:]
    private weak var appState: AppState?
    private var workspaceObserver: NSObjectProtocol?

    private init() {}

    func bind(appState: AppState) {
        self.appState = appState
        installWorkspaceObserverIfNeeded()
    }

    /// When the app intentionally changes mtime during an edit, update stored originals (Python ``notify_mtime_changed_by_app``).
    func notifyMtimeChangedByApp(filePath: String, newModificationDate: Date) {
        let key = Self.normalizedPath(filePath)
        guard var session = sessions[key] else { return }
        session.originalModDate = newModificationDate
        session.originalAccessDate = newModificationDate
        sessions[key] = session
    }

    func beginEdit(path: String, editorName: String, editorURL: URL) {
        guard FileManager.default.fileExists(atPath: path) else { return }

        let key = Self.normalizedPath(path)
        let anchorBundleID = Bundle(url: editorURL)?.bundleIdentifier
        registerSession(path: path, editorAppName: editorName, anchorPID: nil, anchorBundleID: anchorBundleID)

        let fileURL = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([fileURL], withApplicationAt: editorURL, configuration: config) { [weak self] app, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.appState?.status.show("Could not open editor: \(error.localizedDescription)")
                    self.sessions.removeValue(forKey: key)
                    self.stopMonitoringIfIdle()
                    return
                }
                if var session = self.sessions[key] {
                    session.anchorPID = app?.processIdentifier
                    session.anchorBundleID = app?.bundleIdentifier ?? anchorBundleID
                    self.sessions[key] = session
                    self.clearEditorQuitGrace(matching: session)
                }
                self.ensureMonitoring()
            }
        }
    }

    /// Port of ``edit_pixelmator_pro_multi_files`` / ``edit_with_pixelmator_pro_multi`` (first file as document, rest as layers).
    func beginPixelmatorMultiEdit(paths: [String]) {
        guard paths.count >= 2 else { return }

        let normalized = paths.map { Self.normalizedPath($0) }
        for path in normalized {
            guard FileManager.default.isReadableFile(atPath: path) else {
                appState?.status.show("File not found")
                return
            }
        }

        guard let first = normalized.first else { return }
        let editorName = ImageGenEditorSettings.pixelmatorProName
        let pixelmatorBundleID = "com.pixelmatorteam.pixelmator.x"
        registerSession(
            path: first,
            editorAppName: editorName,
            anchorPID: Self.runningEditorPID(bundleIdentifier: pixelmatorBundleID, editorName: editorName),
            anchorBundleID: pixelmatorBundleID
        )

        let canvas = Self.maxPixelmatorCanvasSize(filePaths: normalized)
        let launched = PixelmatorInfillService.launchPixelmatorProMultiFiles(
            paths: normalized,
            canvasWidth: canvas?.0 ?? 0,
            canvasHeight: canvas?.1 ?? 0
        )
        guard launched else {
            appState?.status.show("Could not open Pixelmator Pro.")
            sessions.removeValue(forKey: first)
            stopMonitoringIfIdle()
            return
        }
        if var session = sessions[first] {
            session.anchorPID = Self.runningEditorPID(bundleIdentifier: pixelmatorBundleID, editorName: editorName)
            sessions[first] = session
        }
        ensureMonitoring()
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func maxPixelmatorCanvasSize(filePaths: [String]) -> (Int, Int)? {
        var maxWidth = 0
        var maxHeight = 0
        for path in filePaths {
            guard let dims = SimilarImageGroupPairsBuilder.orientedDimensions(path: path) else {
                return nil
            }
            maxWidth = max(maxWidth, dims.width)
            maxHeight = max(maxHeight, dims.height)
        }
        guard maxWidth > 0, maxHeight > 0 else { return nil }
        return (maxWidth, maxHeight)
    }

    /// Replace any existing snapshot for this path (latest EXIF UserComment on disk wins).
    private func registerSession(
        path: String,
        editorAppName: String,
        anchorPID: pid_t?,
        anchorBundleID: String?
    ) {
        let key = Self.normalizedPath(path)
        var session = MonitoredEdit(
            path: key,
            editorAppName: editorAppName,
            anchorPID: anchorPID,
            anchorBundleID: anchorBundleID,
            originalAccessDate: nil,
            originalModDate: nil,
            originalFileSize: nil,
            originalUserCommentPayload: nil,
            editorQuitAt: nil
        )
        applySnapshot(to: &session)
        sessions[key] = session
        ensureMonitoring()
    }

    private func applySnapshot(to session: inout MonitoredEdit) {
        let url = URL(fileURLWithPath: session.path)
        if let values = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .contentAccessDateKey,
            .fileSizeKey,
        ]) {
            session.originalModDate = values.contentModificationDate
            session.originalAccessDate = values.contentAccessDate ?? values.contentModificationDate
            if let size = values.fileSize {
                session.originalFileSize = Int64(size)
            }
        }
        session.originalUserCommentPayload = ExifService.userCommentRawPayload(path: session.path)
        session.editorQuitAt = nil
    }

    private func ensureMonitoring() {
        guard monitorTask == nil, !sessions.isEmpty else { return }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.checkIntervalSeconds ?? 2) * 1_000_000_000))
                guard let self else { return }
                if self.sessions.isEmpty { break }

                var finishedPaths: [String] = []
                for key in Array(self.sessions.keys) {
                    guard var session = self.sessions[key] else { continue }
                    if self.handleFileChangeIfNeeded(session: &session) {
                        self.sessions[key] = session
                        self.reconcileSiblingSessionsInEditor(triggeredBy: session.path)
                        self.clearEditorQuitGrace(matching: session)
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        session = self.sessions[key] ?? session
                    } else if self.handleStrippedCommentOnly(session: &session) {
                        self.sessions[key] = session
                        self.clearEditorQuitGrace(matching: session)
                    }

                    var editorUp = self.resolveEditorRunning(session: &session)
                    if !editorUp {
                        editorUp = self.isEditorRunning(named: session.editorAppName)
                    }
                    if editorUp {
                        session.editorQuitAt = nil
                    } else if session.editorQuitAt == nil {
                        session.editorQuitAt = Date()
                    }

                    let inGrace = session.editorQuitAt.map {
                        Date().timeIntervalSince($0) < self.postEditorGraceSeconds
                    } ?? false

                    if !editorUp && !inGrace {
                        self.finishSession(&session)
                        finishedPaths.append(key)
                    } else {
                        self.sessions[key] = session
                    }
                }

                for key in finishedPaths {
                    self.sessions.removeValue(forKey: key)
                }
            }
            guard let self else { return }
            self.monitorTask = nil
        }
    }

    private func stopMonitoringIfIdle() {
        guard sessions.isEmpty else { return }
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func finishSession(_ session: inout MonitoredEdit) {
        restoreTimestampsAndComment(session: &session)
        refreshUI(for: session.path)
    }

    /// Pixelmator can rewrite other open documents when one is saved; re-check cohort mates in the same tick.
    private func reconcileSiblingSessionsInEditor(triggeredBy path: String) {
        let trigger = sessions[path]
        for key in sessions.keys where key != path {
            guard var sibling = sessions[key] else { continue }
            if let trigger, !sessionsShareEditor(sibling, trigger) {
                continue
            }
            let handled = handleFileChangeIfNeeded(session: &sibling)
                || handleStrippedCommentOnly(session: &sibling)
            if handled {
                sessions[key] = sibling
            }
        }
    }

    private func sessionsShareEditor(_ a: MonitoredEdit, _ b: MonitoredEdit) -> Bool {
        if a.editorAppName != b.editorAppName { return false }
        if let aBundle = a.anchorBundleID, let bBundle = b.anchorBundleID {
            return aBundle == bBundle
        }
        return true
    }

    private func clearEditorQuitGrace(matching session: MonitoredEdit) {
        for key in sessions.keys {
            guard var other = sessions[key] else { continue }
            guard sessionsShareEditor(other, session) else { continue }
            other.editorQuitAt = nil
            if other.anchorPID == nil {
                other.anchorPID = session.anchorPID
            }
            sessions[key] = other
        }
    }

    private func handleStrippedCommentOnly(session: inout MonitoredEdit) -> Bool {
        guard shouldRestoreUserComment(session: session) else { return false }
        guard FileManager.default.fileExists(atPath: session.path) else { return false }
        restoreTimestampsAndComment(session: &session)
        refreshUI(for: session.path)
        refreshSnapshotSizes(session: &session)
        return true
    }

    private func refreshSnapshotSizes(session: inout MonitoredEdit) {
        let url = URL(fileURLWithPath: session.path)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        session.originalModDate = values.contentModificationDate
        if let size = values.fileSize {
            session.originalFileSize = Int64(size)
        }
    }

    private func handleFileChangeIfNeeded(session: inout MonitoredEdit) -> Bool {
        let path = session.path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mod = values.contentModificationDate,
              let originalMod = session.originalModDate else {
            return false
        }
        let currentSize = values.fileSize.map { Int64($0) }
        let mtimeChanged = abs(mod.timeIntervalSince1970 - originalMod.timeIntervalSince1970) > 1.0
        let sizeChanged = currentSize != session.originalFileSize
        let commentStripped = shouldRestoreUserComment(session: session)
        guard mtimeChanged || sizeChanged || commentStripped else { return false }

        restoreTimestampsAndComment(session: &session)
        refreshUI(for: path)
        refreshSnapshotSizes(session: &session)
        return true
    }

    private func shouldRestoreUserComment(session: MonitoredEdit) -> Bool {
        guard let original = session.originalUserCommentPayload, !original.isEmpty else { return false }
        guard let current = ExifService.userCommentRawPayload(path: session.path) else { return true }
        return current != original
    }

    private func restoreTimestampsAndComment(session: inout MonitoredEdit) {
        let path = session.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        if let payload = session.originalUserCommentPayload, !payload.isEmpty {
            let url = URL(fileURLWithPath: path)
            let times = try? url.resourceValues(forKeys: [.contentModificationDateKey, .contentAccessDateKey])
            let mtime = times?.contentModificationDate
            let atime = times?.contentAccessDate ?? session.originalAccessDate
            do {
                try ExifUserCommentRestore.restore(path: path, userCommentPayload: payload, mtime: mtime, atime: atime)
            } catch {
                NSLog("ExternalEditorSession: user comment restore failed for \(path): \(error)")
            }
        }
        applyOriginalTimestamps(session: &session)
    }

    private func applyOriginalTimestamps(session: inout MonitoredEdit) {
        guard let mtime = session.originalModDate else { return }
        do {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: session.path)
        } catch {
            NSLog("ExternalEditorSession: timestamp restore failed for \(session.path): \(error)")
        }
    }

    private func refreshUI(for path: String) {
        guard let appState else { return }
        DirectoryRefreshService.invalidateThumbnails(appState: appState, paths: [path])
        appState.notifyFileMetadataChanged(path: path)
    }

    private func resolveEditorRunning(session: inout MonitoredEdit) -> Bool {
        if let pid = session.anchorPID,
           let app = NSRunningApplication(processIdentifier: pid) {
            if !app.isTerminated {
                return true
            }
            session.anchorPID = nil
        }
        if let bundleID = session.anchorBundleID,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            session.anchorPID = app.processIdentifier
            return true
        }
        if isEditorRunning(named: session.editorAppName),
           let app = runningApplication(named: session.editorAppName) {
            session.anchorPID = app.processIdentifier
            session.anchorBundleID = session.anchorBundleID ?? app.bundleIdentifier
            return true
        }
        return false
    }

    private func runningApplication(named editorName: String) -> NSRunningApplication? {
        let needle = editorName.lowercased()
        let compact = needle.replacingOccurrences(of: " ", with: "")
        return NSWorkspace.shared.runningApplications.first { app in
            let localized = (app.localizedName ?? "").lowercased()
            let bundle = (app.bundleURL?.deletingPathExtension().lastPathComponent ?? "").lowercased()
            return localized.contains(needle)
                || bundle.contains(compact)
                || bundle.contains(needle)
        }
    }

    private func isEditorRunning(named editorName: String) -> Bool {
        let needle = editorName.lowercased()
        let compact = needle.replacingOccurrences(of: " ", with: "")
        return NSWorkspace.shared.runningApplications.contains { app in
            let localized = (app.localizedName ?? "").lowercased()
            let bundle = (app.bundleURL?.deletingPathExtension().lastPathComponent ?? "").lowercased()
            return localized.contains(needle)
                || bundle.contains(compact)
                || bundle.contains(needle)
        }
    }

    private static func runningEditorPID(bundleIdentifier: String, editorName: String) -> pid_t? {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return app.processIdentifier
        }
        let needle = editorName.lowercased()
        return NSWorkspace.shared.runningApplications.first { app in
            (app.localizedName ?? "").lowercased().contains(needle)
        }?.processIdentifier
    }

    private func installWorkspaceObserverIfNeeded() {
        guard workspaceObserver == nil else { return }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier
            Task { @MainActor [weak self] in
                self?.handleEditorAppTerminated(pid: pid, bundleID: bundleID)
            }
        }
    }

    private func handleEditorAppTerminated(pid: pid_t, bundleID: String?) {
        let now = Date()
        for key in sessions.keys {
            guard var session = sessions[key] else { continue }
            let matchesPID = session.anchorPID == pid
            let matchesBundle = bundleID != nil && session.anchorBundleID == bundleID
            guard matchesPID || matchesBundle else { continue }
            session.anchorPID = nil
            var stillRunning = resolveEditorRunning(session: &session)
            if !stillRunning {
                stillRunning = isEditorRunning(named: session.editorAppName)
            }
            if stillRunning {
                session.editorQuitAt = nil
            } else if session.editorQuitAt == nil {
                session.editorQuitAt = now
            }
            sessions[key] = session
        }
        ensureMonitoring()
    }
}