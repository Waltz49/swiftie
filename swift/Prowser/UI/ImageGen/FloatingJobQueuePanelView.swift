import AppKit
import SwiftUI

struct FloatingJobQueuePanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Job Control")
                    .font(.headline)
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
        .background(JobsPanelWindowConfigurator(alwaysOnTop: appState.jobsPanelAlwaysOnTop))
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

private struct JobsPanelWindowConfigurator: NSViewRepresentable {
    let alwaysOnTop: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        window.level = alwaysOnTop ? .floating : .normal
    }
}
