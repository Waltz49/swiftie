import AppKit
import Foundation

/// Port of Python ``files/external_editor.py`` ``TimestampPreservingEditor`` (single-file edit).
@MainActor
final class ExternalEditorSession {
    static let shared = ExternalEditorSession()

    private let checkIntervalSeconds: TimeInterval = 2.0
    private var monitorTask: Task<Void, Never>?
    private var filePath: String?
    private var originalAccessDate: Date?
    private var originalModDate: Date?
    private var originalUserComment: String?
    private var editorAppName = ""
    private weak var appState: AppState?

    private init() {}

    func bind(appState: AppState) {
        self.appState = appState
    }

    /// When the app intentionally changes mtime during an edit, update stored originals (Python ``notify_mtime_changed_by_app``).
    func notifyMtimeChangedByApp(filePath: String, newModificationDate: Date) {
        guard let monitored = self.filePath, monitored == filePath else { return }
        originalModDate = newModificationDate
        originalAccessDate = newModificationDate
    }

    func beginEdit(path: String, editorName: String, editorURL: URL) {
        stopMonitoring()
        guard FileManager.default.fileExists(atPath: path) else { return }

        editorAppName = editorName
        filePath = path
        snapshotFileState(path: path)

        let fileURL = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([fileURL], withApplicationAt: editorURL, configuration: config) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.appState?.status.show("Could not open editor: \(error.localizedDescription)")
                    self.clearSession()
                    return
                }
                self.startMonitoring()
            }
        }
    }

    /// Port of ``edit_pixelmator_pro_multi_files`` / ``edit_with_pixelmator_pro_multi`` (first file as document, rest as layers).
    func beginPixelmatorMultiEdit(paths: [String]) {
        stopMonitoring()
        guard paths.count >= 2 else { return }

        let normalized = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for path in normalized {
            guard FileManager.default.isReadableFile(atPath: path) else {
                appState?.status.show("File not found")
                return
            }
        }

        guard let first = normalized.first else { return }
        editorAppName = ImageGenEditorSettings.pixelmatorProName
        filePath = first
        snapshotFileState(path: first)

        let canvas = Self.maxPixelmatorCanvasSize(filePaths: normalized)
        let launched = PixelmatorInfillService.launchPixelmatorProMultiFiles(
            paths: normalized,
            canvasWidth: canvas?.0 ?? 0,
            canvasHeight: canvas?.1 ?? 0
        )
        guard launched else {
            appState?.status.show("Could not open Pixelmator Pro.")
            clearSession()
            return
        }
        startMonitoring()
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

    private func snapshotFileState(path: String) {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .contentAccessDateKey]) {
            originalModDate = values.contentModificationDate
            originalAccessDate = values.contentAccessDate ?? values.contentModificationDate
        }
        originalUserComment = ExifService.userComment(path: path)
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        let editor = editorAppName
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.checkIntervalSeconds ?? 2) * 1_000_000_000))
                guard let self else { return }
                if !self.isEditorRunning(named: editor) { break }
                guard let path = self.filePath, FileManager.default.fileExists(atPath: path) else { continue }
                let url = URL(fileURLWithPath: path)
                guard let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      let original = self.originalModDate else {
                    continue
                }
                if abs(mod.timeIntervalSince1970 - original.timeIntervalSince1970) > 1.0 {
                    await self.restoreTimestampsAndComment()
                    self.refreshUI(for: path)
                    if let updated = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                        self.originalModDate = updated
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            guard let self else { return }
            await self.restoreTimestampsAndComment()
            if let path = self.filePath {
                self.refreshUI(for: path)
            }
            self.clearSession()
        }
    }

    private func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func clearSession() {
        stopMonitoring()
        filePath = nil
        originalAccessDate = nil
        originalModDate = nil
        originalUserComment = nil
        editorAppName = ""
    }

    private func restoreTimestampsAndComment() async {
        guard let path = filePath, FileManager.default.fileExists(atPath: path) else { return }
        if let comment = originalUserComment, !comment.isEmpty {
            do {
                try await ExifService.writeUserComment(path: path, text: comment)
            } catch {
                NSLog("ExternalEditorSession: user comment restore failed for \(path): \(error)")
            }
        }
        applyOriginalTimestamps(path: path)
    }

    private func applyOriginalTimestamps(path: String) {
        var attrs: [FileAttributeKey: Any] = [:]
        if let mtime = originalModDate {
            attrs[.modificationDate] = mtime
        }
        if let atime = originalAccessDate {
            attrs[.creationDate] = atime
        }
        guard !attrs.isEmpty else { return }
        do {
            try FileManager.default.setAttributes(attrs, ofItemAtPath: path)
        } catch {
            NSLog("ExternalEditorSession: timestamp restore failed for \(path): \(error)")
        }
    }

    private func refreshUI(for path: String) {
        guard let appState else { return }
        DirectoryRefreshService.invalidateThumbnails(appState: appState, paths: [path])
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
}
