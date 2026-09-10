import AppKit
import Foundation

/// Batch EXIF operations from menus. Port of `exif_operations_manager.py` (phase 1).
@MainActor
final class ExifOperationsController {
    private weak var appState: AppState?

    func bind(_ appState: AppState) {
        self.appState = appState
    }

    func resetFileDateToExifForSelection() {
        guard let appState else { return }
        guard appState.fileData.currentViewMode == .thumbnail else {
            appState.status.show("This feature is only available in thumbnail mode")
            return
        }

        let paths = selectedPaths(appState: appState)
        guard !paths.isEmpty else {
            appState.status.show("No files selected")
            return
        }

        let formatter = ExifOperationsController.displayFormatter
        var rows: [ExifBatchRow] = []
        var changes: [(path: String, exif: Date)] = []

        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let exifDate = ExifService.exifTimestamp(path: path) else { continue }
            guard let mtime = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date else {
                continue
            }
            if abs(mtime.timeIntervalSince1970 - exifDate.timeIntervalSince1970) <= 1 { continue }

            let filename = (path as NSString).lastPathComponent
            rows.append(
                ExifBatchRow(
                    id: path,
                    path: path,
                    filename: filename,
                    detailLines: [
                        "Path: \(truncatePath(path))",
                        "Current: \(formatter.string(from: mtime))",
                        "EXIF:    \(formatter.string(from: exifDate))",
                    ]
                )
            )
            changes.append((path, exifDate))
        }

        guard !changes.isEmpty else {
            showAlert("No files need date changes (all match EXIF or have no EXIF data).")
            return
        }

        let count = changes.count
        appState.exifBatchConfirmation = ExifBatchConfirmationState(
            title: "Reset Date to EXIF",
            infoText: "The following \(count) file(s) will have their modification dates reset to match EXIF data:",
            warningText: nil,
            rows: rows,
            confirmLabel: "Reset Dates",
            onConfirm: { [weak appState] in
                guard let appState else { return }
                var changed = 0
                for (path, exifDate) in changes {
                    do {
                        try FileManager.default.setAttributes(
                            [.modificationDate: exifDate, .creationDate: exifDate],
                            ofItemAtPath: path
                        )
                        appState.metadataCache.invalidate(path: path)
                        changed += 1
                    } catch {
                        continue
                    }
                }
                if changed > 0 {
                    appState.status.show("Reset dates for \(changed) file(s)")
                    appState.refreshDirectory()
                } else {
                    appState.status.show("No files were updated")
                }
            }
        )
    }

    func resetExifDateToFileDateForSelection() {
        guard let appState else { return }
        guard appState.fileData.currentViewMode == .thumbnail else {
            appState.status.show("This feature is only available in thumbnail mode")
            return
        }

        let paths = selectedPaths(appState: appState).filter { ExifService.canWriteExif(path: $0) }
        guard !paths.isEmpty else {
            appState.status.show("No supported files selected")
            return
        }

        let formatter = ExifOperationsController.displayFormatter
        var rows: [ExifBatchRow] = []
        var changes: [String] = []
        var overwriteCount = 0

        for path in paths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let mtime = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date else {
                continue
            }
            let oldExif = ExifService.exifTimestamp(path: path)
            if let oldExif, abs(mtime.timeIntervalSince1970 - oldExif.timeIntervalSince1970) <= 1 {
                continue
            }
            if oldExif != nil { overwriteCount += 1 }

            var lines = [
                "Path: \(truncatePath(path))",
                "New EXIF Date: \(formatter.string(from: mtime))",
            ]
            if let oldExif {
                lines.insert("Old EXIF Date: \(formatter.string(from: oldExif))", at: 1)
            }

            rows.append(
                ExifBatchRow(
                    id: path,
                    path: path,
                    filename: (path as NSString).lastPathComponent,
                    detailLines: lines
                )
            )
            changes.append(path)
        }

        guard !changes.isEmpty else {
            showAlert("No files need EXIF updates (all match file dates or are unsupported).")
            return
        }

        var warning: String?
        if overwriteCount > 0 {
            warning = "WARNING: EXIF date/time data will be updated for \(changes.count) file(s). \(overwriteCount) already have EXIF timestamps that will be overwritten."
        } else {
            warning = "WARNING: EXIF date/time data will be updated for \(changes.count) file(s)."
        }

        appState.exifBatchConfirmation = ExifBatchConfirmationState(
            title: "Reset EXIF to File Date",
            infoText: "The following \(changes.count) file(s) will have EXIF date/time set to match file modification date:",
            warningText: warning,
            rows: rows,
            confirmLabel: "Update EXIF",
            onConfirm: { [weak appState] in
                guard let appState else { return }
                var changed = 0
                for path in changes {
                    do {
                        try ExifService.resetExifDateToFileDate(path: path)
                        appState.metadataCache.invalidate(path: path)
                        changed += 1
                    } catch {
                        continue
                    }
                }
                if changed > 0 {
                    appState.status.show("Updated EXIF dates for \(changed) file(s)")
                    appState.refreshDirectory()
                } else {
                    appState.status.show("No files were updated")
                }
            }
        )
    }

    func deleteUserCommentForSelection() {
        guard let appState else { return }
        let paths = selectedPaths(appState: appState).filter { ExifService.canWriteExif(path: $0) }
        guard !paths.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Delete User Comment?"
        alert.informativeText = "Remove EXIF User Comment from \(paths.count) file(s)?"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for path in paths {
            try? ExifService.deleteUserComment(path: path)
        }
        appState.refreshDirectory()
    }

    func editUserCommentForCurrent() {
        guard let appState, let path = appState.fileData.currentImagePath else { return }
        guard ExifService.canWriteExif(path: path) else {
            showAlert("This file format does not support EXIF User Comment editing.")
            return
        }
        NotificationCenter.default.post(name: .prowserEditUserCommentRequested, object: path)
    }

    private func selectedPaths(appState: AppState) -> [String] {
        if !appState.selection.selectedFiles.isEmpty {
            return Array(appState.selection.selectedFiles)
        }
        if let current = appState.fileData.currentImagePath {
            return [current]
        }
        return []
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    private func truncatePath(_ path: String) -> String {
        let expanded = (path as NSString).standardizingPath
        if expanded.count <= 72 { return expanded }
        return "…" + String(expanded.suffix(68))
    }

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

extension Notification.Name {
    static let prowserEditUserCommentRequested = Notification.Name("prowser.editUserCommentRequested")
}
