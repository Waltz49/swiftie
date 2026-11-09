import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ChatMessageRowView: View {
    @Environment(AppState.self) private var appState
    let message: ChatMessage

    @State private var editText = ""
    @State private var editKeyboardFocused = false
    @State private var speakHighlighted = false

    private var isUser: Bool { message.role == .user }
    private var isEditing: Bool { appState.chat.editingMessageID == message.messageID }

    var body: some View {
        let colors = appState.theme.colors
        let chat = appState.chat
        VStack(alignment: .leading, spacing: 4) {
            messageBubble(colors: colors, chat: chat)
            messageActionBar(chat: chat)
        }
        .padding(.horizontal, ChatMessageChrome.outerHorizontalPadding)
        .padding(.vertical, ChatMessageChrome.outerVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func messageBubble(colors: ThemeColors, chat: ChatController) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if isEditing, messageSupportsAttachments {
                ChatImageThumbRow(
                    paths: Binding(
                        get: { chat.messageEditImagePaths },
                        set: { chat.messageEditImagePaths = $0 }
                    ),
                    allowRemove: true
                )
            } else if !message.imagePaths.isEmpty {
                ChatImageThumbRow(
                    paths: .constant(message.imagePaths),
                    allowRemove: false
                )
            }

            if isEditing {
                let editUnfocusedBackground = isUser
                    ? colors.jobQueueCellBackground
                    : colors.sidebarBackground
                let editFieldBackground = editKeyboardFocused
                    ? colors.chatEditableFieldBackground
                    : editUnfocusedBackground
                ChatMessageEditTextView(
                    text: $editText,
                    isKeyboardFocused: $editKeyboardFocused,
                    seedText: message.text,
                    textColor: colors.dialogText.nsColor,
                    unfocusedBackgroundColor: editUnfocusedBackground.nsColor,
                    focusedBackgroundColor: colors.chatEditableFieldBackground.nsColor,
                    onCommandReturn: { commitEdit() },
                    onEscape: { appState.chat.cancelMessageEdit() },
                    onTextChange: { appState.chat.syncPendingEditText($0) }
                )
                .id(message.messageID)
                .background(editFieldBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(colors.defaultBorder, lineWidth: 1)
                )
                HStack(spacing: 8) {
                    Button("Save") { commitEdit() }
                    Button("Cancel") { appState.chat.cancelMessageEdit() }
                }
                .font(.caption)
            } else {
                ChatMessageBodyTextView(
                    text: message.text,
                    textColor: colors.dialogText.nsColor,
                    onDoubleClick: { Task { @MainActor in beginEdit() } }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(bubbleBackground(colors: colors))
        .overlay(bubbleBorder(colors: colors))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleMessageImageDrop(providers)
        }
    }

    private var messageSupportsAttachments: Bool {
        message.role == .user || message.role == .assistant
    }

    @ViewBuilder
    private func bubbleBackground(colors: ThemeColors) -> some View {
        if isUser {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(colors.jobQueueCellBackground)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func bubbleBorder(colors: ThemeColors) -> some View {
        if isUser {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(colors.sidebarHeaderBorder, lineWidth: 2)
        } else {
            EmptyView()
        }
    }

    @MainActor
    @ViewBuilder
    private func messageActionBar(chat: ChatController) -> some View {
        let imageGenEnabled = appState.imageGen.isEnabled && BundleCapabilities.imageGenUIEnabled
        let createFromTextEnabled = imageGenEnabled
        let audioEnabled = !BundleCapabilities.isMinBundle
        let isStreamingAssistant = chat.streamingAssistantMessageID == message.messageID

        HStack(spacing: 4) {
            Spacer(minLength: 0)

            if !isUser, createFromTextEnabled, !message.text.isEmpty {
                ChatMessageIconButton(
                    normalName: "fromText",
                    hoverName: "fromText_hover",
                    tooltip: """
                    Create an image from text with
                    this message as the prompt
                    (⌥-click to generate immediately)
                    """,
                    action: { Task { @MainActor in createFromText(optionHeld: NSEvent.modifierFlags.contains(.option)) } }
                )
            }

            if !isUser, isStreamingAssistant {
                ChatMessageStopButton {
                    Task { @MainActor in chat.stopGeneration() }
                }
            }

            if isUser {
                ChatMessageIconButton(
                    normalName: "chatfav",
                    hoverName: "chatfav_hover",
                    tooltip: "Save as favorite user prompt",
                    action: { Task { @MainActor in chat.saveUserMessageAsFavorite(messageID: message.messageID) } }
                )
            }

            if audioEnabled, !message.text.isEmpty {
                ChatMessageIconButton(
                    normalName: "bullhorn",
                    hoverName: "bullhorn_hover",
                    tooltip: "Read message aloud (click again to stop)",
                    highlighted: speakHighlighted,
                    action: {
                        Task { @MainActor in
                            SpeechReader.speakOrStop(message.text) {
                                speakHighlighted = SpeechReader.isSpeaking
                            }
                        }
                    }
                )
            }

            ChatMessageIconButton(
                normalName: "edit_icon",
                hoverName: "edit_icon_hover",
                tooltip: "Edit message",
                action: { Task { @MainActor in beginEdit() } }
            )

            ChatMessageIconButton(
                normalName: "dim_reverse_icon",
                hoverName: "dim_reverse_icon_hover",
                tooltip: "Regenerate response",
                action: { Task { @MainActor in chat.redoMessage(messageID: message.messageID) } }
            )

            ChatMessageIconButton(
                normalName: "trash_icon",
                hoverName: "trash_icon_hover",
                tooltip: "Delete message",
                action: { Task { @MainActor in chat.deleteMessage(messageID: message.messageID) } }
            )
        }
        .padding(.horizontal, 4)
    }

    @MainActor
    private func createFromText(optionHeld: Bool) {
        let prompt = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let paths = ChatImagePaths.pathsForImageGen(message)
        if paths.isEmpty {
            appState.openImageGenDialog(
                function: "create",
                initialPrompt: prompt,
                autoGenerate: optionHeld
            )
        } else if appState.chat.sessionSettings.copyImagesToAssistant {
            appState.openImageGenDialog(
                function: "infill",
                initialPrompt: prompt,
                autoGenerate: optionHeld,
                editSourcePaths: paths
            )
        } else {
            appState.openImageGenDialog(
                function: "create",
                initialPrompt: prompt,
                autoGenerate: optionHeld
            )
        }
    }

    @MainActor
    private func beginEdit() {
        editKeyboardFocused = false
        editText = message.text
        appState.chat.beginMessageEdit(
            messageID: message.messageID,
            text: message.text,
            imagePaths: message.imagePaths
        )
    }

    @MainActor
    private func commitEdit() {
        appState.chat.syncPendingEditText(editText)
        appState.chat.commitPendingMessageEditIfNeeded()
    }

    @MainActor
    private func handleMessageImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard messageSupportsAttachments else { return false }
        if !isEditing {
            beginEdit()
        }
        let chat = appState.chat
        return ChatImageThumbDrop.acceptFileURLs(
            from: providers,
            imageExtensions: appState.config.imageExtensions,
            existingPaths: chat.messageEditImagePaths,
            maxImages: ChatSelectionImageTrigger.maxChatImages
        ) { added in
            chat.messageEditImagePaths.append(contentsOf: added)
        }
    }
}

extension Notification.Name {
    static let prowserChatOpenImagePaths = Notification.Name("prowser.chatOpenImagePaths")
}
