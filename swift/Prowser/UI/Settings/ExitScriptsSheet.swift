import SwiftUI

@MainActor
struct ExitScriptsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDialog) private var closeDialog
    @Environment(AppState.self) private var appState

    @State private var textAIExit = ""
    @State private var imageAIExit = ""

    private static let usePromptFilterExitsKey = "use_prompt_filter_exits"

    var body: some View {
        let _ = appState.config.settingsEditRevision
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("Exit Scripts")
                    .font(.system(size: 15, weight: .regular))
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Use prompt filter exits")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(SettingsDialogChrome.rowTitle)
                    Text("Use exit scripts to modify prompt data before model calls.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(SettingsDialogChrome.secondaryText)
                        .multilineTextAlignment(.trailing)
                }
                SettingsPreferenceSwitch(isOn: usePromptFilterExitsBinding)
            }

            exitScriptRow(title: "Text AI exit", subtitle: "LM Studio / caption prompts", text: $textAIExit)
            exitScriptRow(title: "Image AI exit", subtitle: "Image generation prompts", text: $imageAIExit)

            DialogButtonRow([
                DialogButton("Cancel", isCancel: true) { closeDialog(); dismiss() },
                DialogButton("OK", isDefault: true) {
                    SettingsPathValidation.commitPendingPathFieldEdits()
                    appState.config.setValue(
                        SettingsPathValidation.normalizedStoredExitScriptCommand(textAIExit),
                        forKey: ExitScriptUtils.settingTextAIExit
                    )
                    appState.config.setValue(
                        SettingsPathValidation.normalizedStoredExitScriptCommand(imageAIExit),
                        forKey: ExitScriptUtils.settingImageAIExit
                    )
                    appState.config.applySettingsChange(emit: appState.eventBus)
                    closeDialog()
                    dismiss()
                },
            ], focusDefaultOnAppear: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 520, minHeight: 240)
        .persistedDialogGeometry(
            DialogGeometryKey.exitScripts,
            defaultWidth: 560,
            defaultHeight: 280,
            minWidth: 520,
            minHeight: 240
        )
        .onAppear {
            textAIExit = SettingsPathValidation.normalizedExitScriptCommandDisplay(
                appState.config.string(forKey: ExitScriptUtils.settingTextAIExit)
            )
            imageAIExit = SettingsPathValidation.normalizedExitScriptCommandDisplay(
                appState.config.string(forKey: ExitScriptUtils.settingImageAIExit)
            )
        }
    }

    private var usePromptFilterExitsBinding: Binding<Bool> {
        SettingsSupport.boolBinding(
            config: appState.config,
            key: Self.usePromptFilterExitsKey,
            default: false,
            onChange: {
                appState.config.applySettingsChange(emit: appState.eventBus)
            }
        )
    }

    @ViewBuilder
    private func exitScriptRow(title: String, subtitle: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            HStack {
                SettingsPathTextField(
                    title: "python /path/to/script.py",
                    text: text,
                    exitScriptCommand: true
                )
                Button("Browse…") {
                    SettingsSupport.pickFile(into: text, allowedTypes: ["py", "sh", ""])
                }
                let validation = ExitScriptUtils.validateExitScriptCommand(text.wrappedValue)
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
