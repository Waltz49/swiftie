import SwiftUI

enum ChatPaneLayout {
    static let minContentHeight: CGFloat = 80
    static let systemPromptFooterBottomPadding = ChatPromptInputLayout.systemPromptFooterBottomPadding
}

struct ChatPaneView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let chat = appState.chat
        VStack(spacing: 0) {
            if chat.showToolbar {
                ChatPaneToolbarView()
            }

            if chat.showUnavailableOnly {
                VStack(spacing: 12) {
                    Spacer(minLength: 8)
                    Text(ChatCopy.lmStudioUnavailableMessage(config: appState.config))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(appState.theme.colors.sidebarHeaderText)
                        .padding(.horizontal, 16)
                    Button("LM Studio") {
                        appState.openLmStudioOrShowInstallHelp()
                    }
                    .keyboardShortcut(.defaultAction)
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ChatMessageListView()
                ChatPromptInputView()
                Text("System prompt: \(chat.systemPromptLabel)")
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.top, 0)
                    .padding(.bottom, ChatPaneLayout.systemPromptFooterBottomPadding)
                    .foregroundStyle(appState.theme.colors.sidebarMutedText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appState.theme.colors.sidebarBackground)
        .onAppear {
            chat.onPaneAppear()
            ChatKeyboardMonitor.shared.install(appState: appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.chat.showSystemPromptLibrary },
            set: { appState.chat.showSystemPromptLibrary = $0 }
        )) {
            ChatSystemPromptLibrarySheet()
                .environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.chat.showUserPromptLibrary },
            set: { appState.chat.showUserPromptLibrary = $0 }
        )) {
            ChatUserPromptLibrarySheet()
                .environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.chat.showTips },
            set: { appState.chat.showTips = $0 }
        )) {
            ChatTipsSheet()
        }
        .sheet(isPresented: Binding(
            get: { appState.chat.showPrefixPostfixLibrary },
            set: { appState.chat.showPrefixPostfixLibrary = $0 }
        )) {
            PrefixPostfixSheet()
                .environment(appState)
        }
    }
}
