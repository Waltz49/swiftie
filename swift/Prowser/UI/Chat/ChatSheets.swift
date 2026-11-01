import SwiftUI

struct ChatTipsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chat Tips")
                .font(.headline)
                .padding()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    tipBlock("Images", "Drag and drop image files onto the prompt field or onto a message bubble.")
                    tipBlock("/source", "Type /source in a user message to copy source image references onto the assistant reply without starting generation.")
                    tipBlock("{}", "Include the two-character token {} in your message to attach the current browse/thumbnail selection (up to four images).")
                    tipBlock("Editing", "Double-click message text to edit. Drop images while editing to attach them.")
                    tipBlock("Thumbnails", "Click message thumbnails to open those images in the browser.")
                    tipBlock("Keyboard", "F9 or comma toggles the chat pane. Command+R redoes the last user message when chat is visible.")
                }
                .padding(.horizontal)
            }
            DialogButtonRow([DialogButton("OK", isDefault: true) { dismiss() }])
                .padding()
        }
        .frame(minWidth: 680, minHeight: 360)
    }

    private func tipBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            Text(body)
        }
    }
}

/// Port of ``run_chat_favorite_user_prompts`` / ``ChatFavoriteUserPromptsDialog`` (simplified).
struct ChatUserPromptLibrarySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var config = ChatUserPromptStore.Config(selectedFavoriteID: "", favoritePrompts: [])
    @State private var selectedID = ""
    @State private var previewText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Favorite user prompts")
                .font(.headline)
                .padding()
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $previewText)
                    .frame(minHeight: 100, maxHeight: 140)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(config.favoritePrompts) { item in
                            Button {
                                selectedID = item.id
                                previewText = item.text
                            } label: {
                                HStack {
                                    Image(systemName: selectedID == item.id ? "largecircle.fill.circle" : "circle")
                                    VStack(alignment: .leading) {
                                        Text(item.label).font(.subheadline.bold())
                                        Text(item.text).font(.caption).lineLimit(2)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            .padding(.horizontal)
            DialogButtonRow(
                [
                    DialogButton("Cancel", isCancel: true) { dismiss() },
                    DialogButton("OK", isDefault: true) {
                        guard let item = config.favoritePrompts.first(where: { $0.id == selectedID }) else {
                            dismiss()
                            return
                        }
                        NotificationCenter.default.post(
                            name: .prowserChatInsertUserPrompt,
                            object: nil,
                            userInfo: ["text": item.text, "paths": item.imagePaths]
                        )
                        dismiss()
                    },
                ]
            )
            .padding()
        }
        .frame(minWidth: 520, minHeight: 400)
        .onAppear {
            config = ChatUserPromptStore.load(dataDirectory: appState.config.dataDirectory)
            selectedID = config.selectedFavoriteID
            if let first = config.favoritePrompts.first(where: { $0.id == selectedID })
                ?? config.favoritePrompts.first {
                selectedID = first.id
                previewText = first.text
            }
        }
    }
}

extension Notification.Name {
    static let prowserChatInsertUserPrompt = Notification.Name("prowser.chatInsertUserPrompt")
}
