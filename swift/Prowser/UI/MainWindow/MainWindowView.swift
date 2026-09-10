import AppKit
import SwiftUI

struct MainWindowView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

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
                            .frame(minWidth: 400, maxHeight: .infinity)
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
        .sheet(isPresented: Binding(
            get: { appState.showKeyboardHelp },
            set: { appState.showKeyboardHelp = $0 }
        )) {
            KeyboardShortcutsHelpView()
                .environment(\.themeColors, appState.theme.colors)
        }
        .sheet(isPresented: Binding(
            get: { appState.showAbout },
            set: { appState.showAbout = $0 }
        )) {
            AboutView()
                .environment(\.themeColors, appState.theme.colors)
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
        .sheet(isPresented: Binding(
            get: { appState.showFilterDialog },
            set: { appState.showFilterDialog = $0 }
        )) {
            FilterDialogSheet()
                .environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.showEditUserCommentSheet },
            set: { presented in
                if !presented {
                    appState.cancelEditUserComment()
                } else {
                    appState.showEditUserCommentSheet = true
                }
            }
        )) {
            EditExifUserCommentSheet()
                .environment(appState)
        }
        .alert("EXIF Error", isPresented: Binding(
            get: { appState.editUserCommentError != nil },
            set: { if !$0 { appState.editUserCommentError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.editUserCommentError = nil }
        } message: {
            Text(appState.editUserCommentError ?? "")
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            appState.refreshSidebarLayout()
            if appState.jobsDisplayMode == .panel {
                appState.showFloatingJobsPanel = true
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
            }
        }
        .onChange(of: appState.showImageGenUnifiedDialog) { _, show in
            if show {
                openWindow(id: "imagegen-unified")
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
