import SwiftUI

struct ChatPaneView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var chat = appState.chat

        VStack(spacing: 0) {
            if !chat.isEnabled {
                chatUnavailableBanner
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.messages) { message in
                            ChatMessageBubbleView(
                                chat: chat,
                                message: message,
                                isStreamingPlaceholder: message.id == chat.messages.last?.id
                                    && chat.isStreaming
                                    && message.isAssistant
                            )
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: chat.messages.count) { _, _ in
                    if let last = chat.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onChange(of: chat.messages.last?.text) { _, _ in
                    if let last = chat.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if !chat.lastError.isEmpty {
                Text(chat.lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
            }

            ChatPromptInputView(chat: chat)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                .background(MainWindowChatTabStopView())

            Text("System prompt: \(chat.systemPromptLabel)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $chat.showSystemPromptSheet) {
            ChatSystemPromptLibrarySheet(
                store: ChatPromptConfig.SystemPromptStore.load(
                    dataDirectory: appState.config.dataDirectory
                )
            )
            .environment(appState)
        }
    }

    private var chatUnavailableBanner: some View {
        HStack(spacing: 8) {
            Text("Chat requires Python workers and LM Studio.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }
}
