import AppKit
import SwiftUI

struct StatusBarView: View {
    @Environment(AppState.self) private var appState
    @State private var refreshTrigger = 0
    @State private var statusBarEventSink: StatusBarEventSink?

    var body: some View {
        let _ = refreshTrigger
        let sortMode = SortMode(rawValue: appState.config.string(forKey: "sort_mode", default: "date")) ?? .date
        let sortReversed = appState.config.bool(forKey: "sort_reversed", default: false)
        let displayed = appState.fileData.displayedImages
        let currentPath = appState.fileData.currentImagePath
        let filterPattern = appState.filterSettings.filterPattern
        let viewMode = appState.fileData.currentViewMode

        HStack(spacing: 0) {
            ForEach(StatusBarLayout.SectionID.displayOrder, id: \.self) { sectionID in
                sectionView(
                    sectionID,
                    sortMode: sortMode,
                    sortReversed: sortReversed,
                    displayed: displayed,
                    currentPath: currentPath,
                    filterPattern: filterPattern,
                    viewMode: viewMode
                )
                if sectionID.showsSeparatorAfter {
                    StatusBarSeparator()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .frame(height: appState.effectiveStatusBarHeight)
        .clipped()
        .background(appState.theme.colors.statusBarBackground)
        .onAppear {
            statusBarEventSink?.uninstall()
            statusBarEventSink = StatusBarEventSink(appState: appState) {
                refreshTrigger += 1
            }
        }
        .onDisappear {
            statusBarEventSink?.uninstall()
            statusBarEventSink = nil
        }
    }

    @MainActor @ViewBuilder
    private func sectionView(
        _ sectionID: StatusBarLayout.SectionID,
        sortMode: SortMode,
        sortReversed: Bool,
        displayed: [String],
        currentPath: String?,
        filterPattern: String,
        viewMode: ViewMode
    ) -> some View {
        switch sectionID {
        case .sort:
            section(
                text: StatusBarFormatter.sortLabel(mode: sortMode, reversed: sortReversed),
                sectionID: sectionID,
                enabled: true,
                action: { StatusBarMenus.showSortMenu(appState: appState, relativeTo: $0) }
            )
        case .filter:
            section(
                text: StatusBarFormatter.filterLabel(pattern: filterPattern),
                sectionID: sectionID,
                enabled: viewMode == .thumbnail || viewMode == .list,
                action: (viewMode == .thumbnail || viewMode == .list)
                    ? { StatusBarMenus.showFilterMenu(appState: appState, relativeTo: $0) }
                    : nil
            )
        case .filename:
            section(
                text: filenameText(displayed: displayed, currentPath: currentPath, filterPattern: filterPattern),
                sectionID: sectionID,
                enabled: true,
                action: nil
            )
        case .dimensions:
            section(
                text: displayed.isEmpty
                    ? "0 x 0"
                    : StatusBarFormatter.dimensionsLabel(path: currentPath, metadataCache: appState.metadataCache),
                sectionID: sectionID,
                enabled: true,
                action: nil
            )
        case .date:
            let dateLabel = StatusBarFormatter.dateLabel(
                path: currentPath,
                useExifDate: appState.config.useExifDate,
                metadataCache: appState.metadataCache
            )
            section(
                text: dateLabel.text,
                sectionID: sectionID,
                enabled: true,
                trailingIcon: dateTrailingIcon(for: dateLabel),
                action: { StatusBarMenus.showDateMenu(appState: appState, relativeTo: $0) }
            )
        case .fitMode:
            section(
                text: StatusBarFormatter.fitModeLabel(actualSize: appState.browseActualSizeEnabled),
                sectionID: sectionID,
                enabled: viewMode == .browse,
                action: viewMode == .browse ? { _ in appState.toggleBrowseActualSize() } : nil
            )
        case .fileCount:
            section(
                text: StatusBarFormatter.fileCountLabel(
                    displayedPaths: displayed,
                    directory: appState.fileData.currentDirectory,
                    filterPattern: filterPattern,
                    extensions: appState.config.imageExtensions
                ),
                sectionID: sectionID,
                enabled: true,
                action: { StatusBarMenus.showFileCountMenu(appState: appState, relativeTo: $0) }
            )
        }
    }

    @MainActor
    private func dateTrailingIcon(for label: StatusBarFormatter.DateLabel) -> NSImage? {
        guard let usesExif = label.usesExifDate else { return nil }
        return PenDrawnIcons.dateSourceIcon(
            exif: usesExif,
            color: NSColor(appState.theme.colors.statusBarText)
        )
    }

    @MainActor
    private func filenameText(displayed: [String], currentPath: String?, filterPattern: String) -> String {
        if let path = currentPath ?? displayed.first {
            return StatusBarFormatter.displayPath(path)
        }
        if displayed.isEmpty {
            return "No files match the filter: \(filterPattern)"
        }
        return ""
    }

    @MainActor @ViewBuilder
    private func section(
        text: String,
        sectionID: StatusBarLayout.SectionID,
        enabled: Bool,
        trailingIcon: NSImage? = nil,
        action: ((NSView) -> Void)?
    ) -> some View {
        let color = enabled
            ? appState.theme.colors.statusBarText
            : appState.theme.colors.statusBarMutedText
        let host = StatusBarSectionHost(
            text: text,
            textColor: NSColor(color),
            enabled: enabled,
            isBold: sectionID.isBold,
            alignment: nsTextAlignment(for: sectionID.alignment),
            trailingIcon: trailingIcon,
            onClick: action
        )

        if sectionID.expands {
            host
                .frame(maxWidth: .infinity, alignment: sectionID.alignment)
                .layoutPriority(0)
        } else {
            host
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
    }

    private func nsTextAlignment(for alignment: Alignment) -> NSTextAlignment {
        switch alignment {
        case .leading: return .left
        case .trailing: return .right
        default: return .center
        }
    }
}

@MainActor
private final class StatusBarEventSink {
    private var bag: EventBusSubscriptionBag?
    private let onRefresh: () -> Void

    init(appState: AppState, onRefresh: @escaping () -> Void) {
        self.onRefresh = onRefresh
        let bag = EventBusSubscriptionBag(bus: appState.eventBus)
        self.bag = bag
        let types: [AppEventType] = [
            .currentImageChanged,
            .displayedImagesChanged,
            .directoryChanged,
            .viewModeChanged,
            .filterPatternChanged,
            .settingsChanged,
        ]
        for type in types {
            bag.subscribe(type) { [onRefresh] _ in onRefresh() }
        }
    }

    func uninstall() {
        bag = nil
    }
}
