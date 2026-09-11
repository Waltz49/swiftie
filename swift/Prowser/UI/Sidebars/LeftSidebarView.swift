import SwiftUI

struct LeftSidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let chat = appState.chat
        let displayVis = SidebarPaneSplitModel.leftDisplayPaneVisibility(appState: appState)
        let descriptors = [
            SidebarPaneDescriptor(
                index: 0,
                title: "File Tree",
                expandedConfigKey: "file_tree_visible",
                defaultExpanded: true,
                isDisplayed: displayVis[0],
                omitLeftBorder: true,
                contextMenuKind: .fileTree,
                preferredFitContentHeight: { 180 }
            ),
            SidebarPaneDescriptor(
                index: 1,
                title: "Preview",
                expandedConfigKey: "preview_visible",
                defaultExpanded: true,
                isDisplayed: displayVis[1],
                omitLeftBorder: true,
                allowsTitlebarDrag: true,
                preferredFitContentHeight: { appState.previewPanePreferredContentHeight() }
            ),
            SidebarPaneDescriptor(
                index: 2,
                title: "Chat",
                expandedConfigKey: "chat_visible",
                defaultExpanded: false,
                isDisplayed: displayVis[2],
                status: chat.isStreaming ? "…" : nil,
                omitLeftBorder: true,
                allowsTitlebarDrag: true,
                contextMenuKind: .chat,
                preferredFitContentHeight: { 160 }
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
