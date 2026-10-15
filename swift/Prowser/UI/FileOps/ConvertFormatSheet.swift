import SwiftUI

struct ConvertFormatSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDialog) private var closeDialog

    @State private var targetFormat: ConvertFormatService.TargetFormat = .jpeg
    @State private var deleteOriginal = false
    @State private var preserveDates = false
    @State private var isConverting = false


    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Convert Image Format")
                .font(.headline)

            Text("\(appState.fileOpsTargetPaths.count) file(s) selected")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Target format", selection: $targetFormat) {
                ForEach(ConvertFormatService.TargetFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.radioGroup)

            Toggle("Delete original", isOn: $deleteOriginal)

            Toggle("Preserve date", isOn: $preserveDates)

            DialogButtonRow([
                DialogButton("Cancel", isCancel: true, isEnabled: !isConverting) { closeDialog(); dismiss() },
                DialogButton("Convert", isDefault: true,
                             isEnabled: !(isConverting || appState.fileOpsTargetPaths.isEmpty)) { convert() },
            ])
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 200)
        .persistedDialogGeometry(
            DialogGeometryKey.convertFormat,
            defaultWidth: 380,
            defaultHeight: 260,
            minWidth: 320,
            minHeight: 220
        )
        .onAppear { loadFromSettings() }
    }

    @MainActor
    private func loadFromSettings() {
        deleteOriginal = appState.config.bool(forKey: "convert_delete_original", default: false)
        preserveDates = appState.config.bool(forKey: "convert_preserve_date", default: false)
        let formatRaw = (appState.config.rawSettings()["convert_target_format"] as? String ?? "jpg")
            .lowercased()
        switch formatRaw {
        case "png": targetFormat = .png
        case "webp": targetFormat = .webp
        default: targetFormat = .jpeg
        }
    }

    @MainActor
    private func saveSettings() {
        let formatKey: String
        switch targetFormat {
        case .png: formatKey = "png"
        case .webp: formatKey = "webp"
        case .jpeg: formatKey = "jpg"
        }
        appState.config.setValue(formatKey, forKey: "convert_target_format")
        appState.config.setValue(deleteOriginal, forKey: "convert_delete_original")
        appState.config.setValue(preserveDates, forKey: "convert_preserve_date")
        appState.config.applySettingsChange(emit: appState.eventBus)
    }

    @MainActor
    private func convert() {
        let paths = appState.fileOpsTargetPaths
        guard !paths.isEmpty else { return }
        saveSettings()
        isConverting = true

        let workPaths = ConvertFormatService.pathsNeedingConversion(paths, target: targetFormat)
        let batchConversion = workPaths.count > 1
        if batchConversion {
            let suppressSeconds = max(2.0, Double(workPaths.count) * 0.35 + 1.0)
            appState.beginSuppressDirectoryRefresh(minimumDuration: suppressSeconds)
            appState.suspendFileTreeHighlightSync()
        }
        defer {
            if batchConversion {
                appState.resumeFileTreeHighlightSync()
                appState.endSuppressDirectoryRefresh()
            }
        }

        let (converted, errors) = ConvertFormatService.convertAll(
            paths: paths,
            to: targetFormat,
            deleteOriginal: deleteOriginal,
            preserveDates: preserveDates,
            ignoreExifRotation: appState.config.ignoreExifRotation
        )

        isConverting = false
        closeDialog()
        dismiss()
        if !converted.isEmpty {
            applyConvertPathRemap(paths: paths, converted: converted)
            DirectoryRefreshService.invalidateThumbnails(
                appState: appState,
                paths: Array(Set(converted))
            )
            appState.refreshDirectory()
            appState.status.show("Converted \(converted.count) file(s) to \(targetFormat.displayName)")
        }
        if let first = errors.first {
            appState.status.show(first)
        } else if converted.isEmpty {
            appState.status.show("No files needed conversion")
        }
    }

    /// Port of `files/convert_format._apply_path_remap_to_selection`.
    @MainActor
    private func applyConvertPathRemap(paths: [String], converted: [String]) {
        let convertedSet = Set(converted)
        var pathMap: [String: String] = [:]
        for path in paths {
            let output = (path as NSString).deletingPathExtension + "." + targetFormat.fileExtension
            if convertedSet.contains(output) {
                pathMap[path] = output
            }
        }
        guard !pathMap.isEmpty else { return }

        if !appState.selection.selectedFiles.isEmpty {
            appState.selection.selectedFiles = Set(
                appState.selection.selectedFiles.map { pathMap[$0] ?? $0 }
            )
        }
        if let current = appState.fileData.currentImagePath, let mapped = pathMap[current] {
            appState.fileData.setCurrentImagePath(mapped)
            if let index = appState.fileData.displayedImages.firstIndex(of: mapped) {
                appState.fileData.setCurrentIndex(index)
            }
        }
    }
}
