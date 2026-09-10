import SwiftUI

struct ChatPaneView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let chat = appState.chat

        VStack(alignment: .leading, spacing: 8) {
            // Titlebar is provided by SidebarPaneSection in LeftSidebarView.
            if chat.isStreaming || !appState.chatToolbarVisible {
                HStack {
                    Spacer()
                    if chat.isStreaming {
                        Button("Stop") { chat.cancel() }
                    } else if !chat.messages.isEmpty, !appState.chatToolbarVisible {
                        Button("Clear") { chat.clear() }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
            }

            if !chat.isEnabled {
                Text("Chat requires Python workers and LM Studio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.messages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    if let last = chat.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if !chat.lastError.isEmpty {
                Text(chat.lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(alignment: .bottom) {
                TextField("Message", text: Binding(
                    get: { chat.draft },
                    set: { chat.draft = $0 }
                ), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(!chat.isEnabled || chat.isStreaming)
                .onSubmit { chat.send() }

                Button("Send") { chat.send() }
                    .disabled(!chat.isEnabled || chat.isStreaming || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 2) {
            Text(message.role == "user" ? "You" : "Assistant")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(message.text.isEmpty ? "…" : message.text)
                .font(.body)
                .textSelection(.enabled)
                .padding(8)
                .background(message.role == "user" ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
    }
}
