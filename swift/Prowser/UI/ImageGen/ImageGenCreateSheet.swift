import SwiftUI

struct ImageGenCreateSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var prompt = ""
    @State private var width = 1024
    @State private var height = 1024
    @State private var errorMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Image").font(.title2)

            ImageGenPromptPlainTextEdit(
                text: $prompt,
                minLines: ImageGenPromptLayout.createSheetMinLines,
                maxLines: ImageGenPromptLayout.createSheetMaxLines
            )

            HStack {
                Stepper("Width: \(width)", value: $width, in: 512...1536, step: 64)
                Stepper("Height: \(height)", value: $height, in: 512...1536, step: 64)
            }

            if !errorMessage.isEmpty {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }

            DialogButtonRow([
                DialogButton("Cancel", isCancel: true) { dismiss() },
                DialogButton(
                    "Generate",
                    isDefault: true,
                    isEnabled: !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) { submit() },
            ], focusDefaultOnAppear: true)
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 320)
        .persistedDialogGeometry(
            "imagegen_create_sheet_geometry",
            defaultWidth: 480,
            defaultHeight: 360,
            minWidth: 420,
            minHeight: 280
        )
    }

    @MainActor
    private func submit() {
        Task {
            do {
                try await appState.imageGen.enqueueCreate(prompt: prompt, width: width, height: height)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
