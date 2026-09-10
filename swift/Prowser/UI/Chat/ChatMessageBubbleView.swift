import SwiftUI

@MainActor
struct ChatMessageBubbleView: View {
    @Environment(AppState.self) private var appState
    @Bindable var chat: ChatController
    let message: ChatMessage
    let isStreamingPlaceholder: Bool

    @State private var editText = ""
    @State private var editImagePaths: [String] = []
    @FocusState private var editFocused: Bool

    private var isEditing: Bool {
        chat.editingMessageID == message.id
    }

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
            bubbleContent
            actionRow
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        .onAppear {
            editText = message.text
            editImagePaths = message.imagePaths
        }
        .onChange(of: message.text) { _, newValue in
            if !isEditing {
                editText = newValue
            }
        }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.imagePaths.isEmpty, !isEditing {
                ChatImageThumbRow(paths: message.imagePaths)
            }
            if isEditing {
                if !editImagePaths.isEmpty {
                    ChatImageThumbRow(
                        paths: editImagePaths,
                        allowRemove: true,
                        onRemove: { editImagePaths.remove(at: $0) }
                    )
                }
                TextEditor(text: $editText)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 160)
                    .focused($editFocused)
                    .onAppear { editFocused = true }
            } else {
                Text(displayText)
                    .font(.body)
                    .textSelection(.enabled)
                    .onTapGesture(count: 2) { beginEdit() }
            }
        }
        .padding(8)
        .background(message.isUser ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }

    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 8) {
            if message.isAssistant, !isStreamingPlaceholder, !displayText.isEmpty, displayText != "…" {
                Button("Create") {
                    chat.createFromAssistantText(
                        message.text,
                        sourcePaths: message.imagePaths,
                        autoGenerate: false
                    )
                }
                .font(.caption)
            }
            if isStreamingPlaceholder, chat.isStreaming {
                Button("Stop") { chat.cancel() }
                    .font(.caption)
            }
            Spacer(minLength: 0)
            if isEditing {
                Button("Save") { saveEdit() }.font(.caption)
                Button("Cancel") { cancelEdit() }.font(.caption)
            } else if !isStreamingPlaceholder {
                Button("Edit") { beginEdit() }
                    .font(.caption)
                    .disabled(chat.isStreaming)
                if message.isUser || message.isAssistant {
                    Button("Redo") { chat.redoMessage(message.id) }
                        .font(.caption)
                        .disabled(chat.isStreaming)
                }
                Button("Delete") { chat.deleteMessage(message.id) }
                    .font(.caption)
                    .disabled(chat.isStreaming)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var displayText: String {
        let text = message.text
        if text.isEmpty || text == "…" { return "…" }
        return text
    }

    private func beginEdit() {
        guard !chat.isStreaming else { return }
        if let editingID = chat.editingMessageID, editingID != message.id {
            chat.endEditing()
        }
        editText = message.text
        editImagePaths = message.imagePaths
        chat.beginEditing(message.id)
    }

    private func saveEdit() {
        chat.saveEditedMessage(message.id, text: editText, imagePaths: editImagePaths)
    }

    private func cancelEdit() {
        editText = message.text
        editImagePaths = message.imagePaths
        chat.endEditing()
    }
}
