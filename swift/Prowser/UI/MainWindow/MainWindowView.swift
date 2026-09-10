import AppKit
import SwiftUI

struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ProwserMainSplitView(
            leftVisible: appState.leftSidebarColumnVisible,
            rightVisible: appState.rightSidebarColumnVisible,
            preferredLeftWidth: appState.leftSidebarWidth,
            preferredRightWidth: appState.rightSidebarWidth,
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
                    VStack(spacing: 0) {
                        ContentStackView()
                            .frame(minWidth: 400, maxHeight: .infinity)
                        if appState.statusBarColumnVisible {
                            StatusBarView()
                        }
                    }
                    NotificationBubbleOverlay()
                }
            },
            right: {
                RightSidebarView()
            }
        )
        .navigationTitle(appState.fileData.currentDirectory.map { ($0 as NSString).lastPathComponent } ?? "Prowser")
        .preferredColorScheme(appState.theme.preferredColorScheme)
        .background(appState.theme.colors.background)
        .toolbar(.hidden, for: .windowToolbar)
        .sheet(isPresented: Binding(
            get: { appState.showImageGenCreateSheet },
            set: { appState.showImageGenCreateSheet = $0 }
        )) {
            ImageGenCreateSheet()
                .environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.showKeyboardHelp },
            set: { appState.showKeyboardHelp = $0 }
        )) {
            KeyboardShortcutsHelpView()
        }
        .sheet(isPresented: Binding(
            get: { appState.showAbout },
            set: { appState.showAbout = $0 }
        )) {
            AboutView()
        }
        .sheet(isPresented: Binding(
            get: { appState.showSimilaritySearchSheet },
            set: { appState.showSimilaritySearchSheet = $0 }
        )) {
            SimilaritySearchSheet()
                .environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.showPersonSearchSheet },
            set: { appState.showPersonSearchSheet = $0 }
        )) {
            PersonSearchSheet()
                .environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.showFindReferencesSheet },
            set: { appState.showFindReferencesSheet = $0 }
        )) {
            FindReferencesSheet()
                .environment(appState)
        }
        .sheet(item: Binding(
            get: { appState.exifBatchConfirmation },
            set: { appState.exifBatchConfirmation = $0 }
        )) { state in
            ExifBatchConfirmationSheet(state: state) {
                appState.exifBatchConfirmation = nil
            }
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            appState.refreshSidebarLayout()
            if appState.jobsDisplayMode == .panel {
                appState.showFloatingJobsPanel = true
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
            }
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
