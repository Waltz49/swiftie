import SwiftUI

struct MoveWorkFilesSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var directoryName = ""
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move Work Files")
                .font(.headline)
            Text("Enter directory name (created at the same level as the work directory):")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Directory name", text: $directoryName)
                .textFieldStyle(.roundedBorder)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Move") { moveFiles() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValidName(directoryName))
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("/") || trimmed == "." || trimmed == ".." { return false }
        return true
    }

    @MainActor
    private func moveFiles() {
        let name = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidName(name) else {
            errorMessage = "Invalid directory name"
            return
        }
        do {
            let moved = try MoveWorkFilesService.moveWorkFiles(appState: appState, destinationName: name)
            appState.status.show("Moved \(moved) file(s)")
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
