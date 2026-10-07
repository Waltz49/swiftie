import AppKit
import SwiftUI

struct FloatingJobQueuePanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Matches ``SidebarPaneTitlebar`` (30pt header).
    private static let titlebarHeight: CGFloat = 30

    var body: some View {
        let _ = appState.imageGenUIRevision
        let colors = appState.theme.colors
        VStack(spacing: 0) {
            ZStack {
                WindowDragArea()
                    .frame(maxWidth: .infinity, maxHeight: Self.titlebarHeight)
                HStack(spacing: 8) {
                    Text("Job Control" + appState.imageGen.jobsPaneTitleSuffix())
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(colors.sidebarHeaderText)
                        .lineLimit(1)
                    if !appState.imageGen.jobsHeaderStatusText().isEmpty {
                        Text(appState.imageGen.jobsHeaderStatusText())
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(colors.sidebarHeaderText.opacity(0.85))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    SidebarPaneToolsMenuButton(kind: .jobs(floating: true))
                        .foregroundStyle(colors.sidebarHeaderText)
                    Button {
                        appState.hideJobsPanel()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .help("Close floating job panel (⌘J)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .frame(height: Self.titlebarHeight)
            .frame(maxWidth: .infinity)
            .background(colors.sidebarHeaderBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(colors.sidebarHeaderBorder)
                    .frame(height: 1)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(colors.sidebarHeaderBorder)
                    .frame(height: 1)
            }

            SidebarPaneBody(kind: .jobs(floating: true)) {
                JobQueuePanelView(compactForFloating: true)
                    .frame(minWidth: 260, minHeight: 180)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(appState.theme.colors.sidebarBackground)
        .ignoresSafeArea(.container, edges: .top)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .persistedDialogGeometry(
            DialogGeometryKey.jobQueue,
            defaultWidth: 320,
            defaultHeight: 420,
            minWidth: 260,
            minHeight: 220,
            nestedInImageGen: true,
            windowIdentifier: "jobs-panel",
            windowTitle: "Job Control",
            alwaysOnTop: appState.jobsPanelAlwaysOnTop,
            hidesStandardWindowButtons: true
        )
        .onChange(of: appState.jobsPanelAlwaysOnTop) { _, enabled in
            applyJobsPanelWindowLevel(alwaysOnTop: enabled)
        }
        .onAppear {
            appState.syncJobsPaneGeometry()
        }
        .onChange(of: appState.showFloatingJobsPanel) { _, show in
            if !show {
                dismiss()
            }
        }
        .onDisappear {
            appState.hideJobsPanel()
        }
        .onChange(of: appState.jobsQueueSizeMode) { _, _ in
            appState.syncJobsPaneGeometry()
        }
    }

    private func applyJobsPanelWindowLevel(alwaysOnTop: Bool) {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == "jobs-panel" || $0.title == "Job Control"
        }) else { return }
        window.level = alwaysOnTop ? .floating : .normal
    }
}
