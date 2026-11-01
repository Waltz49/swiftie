import SwiftUI

struct ChatMessageListView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(appState.chat.messages) { message in
                        ChatMessageRowView(message: message)
                            .id(message.messageID)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .onChange(of: appState.chat.scrollToBottomToken) { _, _ in
                if let last = appState.chat.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.messageID, anchor: .bottom)
                    }
                }
            }
        }
    }
}
