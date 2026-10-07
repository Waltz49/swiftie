import SwiftUI

/// Pane titlebar matching Python `HeaderWidget` in `combined_sidebar_widget.py`.
struct SidebarPaneTitlebar: View {
    @Environment(AppState.self) private var appState

    let title: String
    let isExpanded: Bool
    let onToggle: () -> Void
    var paneIndex: Int? = nil
    var allowsTitlebarDrag: Bool = false
    var onTitleClick: (() -> Void)? = nil
    var onTitleDoubleClick: (() -> Void)? = nil
    var onTitlebarDragStarted: ((CGFloat) -> Void)? = nil
    var onTitlebarDrag: ((CGFloat) -> Void)? = nil
    var onTitlebarDragEnded: (() -> Void)? = nil
    var status: String? = nil
    var omitLeftBorder: Bool = false
    var showsFlyoutButton: Bool = false
    var onFlyout: (() -> Void)? = nil
    var contextMenuKind: SidebarPaneContextMenuKind? = nil

    @State private var dragStartY: CGFloat?
    @State private var suppressTitleClick = false

    var body: some View {
        let colors = appState.theme.colors

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
        .contentShape(Rectangle())
        .gesture(titlebarDragGesture)
        .onTapGesture(count: 2) {
            suppressTitleClick = true
            onTitleDoubleClick?()
        }
        .onTapGesture(count: 1) {
            guard !suppressTitleClick else {
                suppressTitleClick = false
                return
            }
            onTitleClick?()
        }
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

    private var titlebarDragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard allowsTitlebarDrag, let onTitlebarDrag else { return }
                if dragStartY == nil {
                    dragStartY = value.startLocation.y
                    suppressTitleClick = true
                    onTitlebarDragStarted?(value.startLocation.y)
                }
                onTitlebarDrag(value.location.y)
            }
            .onEnded { _ in
                dragStartY = nil
                onTitlebarDragEnded?()
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
    var onTitleClick: (() -> Void)? = nil
    var onTitleDoubleClick: (() -> Void)? = nil
    var onTitlebarDragStarted: ((CGFloat) -> Void)? = nil
    var onTitlebarDrag: ((CGFloat) -> Void)? = nil
    var onTitlebarDragEnded: (() -> Void)? = nil
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
                onTitleClick: onTitleClick,
                onTitleDoubleClick: onTitleDoubleClick,
                onTitlebarDragStarted: onTitlebarDragStarted,
                onTitlebarDrag: onTitlebarDrag,
                onTitlebarDragEnded: onTitlebarDragEnded,
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
