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
    @State private var composeKeyboardFocused = false

    private static let automaticCreateTooltip =
        "When on, chat messages with images or /create automatically submit an image-generation job."

    var body: some View {
        @Bindable var chat = appState.chat
        let colors = appState.theme.colors
        let composeFieldBackground = composeKeyboardFocused
            ? colors.chatEditableFieldBackground
            : colors.sidebarBackground
        VStack(alignment: .leading, spacing: 4) {
            if !chat.composeAttachmentPaths.isEmpty {
                ChatImageThumbRow(
                    paths: $chat.composeAttachmentPaths,
                    allowRemove: true,
                    canOpen: true
                )
            }

            ZStack(alignment: .topLeading) {
                if chat.composePromptText.isEmpty {
                    Text("Message…  (Enter to send, Shift+Enter for newline)")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                ChatComposePromptTextView(
                    text: $chat.composePromptText,
                    isKeyboardFocused: $composeKeyboardFocused,
                    textColor: colors.dialogText.nsColor,
                    unfocusedBackgroundColor: colors.sidebarBackground.nsColor,
                    focusedBackgroundColor: colors.chatEditableFieldBackground.nsColor,
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
            .background(composeFieldBackground)
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
        return ChatImageThumbDrop.acceptFileURLs(
            from: providers,
            imageExtensions: appState.config.imageExtensions,
            existingPaths: chat.composeAttachmentPaths,
            maxImages: ChatSelectionImageTrigger.maxChatImages
        ) { added in
            chat.composeAttachmentPaths.append(contentsOf: added)
        }
    }
}
