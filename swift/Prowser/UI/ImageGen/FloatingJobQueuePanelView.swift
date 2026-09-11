import AppKit
import SwiftUI

struct FloatingJobQueuePanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = appState.imageGenUIRevision
        VStack(spacing: 0) {
            HStack {
                Text("Job Control" + appState.imageGen.jobsPaneTitleSuffix())
                    .font(.headline)
                if !appState.imageGen.jobsHeaderStatusText().isEmpty {
                    Text(appState.imageGen.jobsHeaderStatusText())
                        .font(.headline)
                        .foregroundStyle(appState.theme.colors.sidebarHeaderText.opacity(0.85))
                }
                Spacer()
                SidebarPaneToolsMenuButton(kind: .jobs(floating: true))
                    .foregroundStyle(appState.theme.colors.sidebarHeaderText)
                Button {
                    appState.hideJobsPanel()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close floating job panel (⌘J)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(appState.theme.colors.sidebarHeaderBackground)

            SidebarPaneBody(kind: .jobs(floating: true)) {
                JobQueuePanelView(compactForFloating: true)
                    .frame(minWidth: 260, minHeight: 180)
            }
        }
        .background(appState.theme.colors.sidebarBackground)
        .persistedDialogGeometry(
            DialogGeometryKey.jobQueue,
            defaultWidth: 320,
            defaultHeight: 420,
            minWidth: 260,
            minHeight: 220,
            nestedInImageGen: true,
            windowTitle: "Job Control",
            alwaysOnTop: appState.jobsPanelAlwaysOnTop
        )
        .onAppear {
            appState.syncJobsPaneGeometry()
        }
        .onDisappear {
            appState.hideJobsPanel()
        }
        .onChange(of: appState.jobsQueueSizeMode) { _, _ in
            appState.syncJobsPaneGeometry()
        }
    }
}
