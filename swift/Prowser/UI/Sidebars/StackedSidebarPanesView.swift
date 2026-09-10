import SwiftUI

struct SidebarPaneDescriptor {
    let index: Int
    let title: String
    let expandedConfigKey: String
    let defaultExpanded: Bool
    let isDisplayed: Bool
    var status: String? = nil
    var omitLeftBorder: Bool = false
    var allowsTitlebarDrag: Bool = false
    var allowsDoubleClickFit: Bool = true
    var isJobsPane: Bool = false
    var showsFlyoutButton: Bool = false
    var contextMenuKind: SidebarPaneContextMenuKind? = nil
    var preferredFitContentHeight: CGFloat = 120
}

@MainActor
struct StackedSidebarPanesView<Pane0: View, Pane1: View, Pane2: View>: View {
    @Environment(AppState.self) private var appState

    let model: SidebarPaneSplitModel
    let descriptors: [SidebarPaneDescriptor]
    @ViewBuilder let pane0: () -> Pane0
    @ViewBuilder let pane1: () -> Pane1
    @ViewBuilder let pane2: () -> Pane2

    @State private var draggingSplitterIndex: Int?

    var body: some View {
        GeometryReader { geometry in
            let displayed = descriptors.filter { descriptor in
                guard descriptor.isDisplayed else { return false }
                return model.paneExpanded(
                    configKey: descriptor.expandedConfigKey,
                    default: descriptor.defaultExpanded
                )
            }

            VStack(spacing: 0) {
                ForEach(Array(displayed.enumerated()), id: \.element.index) { position, descriptor in
                    paneBlock(descriptor: descriptor, height: model.sizes[descriptor.index])
                    if position < displayed.count - 1 {
                        splitterHandle(betweenUpperIndex: descriptor.index)
                    }
                }
            }
            .onAppear {
                relayout(totalHeight: geometry.size.height)
            }
            .onChange(of: geometry.size.height) { _, newHeight in
                relayout(totalHeight: newHeight)
            }
            .onChange(of: appState.sidebarLayoutRevision) { _, _ in
                relayout(totalHeight: geometry.size.height)
            }
            .onChange(of: appState.jobsDisplayMode) { _, _ in
                relayout(totalHeight: geometry.size.height)
            }
            .onChange(of: appState.jobsQueueSizeMode) { _, _ in
                relayout(totalHeight: geometry.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(appState.theme.colors.sidebarBackground)
    }

    private var layoutSignature: String {
        descriptors.map { descriptor in
            let expanded = model.paneExpanded(
                configKey: descriptor.expandedConfigKey,
                default: descriptor.defaultExpanded
            )
            return "\(descriptor.index):\(descriptor.isDisplayed):\(expanded)"
        }.joined(separator: "|")
        + "|jobs:\(appState.jobsDisplayMode.rawValue)|mode:\(appState.jobsQueueSizeMode.rawValue)"
    }

    @ViewBuilder
    private func paneBlock(descriptor: SidebarPaneDescriptor, height: CGFloat) -> some View {
        let expanded = model.paneExpanded(
            configKey: descriptor.expandedConfigKey,
            default: descriptor.defaultExpanded
        )
        let paneHeight = max(height, SidebarPaneLayout.headerHeight)

        SidebarPaneSection(
            title: descriptor.title,
            isExpanded: expanded,
            onToggle: { togglePane(descriptor) },
            paneIndex: descriptor.index,
            allowsTitlebarDrag: descriptor.allowsTitlebarDrag,
            onTitleClick: descriptor.index == 0 && model.side == .left ? { appState.requestFileTreeFocus() } : nil,
            onTitleDoubleClick: descriptor.allowsDoubleClickFit
                ? { handleDoubleClick(descriptor) }
                : nil,
            onTitlebarDragStarted: descriptor.allowsTitlebarDrag
                ? { y in model.beginTitlebarDrag(atY: y) }
                : nil,
            onTitlebarDrag: descriptor.allowsTitlebarDrag
                ? { y in model.applyTitlebarDrag(paneIndex: descriptor.index, currentY: y, appState: appState) }
                : nil,
            onTitlebarDragEnded: descriptor.allowsTitlebarDrag
                ? { model.endTitlebarDrag(appState: appState) }
                : nil,
            status: descriptor.status,
            omitLeftBorder: descriptor.omitLeftBorder,
            showsFlyoutButton: descriptor.showsFlyoutButton,
            onFlyout: descriptor.showsFlyoutButton ? { appState.showJobsPanel() } : nil,
            contextMenuKind: descriptor.contextMenuKind
        ) {
            SidebarPaneBody(kind: descriptor.contextMenuKind) {
                paneContent(for: descriptor.index)
            }
        }
        .frame(height: paneHeight, alignment: .top)
        .clipped()
    }

    @ViewBuilder
    private func paneContent(for index: Int) -> some View {
        switch index {
        case 0: pane0()
        case 1: pane1()
        default: pane2()
        }
    }

    private func splitterHandle(betweenUpperIndex index: Int) -> some View {
        let colors = appState.theme.colors
        return Rectangle()
            .fill(colors.sidebarHeaderBorder.opacity(0.8))
            .frame(height: 4)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if draggingSplitterIndex == nil {
                            draggingSplitterIndex = index
                            model.beginTitlebarDrag(atY: 0)
                        }
                        model.applySplitterDrag(
                            upperIndex: index,
                            currentY: value.translation.height,
                            appState: appState
                        )
                    }
                    .onEnded { _ in
                        draggingSplitterIndex = nil
                        model.endTitlebarDrag(appState: appState)
                    }
            )
    }

    private func relayout(totalHeight: CGFloat) {
        let updated = model.layoutSizes(totalHeight: totalHeight, appState: appState)
        model.applySizes(updated, appState: appState, persist: false)
    }

    private func togglePane(_ descriptor: SidebarPaneDescriptor) {
        let expanded = model.paneExpanded(
            configKey: descriptor.expandedConfigKey,
            default: descriptor.defaultExpanded
        )
        model.setPaneExpanded(!expanded, configKey: descriptor.expandedConfigKey)
        appState.onSidebarPaneToggled(side: model.side, nowVisible: !expanded)
        appState.config.applySettingsChange(emit: appState.eventBus)
    }

    private func handleDoubleClick(_ descriptor: SidebarPaneDescriptor) {
        if descriptor.isJobsPane {
            model.cycleJobsPaneSize(appState: appState)
            return
        }
        model.togglePaneFit(
            paneIndex: descriptor.index,
            appState: appState,
            contentHeight: descriptor.preferredFitContentHeight
        )
        appState.config.applySettingsChange(emit: appState.eventBus)
    }
}
