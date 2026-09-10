import SwiftUI

struct RightSidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let imageGen = appState.imageGen
        let jobsTitle = "Job Control" + imageGen.jobsPaneTitleSuffix()
        let descriptors = [
            SidebarPaneDescriptor(
                index: 0,
                title: "Organize",
                expandedConfigKey: "shortcuts_sidebar_visible",
                defaultExpanded: true,
                isDisplayed: true,
                omitLeftBorder: true,
                preferredFitContentHeight: 140
            ),
            SidebarPaneDescriptor(
                index: 1,
                title: "File Information",
                expandedConfigKey: "information_sidebar_visible",
                defaultExpanded: true,
                isDisplayed: true,
                allowsTitlebarDrag: true,
                contextMenuKind: .information,
                preferredFitContentHeight: 180
            ),
            SidebarPaneDescriptor(
                index: 2,
                title: jobsTitle,
                expandedConfigKey: "jobs_visible",
                defaultExpanded: true,
                isDisplayed: BundleCapabilities.imageGenUIEnabled && appState.jobsDisplayMode == .pane,
                status: imageGen.jobsHeaderStatusText().isEmpty ? nil : imageGen.jobsHeaderStatusText(),
                allowsTitlebarDrag: true,
                isJobsPane: true,
                showsFlyoutButton: true,
                contextMenuKind: .jobs(floating: false),
                preferredFitContentHeight: appState.jobsQueuePaneContentHeight()
            ),
        ]

        StackedSidebarPanesView(
            model: appState.rightSidebarSplit,
            descriptors: descriptors,
            pane0: { ShortcutsSidebarView() },
            pane1: { InformationPaneView().frame(minHeight: 80) },
            pane2: { JobQueuePanelView().frame(minHeight: 60) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
