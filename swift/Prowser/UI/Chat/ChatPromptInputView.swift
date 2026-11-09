import SwiftUI
import UniformTypeIdentifiers

enum ChatPromptInputLayout {
    /// Matches Python ``CURSOR_PEEK_ZONE_HEIGHT`` (status-bar peek band).
    static let cursorPeekZoneHeight: CGFloat = 35
    /// Matches Python ``CHAT_PROMPT_BOTTOM_PADDING_EXTRA_PX`` on the system prompt footer.
    static let systemPromptFooterBottomPadding: CGFloat = 10
}

struct ChatPromptInputView: View {
    @Environment(AppState.self) private var appState

    private static let automaticCreateTooltip =
        "When on, chat messages with images or /create automatically submit an image-generation job."

    var body: some View {
        @Bindable var chat = appState.chat
        let colors = appState.theme.colors
        VStack(alignment: .leading, spacing: 4) {
            if !chat.composeAttachmentPaths.isEmpty {
                ChatMessageThumbRow(paths: chat.composeAttachmentPaths)
            }

            ZStack(alignment: .topLeading) {
                if chat.composePromptText.isEmpty {
                    Text("Message… (⌘Return to send, Return for newline)")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                ChatComposePromptTextView(
                    text: $chat.composePromptText,
                    textColor: colors.dialogText.nsColor,
                    backgroundColor: colors.sidebarBackground.nsColor,
                    inputEnabled: chat.composeFieldEnabled,
                    isStreaming: chat.isStreaming,
                    onCommandReturn: {
                        guard chat.canSubmitUserMessage else { return }
                        submit()
                    },
                    onExitKeyboardFocus: {
                        appState.focusMainCanvas()
                    },
                    onTextChange: { chat.refreshComposeAttachmentsForSelectionTrigger(in: $0) }
                )
                .frame(minHeight: 44, maxHeight: 140)
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handleDrop(providers)
                    }
            }
            .padding(8)
            .background(colors.sidebarBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(colors.sidebarHeaderBorder)
            )

            SettingsPreferenceCompactToggleRow(
                title: "Submit Job Automatically",
                tooltip: Self.automaticCreateTooltip,
                titleColor: appState.theme.colors.sidebarHeaderText,
                expandLabel: true,
                isOn: Binding(
                    get: { chat.sessionSettings.automaticCreate },
                    set: { chat.setAutomaticCreate($0) }
                )
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .frame(height: ChatPromptInputLayout.cursorPeekZoneHeight)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 0)
    }

    @MainActor
    private func submit() {
        let chat = appState.chat
        let text = chat.composePromptText
        let paths = chat.composeAttachmentPaths
        chat.composePromptText = ""
        chat.composeAttachmentPaths = []
        appState.chat.submitUserMessage(text: text, imagePaths: paths)
    }

    @MainActor
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let chat = appState.chat
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.isFileURL else { return }
                let path = url.standardizedFileURL.path
                Task { @MainActor in
                    guard FileManager.default.isReadableFile(atPath: path) else { return }
                    if !chat.composeAttachmentPaths.contains(path),
                       chat.composeAttachmentPaths.count < ChatSelectionImageTrigger.maxChatImages {
                        chat.composeAttachmentPaths.append(path)
                    }
                }
            }
        }
        return accepted
    }
}
