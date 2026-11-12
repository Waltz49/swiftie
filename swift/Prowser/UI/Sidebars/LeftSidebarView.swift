import SwiftUI

struct LeftSidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let mountedVis = SidebarPaneSplitModel.leftMountedPaneVisibility(appState: appState)
        let descriptors = [
            SidebarPaneDescriptor(
                index: 0,
                title: "File Tree",
                expandedConfigKey: "file_tree_visible",
                defaultExpanded: true,
                isDisplayed: mountedVis[0],
                omitLeftBorder: true,
                contextMenuKind: .fileTree,
                keepContentMountedWhenCollapsed: true,
                preferredFitContentHeight: { 180 }
            ),
            SidebarPaneDescriptor(
                index: 1,
                title: "Preview",
                expandedConfigKey: "preview_visible",
                defaultExpanded: true,
                isDisplayed: mountedVis[1],
                omitLeftBorder: true,
                allowsTitlebarDrag: true,
                preferredFitContentHeight: { appState.previewPanePreferredContentHeight() }
            ),
            SidebarPaneDescriptor(
                index: 2,
                title: "",
                expandedConfigKey: "chat_visible",
                defaultExpanded: false,
                isDisplayed: mountedVis[2],
                omitLeftBorder: true,
                contextMenuKind: .chat,
                preferredFitContentHeight: { appState.chat.preferredSidebarContentHeight() }
            ),
        ]

        StackedSidebarPanesView(
            model: appState.leftSidebarSplit,
            descriptors: descriptors,
            pane0: { FileTreeView().frame(minHeight: 80) },
            pane1: { PreviewPaneView().frame(minHeight: 64) },
            pane2: { ChatPaneView().frame(minHeight: ChatPaneLayout.minContentHeight) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
