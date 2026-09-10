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

            TextField("Prompt", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)

            HStack {
                Stepper("Width: \(width)", value: $width, in: 512...1536, step: 64)
                Stepper("Height: \(height)", value: $height, in: 512...1536, step: 64)
            }

            if !errorMessage.isEmpty {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Generate") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    @MainActor
    private func submit() {
        do {
            try appState.imageGen.enqueueCreate(prompt: prompt, width: width, height: height)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
