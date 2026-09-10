import SwiftUI

struct LeftSidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let chat = appState.chat
        let inBrowse = appState.fileData.currentViewMode == .browse
        let descriptors = [
            SidebarPaneDescriptor(
                index: 0,
                title: "File Tree",
                expandedConfigKey: "file_tree_visible",
                defaultExpanded: true,
                isDisplayed: !inBrowse,
                omitLeftBorder: true,
                contextMenuKind: .fileTree,
                preferredFitContentHeight: 180
            ),
            SidebarPaneDescriptor(
                index: 1,
                title: "Preview",
                expandedConfigKey: "preview_visible",
                defaultExpanded: true,
                isDisplayed: !inBrowse,
                omitLeftBorder: true,
                allowsTitlebarDrag: true,
                preferredFitContentHeight: 120
            ),
            SidebarPaneDescriptor(
                index: 2,
                title: "Chat",
                expandedConfigKey: "chat_visible",
                defaultExpanded: false,
                isDisplayed: BundleCapabilities.chatUIEnabled,
                status: chat.isStreaming ? "…" : nil,
                omitLeftBorder: true,
                allowsTitlebarDrag: true,
                contextMenuKind: .chat,
                preferredFitContentHeight: 160
            ),
        ]

        StackedSidebarPanesView(
            model: appState.leftSidebarSplit,
            descriptors: descriptors,
            pane0: { FileTreeView().frame(minHeight: 80) },
            pane1: { PreviewPaneView().frame(minHeight: 64) },
            pane2: { ChatPaneView().frame(minHeight: 80) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
