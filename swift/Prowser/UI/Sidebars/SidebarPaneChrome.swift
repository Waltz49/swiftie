import SwiftUI

/// Pane titlebar matching Python `HeaderWidget` in `combined_sidebar_widget.py`.
struct SidebarPaneTitlebar: View {
    @Environment(AppState.self) private var appState

    let title: String
    let isExpanded: Bool
    let onToggle: () -> Void
    var paneIndex: Int? = nil
    var allowsTitlebarDrag: Bool = false
    var splitModel: SidebarPaneSplitModel? = nil
    var onTitleClick: (() -> Void)? = nil
    var onTitleDoubleClick: (() -> Void)? = nil
    var status: String? = nil
    var omitLeftBorder: Bool = false
    var showsFlyoutButton: Bool = false
    var onFlyout: (() -> Void)? = nil
    var contextMenuKind: SidebarPaneContextMenuKind? = nil
    var titlebarFocused: Bool = false

    @State private var suppressTitleClick = false

    private var titlebarResizeEnabled: Bool {
        guard allowsTitlebarDrag, let paneIndex, paneIndex >= 1, splitModel != nil else { return false }
        return true
    }

    private var showsJobsQueueSizeLights: Bool {
        if case .jobs = contextMenuKind { return true }
        return false
    }

    var body: some View {
        let colors = appState.theme.colors

        HStack(spacing: 8) {
            if showsJobsQueueSizeLights {
                JobsQueueSizeTrafficLights()
            }
            titlebarDragRegion(colors: colors)

            if let contextMenuKind {
                SidebarPaneToolsMenuButton(kind: contextMenuKind)
                    .foregroundStyle(colors.sidebarHeaderText)
            }

            if showsFlyoutButton, let onFlyout {
                SidebarTitlebarChipButton(
                    tooltip: "Open floating job control panel",
                    image: { colors, hover in
                        TitlebarIcons.flyoutIcon(paneMode: true, colors: colors, hover: hover)
                    },
                    action: onFlyout
                )
            }

            SidebarTitlebarChipButton(
                tooltip: isExpanded ? "Hide pane" : "Show pane",
                image: { colors, hover in
                    TitlebarIcons.hideIcon(mode: isExpanded ? "minus" : "plus", colors: colors, hover: hover)
                },
                action: onToggle
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background {
            if titlebarResizeEnabled, let paneIndex, let splitModel {
                SidebarPaneVerticalResizeMouseView(
                    paneIndex: paneIndex,
                    splitModel: splitModel,
                    appState: appState,
                    onDragStarted: { suppressTitleClick = true },
                    onDoubleClick: {
                        suppressTitleClick = true
                        onTitleDoubleClick?()
                    }
                )
            }
        }
        .background(titlebarFocused ? colors.sidebarHeaderFocusBackground : colors.sidebarHeaderBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(colors.sidebarHeaderBorder)
                .frame(height: 1)
        }
        .overlay(alignment: .leading) {
            if !omitLeftBorder {
                Rectangle()
                    .fill(colors.sidebarHeaderBorder)
                    .frame(width: 1)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(colors.sidebarHeaderBorder)
                .frame(width: 1)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(colors.sidebarHeaderBorder)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func titlebarDragRegion(colors: ThemeColors) -> some View {
        ZStack {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(colors.sidebarHeaderText)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let status, !status.isEmpty {
                    Text(status)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(colors.sidebarHeaderText.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .if(!titlebarResizeEnabled) { view in
            view
                .onTapGesture(count: 1) {
                    onTitleClick?()
                }
                .onTapGesture(count: 2) {
                    suppressTitleClick = true
                    onTitleDoubleClick?()
                }
        }
    }
}

private extension View {
    @ViewBuilder
    func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

/// Titlebar + content for an open sidebar pane (closed panes are omitted from the stack).
struct SidebarPaneSection<Content: View>: View {
    @Environment(AppState.self) private var appState

    let title: String
    let isExpanded: Bool
    let onToggle: () -> Void
    var paneIndex: Int? = nil
    var allowsTitlebarDrag: Bool = false
    var splitModel: SidebarPaneSplitModel? = nil
    var onTitleClick: (() -> Void)? = nil
    var onTitleDoubleClick: (() -> Void)? = nil
    var status: String? = nil
    var omitLeftBorder: Bool = false
    var showsFlyoutButton: Bool = false
    var onFlyout: (() -> Void)? = nil
    var contextMenuKind: SidebarPaneContextMenuKind? = nil
    /// When false (e.g. Mini ⌥[ Mode), the titlebar is omitted while expanded; collapsed panes still show the bar so the pane can be expanded again.
    var showsTitlebar: Bool = true
    var titlebarFocused: Bool = false
    /// When true, content stays mounted at zero size while collapsed (file tree T toggle).
    var keepContentMountedWhenCollapsed: Bool = false
    @ViewBuilder let content: () -> Content

    private var isJobsPaneContext: Bool {
        if case .jobs = contextMenuKind { return true }
        return false
    }

    private var titlebarVisible: Bool {
        if keepContentMountedWhenCollapsed, !isExpanded { return false }
        return showsTitlebar || !isExpanded
    }

    private var contentMounted: Bool {
        isExpanded || keepContentMountedWhenCollapsed
    }

    var body: some View {
        VStack(spacing: 0) {
            if titlebarVisible {
                SidebarPaneTitlebar(
                    title: title,
                    isExpanded: isExpanded,
                    onToggle: onToggle,
                    paneIndex: paneIndex,
                    allowsTitlebarDrag: allowsTitlebarDrag,
                    splitModel: splitModel,
                    onTitleClick: onTitleClick,
                    onTitleDoubleClick: onTitleDoubleClick,
                    status: status,
                    omitLeftBorder: omitLeftBorder,
                    showsFlyoutButton: showsFlyoutButton,
                    onFlyout: onFlyout,
                    contextMenuKind: contextMenuKind,
                    titlebarFocused: titlebarFocused
                )
            }

            if contentMounted {
                content()
                    .frame(maxWidth: .infinity, maxHeight: isExpanded ? .infinity : 0, alignment: .top)
                    .clipped()
                    .allowsHitTesting(isExpanded)
                    .accessibilityHidden(!isExpanded)
                    .modifier(SidebarPaneOverflowClip(enabled: !isJobsPaneContext && isExpanded))
                    .background(appState.theme.colors.sidebarBackground)
                    .overlay(alignment: .leading) {
                        if isExpanded, !omitLeftBorder {
                            Rectangle()
                                .fill(appState.theme.colors.sidebarHeaderBorder)
                                .frame(width: 1)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if isExpanded {
                            Rectangle()
                                .fill(appState.theme.colors.sidebarHeaderBorder)
                                .frame(width: 1)
                        }
                    }
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: isExpanded ? .infinity : (keepContentMountedWhenCollapsed ? 0 : nil),
            alignment: .top
        )
    }
}

/// Optional action toolbar + right-click context menu for a sidebar pane body.
@MainActor
struct SidebarPaneBody<Content: View>: View {
    @Environment(AppState.self) private var appState

    let kind: SidebarPaneContextMenuKind?
    @ViewBuilder let content: () -> Content

    private var isJobsContextMenu: Bool {
        if case .jobs = kind { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            if let kind, toolbarVisible(for: kind) {
                toolbar(for: kind)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .modifier(SidebarPaneOverflowClip(enabled: !isJobsContextMenu))
        }
        .overlay {
            if let kind, !usesInternalContextMenu(kind) {
                PaneContextMenuReceiver(kind: kind)
            }
        }
    }

    @ViewBuilder
    private func toolbar(for kind: SidebarPaneContextMenuKind) -> some View {
        switch kind {
        case .fileTree:
            FileTreeToolbarView()
        case .information:
            InformationActionBarView()
        case .jobs:
            JobsToolbarView()
        case .chat:
            EmptyView()
        }
    }

    private func usesInternalContextMenu(_ kind: SidebarPaneContextMenuKind) -> Bool {
        switch kind {
        case .fileTree, .jobs:
            return true
        default:
            return false
        }
    }

    private func toolbarVisible(for kind: SidebarPaneContextMenuKind) -> Bool {
        switch kind {
        case .fileTree:
            return appState.fileTreeToolbarVisible
        case .information:
            return appState.informationMenuBarVisible
        case .jobs:
            return appState.jobsToolbarVisible && !appState.jobsPaneMiniChromeActive
        case .chat:
            return false
        }
    }
}

/// Clips pane overflow for upper sidebar sections; the jobs pane sits on the bottom edge and
/// does not need bottom clipping when content is slightly taller than the splitter slice.
struct SidebarPaneOverflowClip: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.clipped()
        } else {
            content
        }
    }
}
