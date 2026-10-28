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

    @State private var suppressTitleClick = false

    private var titlebarResizeEnabled: Bool {
        guard allowsTitlebarDrag, let paneIndex, paneIndex >= 1, splitModel != nil else { return false }
        return true
    }

    var body: some View {
        let colors = appState.theme.colors

        HStack(spacing: 8) {
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
        .background(colors.sidebarHeaderBackground)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onTapGesture(count: 1) {
            guard !titlebarResizeEnabled else { return }
            onTitleClick?()
        }
        .onTapGesture(count: 2) {
            guard !titlebarResizeEnabled else { return }
            suppressTitleClick = true
            onTitleDoubleClick?()
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
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
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
                contextMenuKind: contextMenuKind
            )

            if isExpanded {
                content()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .background(appState.theme.colors.sidebarBackground)
                    .overlay(alignment: .leading) {
                        if !omitLeftBorder {
                            Rectangle()
                                .fill(appState.theme.colors.sidebarHeaderBorder)
                                .frame(width: 1)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(appState.theme.colors.sidebarHeaderBorder)
                            .frame(width: 1)
                    }
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: isExpanded ? .infinity : nil,
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

    var body: some View {
        VStack(spacing: 0) {
            if let kind, toolbarVisible(for: kind) {
                toolbar(for: kind)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
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
            return appState.jobsToolbarVisible
        }
    }
}
