import SwiftUI

struct ConvertFormatSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDialog) private var closeDialog

    @State private var targetFormat: ConvertFormatService.TargetFormat = .jpeg
    @State private var deleteOriginal = false
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

            Toggle("Delete original after conversion", isOn: $deleteOriginal)

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
            defaultHeight: 220,
            minWidth: 320,
            minHeight: 180
        )
    }

    @MainActor
    private func convert() {
        let paths = appState.fileOpsTargetPaths
        guard !paths.isEmpty else { return }
        isConverting = true
        let (converted, errors) = ConvertFormatService.convertAll(
            paths: paths,
            to: targetFormat,
            deleteOriginal: deleteOriginal
        )
        isConverting = false
        closeDialog()
        dismiss()
        if !converted.isEmpty {
            appState.thumbnailInvalidationGeneration += 1
            appState.refreshDirectory()
            appState.status.show("Converted \(converted.count) file(s) to \(targetFormat.displayName)")
        }
        if let first = errors.first {
            appState.status.show(first)
        } else if converted.isEmpty {
            appState.status.show("No files needed conversion")
        }
    }
}
