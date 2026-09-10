import AppKit
import SwiftUI

struct StatusBarView: View {
    @Environment(AppState.self) private var appState
    @State private var refreshTrigger = 0

    var body: some View {
        let _ = refreshTrigger
        let sortMode = SortMode(rawValue: appState.config.string(forKey: "sort_mode", default: "date")) ?? .date
        let sortReversed = appState.config.bool(forKey: "sort_reversed", default: false)
        let displayed = appState.fileData.displayedImages
        let currentPath = appState.fileData.currentImagePath
        let filterPattern = appState.filterSettings.filterPattern
        let viewMode = appState.fileData.currentViewMode

        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 0) {
                ForEach(StatusBarLayout.SectionID.displayOrder, id: \.self) { sectionID in
                    sectionView(
                        sectionID,
                        totalWidth: width,
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
            .overlay(alignment: .trailing) {
                if let message = appState.status.bubbles.last?.message {
                    section(
                        text: message,
                        sectionID: nil,
                        totalWidth: width,
                        enabled: false,
                        action: nil
                    )
                    .italic()
                }
            }
        }
        .frame(height: appState.effectiveStatusBarHeight)
        .clipped()
        .background(appState.theme.colors.statusBarBackground)
        .onReceive(NotificationCenter.default.publisher(for: .prowserCurrentImageChanged)) { _ in
            refreshTrigger += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserDisplayedImagesChanged)) { _ in
            refreshTrigger += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserDirectoryChanged)) { _ in
            refreshTrigger += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserViewModeChanged)) { _ in
            refreshTrigger += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserFilterPatternChanged)) { _ in
            refreshTrigger += 1
        }
    }

    @MainActor @ViewBuilder
    private func sectionView(
        _ sectionID: StatusBarLayout.SectionID,
        totalWidth: CGFloat,
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
                totalWidth: totalWidth,
                enabled: true,
                action: { StatusBarMenus.showSortMenu(appState: appState, relativeTo: $0) }
            )
        case .filter:
            section(
                text: StatusBarFormatter.filterLabel(pattern: filterPattern),
                sectionID: sectionID,
                totalWidth: totalWidth,
                enabled: viewMode == .thumbnail || viewMode == .list,
                action: (viewMode == .thumbnail || viewMode == .list)
                    ? { StatusBarMenus.showFilterMenu(appState: appState, relativeTo: $0) }
                    : nil
            )
        case .filename:
            section(
                text: filenameText(displayed: displayed, currentPath: currentPath, filterPattern: filterPattern),
                sectionID: sectionID,
                totalWidth: totalWidth,
                enabled: true,
                action: nil
            )
        case .dimensions:
            section(
                text: displayed.isEmpty
                    ? "0 x 0"
                    : StatusBarFormatter.dimensionsLabel(path: currentPath, metadataCache: appState.metadataCache),
                sectionID: sectionID,
                totalWidth: totalWidth,
                enabled: true,
                action: nil
            )
        case .date:
            section(
                text: StatusBarFormatter.dateLabel(
                    path: currentPath,
                    useExifDate: appState.config.useExifDate,
                    metadataCache: appState.metadataCache
                ),
                sectionID: sectionID,
                totalWidth: totalWidth,
                enabled: true,
                action: { StatusBarMenus.showDateMenu(appState: appState, relativeTo: $0) }
            )
        case .fitMode:
            section(
                text: StatusBarFormatter.fitModeLabel(actualSize: appState.browseActualSizeEnabled),
                sectionID: sectionID,
                totalWidth: totalWidth,
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
                totalWidth: totalWidth,
                enabled: true,
                action: nil
            )
        }
    }

    @MainActor
    private func filenameText(displayed: [String], currentPath: String?, filterPattern: String) -> String {
        if displayed.isEmpty {
            return "No files match the filter: \(filterPattern)"
        }
        if let path = currentPath {
            return StatusBarFormatter.displayPath(path)
        }
        return "No files match the filter: \(filterPattern)"
    }

    @MainActor @ViewBuilder
    private func section(
        text: String,
        sectionID: StatusBarLayout.SectionID?,
        totalWidth: CGFloat,
        enabled: Bool,
        action: ((NSView) -> Void)?
    ) -> some View {
        let color = enabled
            ? appState.theme.colors.statusBarText
            : appState.theme.colors.statusBarText.opacity(0.45)
        let host = StatusBarSectionHost(
            text: text,
            textColor: NSColor(color),
            enabled: enabled,
            isBold: sectionID?.isBold ?? false,
            alignment: nsTextAlignment(for: sectionID?.alignment ?? .leading),
            onClick: action
        )

        if let sectionID, sectionID.expands {
            host
                .frame(
                    minWidth: StatusBarLayout.minWidth(for: sectionID, totalWidth: totalWidth),
                    maxWidth: .infinity,
                    alignment: sectionID.alignment
                )
                .layoutPriority(0)
        } else if let sectionID {
            host
                .frame(
                    minWidth: StatusBarLayout.minWidth(for: sectionID, totalWidth: totalWidth),
                    alignment: sectionID.alignment
                )
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        } else {
            host
                .frame(minWidth: max(80, totalWidth * 0.10), alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
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
