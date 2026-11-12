import AppKit
import SwiftUI

@MainActor
struct MoveToDirectorySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDialog) private var closeDialog

    @State private var directoryPath = ""
    @State private var allowCreateDirectory = false
    @State private var errorMessage = ""
    @State private var isMoving = false

    private var paths: [String] { appState.fileOpsTargetPaths }

    private var validationState: SettingsPathValidationState {
        SettingsPathValidation.validateDirectoryPath(directoryPath, allowMissing: allowCreateDirectory)
    }

    private var canMove: Bool {
        guard !paths.isEmpty, !isMoving else { return false }
        if case .valid = validationState { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move to Directory")
                .font(.headline)

            Text(summaryText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                TextField("Directory path", text: $directoryPath)
                    .textFieldStyle(.roundedBorder)
                SettingsPathValidationIndicator(state: validationState)
                    .frame(width: 20)
                Button("…") { browseDirectory() }
                    .frame(width: 30)
                    .help("Choose directory")
            }

            Toggle("Allow new directory creation", isOn: $allowCreateDirectory)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DialogButtonRow([
                DialogButton("Cancel", isCancel: true, isEnabled: !isMoving) {
                    closeDialog()
                    dismiss()
                },
                DialogButton("Move", isDefault: true, isEnabled: canMove) { performMove() },
            ])
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 220)
        .persistedDialogGeometry(
            DialogGeometryKey.moveToDirectory,
            defaultWidth: 480,
            defaultHeight: 240,
            minWidth: 420,
            minHeight: 200
        )
        .onAppear { loadInitialPath() }
        .onChange(of: directoryPath) { _, _ in errorMessage = "" }
        .onChange(of: allowCreateDirectory) { _, _ in errorMessage = "" }
    }

    private var summaryText: String {
        let count = paths.count
        if count == 0 { return "No files selected" }
        if count == 1, let name = paths.first.map({ ($0 as NSString).lastPathComponent }) {
            return "Move 1 file: \(name)"
        }
        return "Move \(count) files"
    }

    @MainActor
    private func loadInitialPath() {
        errorMessage = ""
        if let lastDrop = appState.lastDropLocation,
           PathLabelDisambiguation.isEligibleLastDropDirectory(stored: lastDrop) {
            directoryPath = SettingsPathValidation.normalizedTypedPathDisplayPath(lastDrop)
        } else if let first = paths.first {
            let parent = (first as NSString).deletingLastPathComponent
            if !parent.isEmpty {
                directoryPath = SettingsPathValidation.normalizedTypedPathDisplayPath(parent)
            }
        }
    }

    @MainActor
    private func browseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        let expanded = SettingsPathValidation.expandedPath(directoryPath)
        if !expanded.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                panel.directoryURL = URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        directoryPath = SettingsPathValidation.normalizedTypedPathDisplayPath(url.path)
    }

    @MainActor
    private func performMove() {
        guard canMove else { return }
        isMoving = true
        errorMessage = ""
        defer { isMoving = false }

        let result = appState.fileOperations.moveSelectedToDirectory(
            paths: paths,
            targetPath: directoryPath,
            allowCreateDirectory: allowCreateDirectory
        )
        switch result {
        case .preparationFailed(let message):
            errorMessage = message
        case .finished(let shouldDismiss):
            if shouldDismiss {
                closeDialog()
                dismiss()
            }
        }
    }
}
