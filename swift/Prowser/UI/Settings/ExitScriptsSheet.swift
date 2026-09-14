import SwiftUI

@MainActor
struct ExitScriptsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var textAIExit = ""
    @State private var imageAIExit = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Exit Scripts")
                .font(.title2)
            Text("External scripts run before model calls when prompt filter exits are enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)

            exitScriptRow(title: "Text AI exit", subtitle: "LM Studio / caption prompts", text: $textAIExit)
            exitScriptRow(title: "Image AI exit", subtitle: "Image generation prompts", text: $imageAIExit)

            DialogButtonRow([
                DialogButton("Cancel", isCancel: true) { dismiss() },
                DialogButton("OK", isDefault: true) {
                    appState.config.setValue(textAIExit, forKey: ExitScriptUtils.settingTextAIExit)
                    appState.config.setValue(imageAIExit, forKey: ExitScriptUtils.settingImageAIExit)
                    appState.config.applySettingsChange(emit: appState.eventBus)
                    dismiss()
                },
            ], focusDefaultOnAppear: true)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 240)
        .onAppear {
            textAIExit = appState.config.string(forKey: ExitScriptUtils.settingTextAIExit)
            imageAIExit = appState.config.string(forKey: ExitScriptUtils.settingImageAIExit)
        }
    }

    @ViewBuilder
    private func exitScriptRow(title: String, subtitle: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("python /path/to/script.py", text: text)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") {
                    SettingsSupport.pickFile(into: text, allowedTypes: ["py", "sh", ""])
                }
                let validation = ExitScriptUtils.validateExitScriptCommand(text.wrappedValue)
                Image(systemName: validation.valid ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(validation.valid ? .green : .orange)
                    .help(validation.message)
            }
        }
    }
}
