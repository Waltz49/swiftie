import AppKit
import SwiftUI

struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            ProwserMainSplitView(
                leftVisible: appState.effectiveLeftSidebarVisible,
                rightVisible: appState.effectiveRightSidebarVisible,
                preferredLeftWidth: appState.effectiveLeftSidebarWidth,
                preferredRightWidth: appState.effectiveRightSidebarWidth,
                allowAnimatedWidths: appState.chromeLayoutOverride != nil,
                layoutRevision: appState.sidebarLayoutRevision,
                onLeftWidthChange: { width in
                    appState.updateLeftSidebarWidth(width)
                },
                onRightWidthChange: { width in
                    appState.updateRightSidebarWidth(width)
                },
                onLayoutApplied: {
                    appState.notifyMainContentLayoutChanged()
                },
                left: {
                    LeftSidebarView()
                },
                center: {
                    ContentStackView()
                        .frame(minWidth: SidebarWidthLimits.centerMin, maxHeight: .infinity)
                        .background(MainWindowCanvasTabStopView())
                },
                right: {
                    RightSidebarView()
                }
            )
            .frame(maxHeight: .infinity)

            if appState.mountsStatusBarRow {
                StatusBarView()
            }
        }
        .overlay(alignment: .bottomLeading) {
            NotificationBubbleOverlay()
        }
        .overlay {
            CopyFeedbackOverlay()
        }
        .navigationTitle(appState.fileData.currentDirectory.map { ($0 as NSString).lastPathComponent } ?? "Prowser")
        .preferredColorScheme(appState.theme.preferredColorScheme)
        .environment(\.themeColors, appState.theme.colors)
        .background(appState.theme.colors.background)
        .toolbar(.hidden, for: .windowToolbar)
        .background(MainWindowIdentityAnchor())
        .background(AuxiliaryDialogBridge())
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            appState.refreshSidebarLayout()
            if appState.jobsDisplayMode == .panel, appState.showFloatingJobsPanel {
                openWindow(id: "jobs-panel")
            }
            if appState.showImageGenUnifiedDialog {
                openWindow(id: "imagegen-unified")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                appState.refreshSidebarLayout()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                appState.refreshSidebarLayout()
            }
        }
        .onChange(of: appState.showFloatingJobsPanel) { _, show in
            if show {
                openWindow(id: "jobs-panel")
            } else {
                dismissWindow(id: "jobs-panel")
            }
        }
        .onChange(of: appState.showImageGenUnifiedDialog) { _, show in
            if show {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "imagegen-unified")
            } else {
                dismissWindow(id: "imagegen-unified")
            }
        }
        .onChange(of: appState.settingsOpenRequestToken) { _, _ in
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct ContentStackView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var fileData = appState.fileData

        // Keep thumbnail grid mounted (Qt stacked widget parity) so scroll/highlight survive browse.
        ZStack {
            ThumbnailGridView()
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(appState.theme.colors.thumbnailGridBackground)
                        .frame(height: ThumbnailLayout.topCoverBandHeight)
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                }
                .opacity(fileData.currentViewMode == .thumbnail ? 1 : 0)
                .allowsHitTesting(fileData.currentViewMode == .thumbnail)
                .zIndex(fileData.currentViewMode == .thumbnail ? 1 : 0)

            // Keep list mounted (Qt stacked widget parity) so scroll survives browse.
            ImageListView()
                .opacity(fileData.currentViewMode == .list ? 1 : 0)
                .allowsHitTesting(fileData.currentViewMode == .list)
                .zIndex(fileData.currentViewMode == .list ? 1 : 0)

            switch fileData.currentViewMode {
            case .thumbnail:
                EmptyView()
            case .list:
                EmptyView()
            case .browse:
                BrowseView()
            case .slideshow:
                SlideshowView()
            case .slideshow2:
                Slideshow2View()
            case .slideshow3:
                Slideshow3View()
            }
        }
    }
}
