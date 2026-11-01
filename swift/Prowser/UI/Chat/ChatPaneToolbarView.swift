import SwiftUI

struct ChatPaneToolbarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let chat = appState.chat
        HStack(spacing: 4) {
            SidebarAssetIconButton(
                normalName: "prompt",
                hoverName: "prompt_hover",
                tooltip: "System prompt for chat\nOpen the system prompt library",
                action: { chat.editSystemPrompt() }
            )

            SidebarAssetIconButton(
                normalName: "copy_asst",
                hoverName: "copy_asst_hover",
                tooltip: """
                Copy images to Assistant's reply
                When enabled, assistant replies show the preceding user message images
                """,
                selected: chat.sessionSettings.copyImagesToAssistant,
                action: {
                    chat.setCopyImagesToAssistant(!chat.sessionSettings.copyImagesToAssistant)
                }
            )

            Spacer(minLength: 0)

            SidebarAssetIconButton(
                normalName: "trash_icon",
                hoverName: "trash_icon_hover",
                tooltip: "Clear Chat\nRemove all messages and attachments",
                action: { chat.clearChat() }
            )
        }
        .padding(.horizontal, 8)
        .padding(.top, 0)
        .padding(.bottom, 5)
        .background(appState.theme.colors.sidebarHeaderBackground.opacity(0.35))
    }
}
