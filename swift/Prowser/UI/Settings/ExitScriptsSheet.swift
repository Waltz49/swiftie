import SwiftUI

@MainActor
struct ExitScriptsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDialog) private var closeDialog
    @Environment(AppState.self) private var appState

    private static let usePromptFilterExitsKey = "use_prompt_filter_exits"

    var body: some View {
        @Bindable var chat = appState.chat
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

            ExitScriptCommandRow(
                title: "Text AI exit",
                subtitle: "LM Studio / caption prompts",
                text: $chat.textAIExitDraft
            )
            ExitScriptCommandRow(
                title: "Image AI exit",
                subtitle: "Image generation prompts",
                text: $chat.imageAIExitDraft
            )

            DialogButtonRow([
                DialogButton("Cancel", isCancel: true) { closeDialog(); dismiss() },
                DialogButton("OK", isDefault: true) {
                    let textStored = SettingsPathValidation.normalizedStoredExitScriptCommand(chat.textAIExitDraft)
                    let imageStored = SettingsPathValidation.normalizedStoredExitScriptCommand(chat.imageAIExitDraft)
                    chat.textAIExitDraft = SettingsPathValidation.normalizedExitScriptCommandDisplay(chat.textAIExitDraft)
                    chat.imageAIExitDraft = SettingsPathValidation.normalizedExitScriptCommandDisplay(chat.imageAIExitDraft)
                    appState.config.setValue(textStored, forKey: ExitScriptUtils.settingTextAIExit)
                    appState.config.setValue(imageStored, forKey: ExitScriptUtils.settingImageAIExit)
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
}
