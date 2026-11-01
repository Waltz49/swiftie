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

    @State private var promptText = ""
    @State private var attachmentPaths: [String] = []

    private static let automaticCreateTooltip =
        "When on, chat messages with images or /create automatically submit an image-generation job."

    var body: some View {
        let chat = appState.chat
        VStack(alignment: .leading, spacing: 4) {
            if !attachmentPaths.isEmpty {
                ChatMessageThumbRow(paths: attachmentPaths)
            }

            ZStack(alignment: .topLeading) {
                if promptText.isEmpty {
                    Text("Message… (Return to send, Shift+Return for newline)")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $promptText)
                    .frame(minHeight: 44, maxHeight: 140)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .disabled(!chat.promptInputEnabled)
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handleDrop(providers)
                    }
            }
            .padding(8)
            .background(appState.theme.colors.sidebarBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(appState.theme.colors.sidebarHeaderBorder)
            )
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) { return .ignored }
                if !chat.promptInputEnabled || chat.isStreaming { return .ignored }
                submit()
                return .handled
            }

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
            .disabled(!chat.promptInputEnabled)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 0)
        .onChange(of: appState.chat.pendingFavoritePromptText) { _, text in
            guard let text, !text.isEmpty else { return }
            promptText = text
            appState.chat.pendingFavoritePromptText = nil
            let paths = appState.chat.pendingFavoritePromptImagePaths
            if !paths.isEmpty {
                attachmentPaths = Array(paths.prefix(ChatSelectionImageTrigger.maxChatImages))
                appState.chat.pendingFavoritePromptImagePaths = []
            }
        }
    }

    @MainActor
    private func submit() {
        let text = promptText
        let paths = attachmentPaths
        promptText = ""
        attachmentPaths = []
        appState.chat.submitUserMessage(text: text, imagePaths: paths)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
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
                    if !attachmentPaths.contains(path), attachmentPaths.count < ChatSelectionImageTrigger.maxChatImages {
                        attachmentPaths.append(path)
                    }
                }
            }
        }
        return accepted
    }
}
