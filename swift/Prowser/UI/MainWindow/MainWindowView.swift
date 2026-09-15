import AppKit
import SwiftUI

struct MainWindowView: View {
    @Environment(AppState.self) private var appState

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
                    ZStack(alignment: .bottomLeading) {
                        ContentStackView()
                            .frame(minWidth: SidebarWidthLimits.centerMin, maxHeight: .infinity)
                            .background(MainWindowCanvasTabStopView())
                        NotificationBubbleOverlay()
                    }
                },
                right: {
                    RightSidebarView()
                }
            )
            .frame(maxHeight: .infinity)

            if appState.effectiveStatusBarHeight > 0 || appState.chromeLayoutOverride != nil {
                StatusBarView()
            }
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
                .opacity(fileData.currentViewMode == .thumbnail ? 1 : 0)
                .allowsHitTesting(fileData.currentViewMode == .thumbnail)
                .zIndex(fileData.currentViewMode == .thumbnail ? 1 : 0)

            switch fileData.currentViewMode {
            case .thumbnail:
                EmptyView()
            case .list:
                ImageListView()
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
