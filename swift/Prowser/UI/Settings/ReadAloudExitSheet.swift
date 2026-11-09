import SwiftUI

@MainActor
struct ReadAloudExitSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDialog) private var closeDialog
    @Environment(AppState.self) private var appState

    private static let testPhraseHelp = "Speaks a short test phrase through the script field above."

    var body: some View {
        let _ = appState.config.settingsEditRevision
        @Bindable var chat = appState.chat
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("Read aloud exit")
                    .font(.system(size: 15, weight: .regular))
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Use read aloud exit")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(SettingsDialogChrome.rowTitle)
                    Text("Run the configured script when speak is triggered.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(SettingsDialogChrome.secondaryText)
                        .multilineTextAlignment(.trailing)
                }
                SettingsPreferenceSwitch(isOn: useReadAloudExitBinding)
            }

            Text(
                "An implicit -p parameter passes the text; add your own parameters as needed."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ExitScriptCommandRow(
                title: "Script",
                subtitle: "Example: python ~/scripts/say_exit.py --voice Joe --rate 1.2",
                text: $chat.readAloudExitCommandDraft
            )

            DialogButtonRow([
                DialogButton("Cancel", isCancel: true) { closeDialog(); dismiss() },
                DialogButton("OK", isDefault: true) {
                    let normalized = normalizedCommand(chat.readAloudExitCommandDraft)
                    chat.readAloudExitCommandDraft = normalized.display
                    appState.config.persistTopLevelSettingKeys([
                        ExitScriptUtils.settingSayExit: normalized.stored,
                    ])
                    appState.config.applySettingsChange(emit: appState.eventBus)
                    closeDialog()
                    dismiss()
                },
            ], leadingButtons: [
                DialogButton("Test", isEnabled: testButtonEnabled(chat.readAloudExitCommandDraft), help: Self.testPhraseHelp) {
                    runTest(draft: chat.readAloudExitCommandDraft)
                },
            ], focusDefaultOnAppear: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 520, minHeight: 220)
        .persistedDialogGeometry(
            DialogGeometryKey.readAloudExit,
            defaultWidth: 560,
            defaultHeight: 260,
            minWidth: 520,
            minHeight: 220
        )
    }

    private var useReadAloudExitBinding: Binding<Bool> {
        Binding(
            get: {
                appState.config.bool(forKey: ExitScriptUtils.useReadAloudExitKey, default: false)
            },
            set: { newValue in
                appState.config.persistTopLevelSettingKeys([
                    ExitScriptUtils.useReadAloudExitKey: newValue,
                ])
                appState.config.applySettingsChange(emit: appState.eventBus)
            }
        )
    }

    private func normalizedCommand(_ raw: String) -> (display: String, stored: String) {
        let display = SettingsPathValidation.normalizedExitScriptCommandDisplay(raw)
        let stored = SettingsPathValidation.normalizedStoredExitScriptCommand(raw)
        return (display, stored)
    }

    private func testButtonEnabled(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return ExitScriptUtils.validateExitScriptCommand(trimmed).valid
    }

    private func runTest(draft: String) {
        let normalized = normalizedCommand(draft)
        appState.chat.readAloudExitCommandDraft = normalized.display
        if let message = SpeechReader.testReadAloudExit(rawCommand: normalized.stored, config: appState.config) {
            appState.status.show(message)
        }
    }
}

/// Shared path row for exit-script settings dialogs.
struct ExitScriptCommandRow: View {
    let title: String
    let subtitle: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("python /path/to/script.py", text: $text)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") {
                    SettingsSupport.pickFile(into: $text, allowedTypes: ["py", "sh", ""])
                }
                let validation = ExitScriptUtils.validateExitScriptCommand(text)
                if validation.message.isEmpty {
                    SettingsPathValidationIndicator(state: .empty)
                } else if validation.valid {
                    SettingsPathValidationIndicator(state: .valid(tooltip: validation.message))
                } else {
                    SettingsPathValidationIndicator(state: .invalid(tooltip: validation.message))
                }
            }
        }
    }
}
