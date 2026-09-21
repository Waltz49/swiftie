import AppKit
import SwiftUI

@MainActor
protocol ImageListDelegate: AnyObject {
    func imageListDidSelect(index: Int, path: String)
    func imageListDidClick(
        index: Int,
        path: String,
        shiftPressed: Bool,
        cmdPressed: Bool,
        ctrlPressed: Bool
    )
    func imageListDidOpenBrowse(index: Int, path: String)
    func imageListShowContextMenu(for event: NSEvent, clickedIndex: Int, in view: NSView)
    func imageListDidRequestColumnSort(_ mode: SortMode, toggleReverse: Bool)
    func imageListColumnLayoutDidChange(_ layout: ImageListColumnLayout)
}

/// AppKit list view with sortable, reorderable columns.
@MainActor
final class ImageListNSView: NSView, ImageListHeaderDelegate {
    weak var listDelegate: ImageListDelegate?
    weak var appState: AppState?
    weak var thumbnailCache: ThumbnailCache?

    let columnLayout = ImageListColumnLayout()

    private let scrollView = NSScrollView()
    private let tableView = ImageListTableView(frame: .zero)
    private let directoryBannerView = ImageListDirectoryBannerView(frame: .zero)
    private let headerView = ImageListTableHeaderView(frame: .zero)
    private var columnMoveObserver: NSObjectProtocol?
    private var clipBoundsObserver: NSObjectProtocol?
    private var directoryBannerHeightConstraint: NSLayoutConstraint?
    private var headerHeightConstraint: NSLayoutConstraint?
    private var headerLeadingConstraint: NSLayoutConstraint?

    var imagePaths: [String] = [] {
        didSet {
            guard oldValue != imagePaths else { return }
            tableView.host = self
            tableView.reloadData()
            syncSelection()
            updateDirectoryBanner()
            if isCommentsColumnVisible {
                scheduleCommentDataLoad(paths: imagePaths)
            }
        }
    }

    var rowDataByPath: [String: ImageListRowData] = [:] {
        didSet {
            guard oldValue != rowDataByPath else { return }
            // Do not reloadData here: that resets scroll to the top. Row text is
            // picked up on the next cell configure / imagePaths reload.
        }
    }

    private var pendingEnsureVisible = false

    override func layout() {
        super.layout()
        if pendingEnsureVisible {
            pendingEnsureVisible = false
            ensureActiveRowOnScreen()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            ensureActiveRowOnScreen()
        }
    }

    var commentInfoByPath: [String: ImageListCommentInfo] = [:]
    private var commentLoadTask: Task<Void, Never>?
    private var commentLoadGeneration = 0
    private(set) var isCommentsColumnVisible = false

    var currentPath: String? {
        didSet {
            guard oldValue != currentPath else { return }
            applyHighlight(forPaths: Set([oldValue, currentPath].compactMap { $0 }))
            syncSelection()
        }
    }

    var selectedPaths: Set<String> = [] {
        didSet {
            guard oldValue != selectedPaths else { return }
            applyHighlight(forPaths: oldValue.union(selectedPaths))
        }
    }

    var multiSelectMode = false {
        didSet {
            guard oldValue != multiSelectMode else { return }
            applyHighlight(forVisibleRows: true)
        }
    }

    var rowHeight: CGFloat = 48 {
        didSet {
            guard oldValue != rowHeight else { return }
            tableView.rowHeight = rowHeight
            headerView.pinnedHeight = rowHeight
            headerHeightConstraint?.constant = rowHeight
            tableView.tile()
            scrollView.tile()
            updateThumbnailColumnWidth()
            tableView.reloadData()
        }
    }

    var thumbnailRefreshToken = 0 {
        didSet {
            guard oldValue != thumbnailRefreshToken else { return }
            tableView.reloadData()
            if isCommentsColumnVisible {
                scheduleCommentDataLoad(paths: imagePaths)
            }
        }
    }

    var sortMode: SortMode = .date
    var sortReversed = false

    var themeColors = ThemeColors.dark

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        if let columnMoveObserver {
            NotificationCenter.default.removeObserver(columnMoveObserver)
        }
        if let clipBoundsObserver {
            NotificationCenter.default.removeObserver(clipBoundsObserver)
        }
    }

    func applyColumnLayoutFromSettings(_ config: AppConfig) {
        columnLayout.load(from: config)
        updateCommentsColumnActive(columnLayout.isColumnVisible(.comments))
        rebuildTableColumns()
    }

    func updateCommentsColumnActive(_ visible: Bool) {
        guard visible != isCommentsColumnVisible else { return }
        isCommentsColumnVisible = visible
        if visible {
            scheduleCommentDataLoad(paths: imagePaths)
        } else {
            commentLoadTask?.cancel()
            commentLoadTask = nil
            commentInfoByPath = [:]
        }
    }

    /// Ranks matching the Cmt column cells currently shown (no rereads).
    func commentColumnSortRanks() -> [String: Int] {
        ImageListCommentStatusCache.shared.snapshotSortRanks(
            for: imagePaths,
            displayed: commentInfoByPath
        )
    }

    /// Paint highlight on existing cells only. Never recreates rows or reloads thumbnails.
    private func applyHighlight(forPaths paths: Set<String>) {
        guard !paths.isEmpty else { return }
        applyHighlight(matching: paths)
    }

    private func applyHighlight(forVisibleRows: Bool) {
        guard forVisibleRows else { return }
        applyHighlight(matching: nil)
    }

    private func applyHighlight(matching paths: Set<String>?) {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location..<(visible.location + visible.length) {
            guard row >= 0, row < imagePaths.count else { continue }
            if let paths, !paths.contains(imagePaths[row]) { continue }
            applyHighlight(toRow: row)
        }
    }

    private func applyHighlight(toRow row: Int) {
        guard row >= 0, row < imagePaths.count else { return }
        let path = imagePaths[row]
        let background = rowBackground(for: path)
        let color = textColor(for: path)
        let columnCount = tableView.numberOfColumns
        guard columnCount > 0 else { return }
        for column in 0..<columnCount {
            guard let view = tableView.view(atColumn: column, row: row, makeIfNecessary: false) else { continue }
            if let cell = view as? ImageListThumbnailCell {
                cell.applyHighlight(backgroundColor: background)
            } else if let cell = view as? ImageListCommentCell {
                cell.applyHighlight(backgroundColor: background)
            } else if let cell = view as? ImageListTextCell {
                cell.applyHighlight(textColor: color, backgroundColor: background)
            }
        }
    }

    func scheduleCommentDataLoad(paths: [String]) {
        guard isCommentsColumnVisible, !paths.isEmpty else { return }
        commentLoadTask?.cancel()
        commentLoadGeneration += 1
        let generation = commentLoadGeneration
        let pathsToLoad = paths
        applyCachedCommentInfo(for: pathsToLoad)
        let misses = ImageListCommentStatusCache.shared.pathsNeedingLoad(pathsToLoad)
        guard !misses.isEmpty else { return }

        commentLoadTask = Task {
            var pendingPaths: [String] = []
            var pendingInfo: [String: ImageListCommentInfo] = [:]
            for (index, path) in misses.enumerated() {
                if Task.isCancelled { return }
                let info = await Task.detached(priority: .utility) {
                    ImageListCommentService.classify(path: path)
                }.value
                if Task.isCancelled { return }
                pendingPaths.append(path)
                pendingInfo[path] = info
                if index % 24 == 23 {
                    let batchPaths = pendingPaths
                    let batchInfo = pendingInfo
                    pendingPaths = []
                    pendingInfo = [:]
                    await MainActor.run {
                        guard generation == self.commentLoadGeneration else { return }
                        self.mergeCommentBatch(paths: batchPaths, info: batchInfo)
                    }
                }
            }
            let batchPaths = pendingPaths
            let batchInfo = pendingInfo
            await MainActor.run {
                guard generation == self.commentLoadGeneration else { return }
                self.mergeCommentBatch(paths: batchPaths, info: batchInfo)
            }
        }
    }

    private func applyCachedCommentInfo(for paths: [String]) {
        let pathSet = Set(paths)
        commentInfoByPath = commentInfoByPath.filter { pathSet.contains($0.key) }
        let cached = ImageListCommentStatusCache.shared.prime(paths: paths)
        for path in paths {
            if let info = cached[path] {
                commentInfoByPath[path] = info
            } else {
                commentInfoByPath.removeValue(forKey: path)
            }
        }
        tableView.reloadCommentColumnRows(in: paths, host: self)
    }

    private func mergeCommentBatch(paths: [String], info: [String: ImageListCommentInfo]) {
        for path in paths {
            guard let value = info[path] else { continue }
            ImageListCommentStatusCache.shared.store(path: path, info: value)
            commentInfoByPath[path] = value
        }
        tableView.reloadCommentColumnRows(in: paths, host: self)
    }

    func updateSortIndicators(mode: SortMode, reversed: Bool) {
        sortMode = mode
        sortReversed = reversed
        refreshHeaderTitles()
    }

    private func configure() {
        wantsLayer = true
        clipsToBounds = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView.host = self
        tableView.style = .fullWidth
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.gridStyleMask = .solidVerticalGridLineMask
        tableView.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.headerDelegate = self
        headerView.pinnedHeight = rowHeight
        // Keep the AppKit header↔table link for column drag, but do not let the
        // table overlay the header on row 0 (`.plain` / floating header).
        tableView.headerView = headerView
        headerView.tableView = tableView
        tableView.headerView = nil

        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = tableView
        directoryBannerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        addSubview(directoryBannerView)
        addSubview(headerView)

        let bannerHeight = directoryBannerView.heightAnchor.constraint(equalToConstant: 0)
        let headerHeight = headerView.heightAnchor.constraint(equalToConstant: rowHeight)
        let headerLeading = headerView.leadingAnchor.constraint(equalTo: leadingAnchor)
        directoryBannerHeightConstraint = bannerHeight
        headerHeightConstraint = headerHeight
        headerLeadingConstraint = headerLeading
        NSLayoutConstraint.activate([
            directoryBannerView.topAnchor.constraint(equalTo: topAnchor),
            directoryBannerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            directoryBannerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bannerHeight,
            headerView.topAnchor.constraint(equalTo: directoryBannerView.bottomAnchor),
            headerLeading,
            headerHeight,
            headerView.widthAnchor.constraint(equalTo: tableView.widthAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        tableView.tile()
        scrollView.tile()
        placeHeaderAboveTable()

        clipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncHeaderHorizontalOffset()
            }
        }

        columnMoveObserver = NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidMoveNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let movedTable = notification.object as? NSTableView,
                      movedTable === self.tableView else { return }
                self.headerView.noteColumnMovedByUser()
                self.handleColumnsMoved()
            }
        }

        rebuildTableColumns()
        updateDirectoryBanner()
    }

    private func updateDirectoryBanner() {
        let content = ImageListRowFormatting.listHeaderDirectoryBannerContent(for: imagePaths)
        directoryBannerView.content = content
        let height: CGFloat
        if content != nil {
            height = ImageListDirectoryBannerView.preferredHeight
        } else {
            height = 0
        }
        directoryBannerHeightConstraint?.constant = height
        directoryBannerView.isHidden = height == 0
        directoryBannerView.needsDisplay = true
    }

    func placeHeaderAboveTable() {
        if headerView.superview !== self {
            addSubview(headerView)
        }
        headerView.tableView = tableView
        if tableView.headerView != nil {
            tableView.headerView = nil
            headerView.tableView = tableView
        }
        syncHeaderHorizontalOffset()
    }

    private func syncHeaderHorizontalOffset() {
        headerLeadingConstraint?.constant = -tableView.visibleRect.origin.x
    }

    private func handleColumnsMoved() {
        columnLayout.syncOrderFromTableColumns(tableView)
        listDelegate?.imageListColumnLayoutDidChange(columnLayout)
        headerView.needsDisplay = true
    }

    /// Rebuilds table columns. Reloads only `reloadColumnIDs` (never thumbnails); nil = all text columns.
    private func rebuildTableColumns(reloadColumnIDs: Set<ImageListColumnID>? = nil) {
        while tableView.tableColumns.count > 0 {
            tableView.removeTableColumn(tableView.tableColumns[0])
        }
        for columnID in columnLayout.visibleColumns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(columnID.rawValue))
            column.title = columnID.title
            column.minWidth = columnID.minWidth
            column.width = width(for: columnID)
            column.headerCell.alignment = columnID.headerTextAlignment
            if columnID == .name {
                column.resizingMask = [.autoresizingMask, .userResizingMask]
            } else if columnID == .comments || columnID == .ext {
                // Narrow column: disable resize so the whole header is a sort click target.
                column.resizingMask = []
            } else {
                column.resizingMask = .userResizingMask
            }
            tableView.addTableColumn(column)
        }
        refreshHeaderTitles()
        reloadTableCellData(columnIDs: reloadColumnIDs)
        headerView.needsDisplay = true
    }

    private func reloadTableCellData(columnIDs: Set<ImageListColumnID>?) {
        guard !imagePaths.isEmpty else { return }
        let ids: Set<ImageListColumnID>
        if let columnIDs {
            guard !columnIDs.isEmpty else { return }
            ids = columnIDs
        } else {
            ids = Set(ImageListColumnID.allCases.filter { $0 != .thumbnail })
        }
        let rows = IndexSet(integersIn: 0..<imagePaths.count)
        tableView.reloadRows(in: rows, columnIDs: ids)
    }

    private func width(for columnID: ImageListColumnID) -> CGFloat {
        if columnID == .thumbnail {
            return max(columnID.minWidth, rowHeight * 2)
        }
        return columnID.defaultWidth
    }

    private func updateThumbnailColumnWidth() {
        guard let column = tableView.tableColumns.first(where: {
            $0.identifier.rawValue == ImageListColumnID.thumbnail.rawValue
        }) else { return }
        column.width = max(ImageListColumnID.thumbnail.minWidth, rowHeight * 2)
    }

    private func refreshHeaderTitles() {
        for tableColumn in tableView.tableColumns {
            guard let colID = ImageListColumnID(rawValue: tableColumn.identifier.rawValue) else { continue }
            tableColumn.title = headerTitle(for: colID)
            tableColumn.headerCell.alignment = colID.headerTextAlignment
        }
        headerView.needsDisplay = true
    }

    private func headerTitle(for column: ImageListColumnID) -> String {
        let title = column.title
        guard !title.isEmpty else { return title }
        let indicator = listHeaderSortIndicator(for: column)
        guard indicator.active else { return title }
        return title + (indicator.reversed ? "▼" : "▲")
    }

    private func syncSelection() {
        guard let currentPath,
              let row = imagePaths.firstIndex(of: currentPath) else {
            tableView.deselectAll(nil)
            return
        }
        if tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        scrollRowFullyOnScreen(row)
    }

    /// Scroll only if the active row is not fully in the unobscured viewport.
    func ensureActiveRowOnScreen() {
        revealActiveRow(force: false)
    }

    /// Port of Python `scroll_to_highlighted(force=)`. Home/End use `force: true`.
    func revealActiveRow(force: Bool) {
        guard let currentPath, let row = imagePaths.firstIndex(of: currentPath) else { return }
        if unobscuredVisibleRect().height < max(8, rowHeight) {
            pendingEnsureVisible = true
            return
        }
        scrollRowFullyOnScreen(row, force: force)
    }

    /// Rows live below the header, so the table clip is already unobscured.
    private func unobscuredVisibleRect() -> NSRect {
        tableView.visibleRect
    }

    /// Port of Python `scroll_to_highlighted`: both top and bottom of the row must be on screen.
    private func scrollRowFullyOnScreen(_ row: Int, force: Bool = false) {
        let rowRect = tableView.rect(ofRow: row)
        guard !rowRect.isNull, !rowRect.isEmpty else { return }
        let visible = unobscuredVisibleRect()
        guard visible.height > 0.5 else {
            pendingEnsureVisible = true
            return
        }

        let slop: CGFloat = 1
        let topOK = rowRect.minY >= visible.minY - slop
        let bottomOK = rowRect.maxY <= visible.maxY + slop
        if !force, topOK, bottomOK { return }

        var origin = tableView.visibleRect.origin
        if force, row == 0 || (!topOK && (bottomOK || rowRect.minY < visible.minY)) {
            origin.y += rowRect.minY - visible.minY
        } else if force, row == imagePaths.count - 1 || !bottomOK {
            origin.y += rowRect.maxY - visible.maxY
        } else if !topOK {
            origin.y += rowRect.minY - visible.minY
        } else if !bottomOK {
            origin.y += rowRect.maxY - visible.maxY
        } else if force {
            origin.y += rowRect.minY - visible.minY
        }
        let maxOriginY = max(0, tableView.bounds.height - tableView.visibleRect.height)
        origin.y = min(max(0, origin.y), maxOriginY)
        if abs(origin.y - tableView.visibleRect.origin.y) > 0.5 {
            scrollClip(to: origin)
        }
    }

    private func scrollClip(to origin: NSPoint) {
        let clip = scrollView.contentView
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    func rowBackground(for path: String) -> NSColor {
        let isCurrent = path == currentPath
        let isMultiSelected = selectedPaths.contains(path)
        if isMultiSelected && multiSelectMode {
            return NSColor(themeColors.multiselectBackground).withAlphaComponent(0.35)
        }
        if isCurrent {
            return NSColor(themeColors.currentImageBackground).withAlphaComponent(0.35)
        }
        if isMultiSelected {
            return NSColor(themeColors.multiselectBackground).withAlphaComponent(0.25)
        }
        return NSColor(themeColors.thumbnailGridBackground)
    }

    func textColor(for path: String) -> NSColor {
        let isCurrent = path == currentPath
        let isMultiSelected = selectedPaths.contains(path)
        if isCurrent {
            return NSColor(themeColors.currentImageBorder)
        }
        if isMultiSelected && multiSelectMode {
            return NSColor(themeColors.multiselectBorder)
        }
        return NSColor(themeColors.text)
    }

    // MARK: - ImageListHeaderDelegate

    func listHeaderDidRequestSort(for column: ImageListColumnID) {
        guard let mode = column.sortMode else { return }
        let toggle = sortMode == mode
        listDelegate?.imageListDidRequestColumnSort(mode, toggleReverse: toggle)
        refreshHeaderTitles()
    }

    func handleTableHeaderClick(_ tableColumn: NSTableColumn) {
        guard headerView.claimSortClick() else { return }
        guard let colID = ImageListColumnID(rawValue: tableColumn.identifier.rawValue) else { return }
        listHeaderDidRequestSort(for: colID)
    }

    func listHeaderDidToggleColumnVisibility(_ column: ImageListColumnID, visible: Bool) {
        columnLayout.setColumnVisible(column, visible: visible)
        if column == .comments {
            updateCommentsColumnActive(visible)
        }
        listDelegate?.imageListColumnLayoutDidChange(columnLayout)
        let reloadIDs = columnReloadIDsAfterVisibilityToggle(column, visible: visible)
        rebuildTableColumns(reloadColumnIDs: reloadIDs)
    }

    private func columnReloadIDsAfterVisibilityToggle(
        _ column: ImageListColumnID,
        visible: Bool
    ) -> Set<ImageListColumnID> {
        switch column {
        case .ext:
            return visible ? [.name, .ext] : [.name]
        case .comments:
            return visible ? [.comments] : []
        default:
            return visible ? [column] : []
        }
    }

    func listHeaderDidRequestDefaultColumnOrder() {
        columnLayout.applyDefaultColumnOrder()
        listDelegate?.imageListColumnLayoutDidChange(columnLayout)
        rebuildTableColumns()
    }

    func listHeaderSortIndicator(for column: ImageListColumnID) -> (active: Bool, reversed: Bool) {
        guard let mode = column.sortMode else { return (false, false) }
        let active: Bool
        switch mode {
        case .filesize:
            active = sortMode == .filesize || sortMode == .size
        default:
            active = sortMode == mode
        }
        return (active, sortReversed)
    }

    func listHeaderIsColumnVisible(_ column: ImageListColumnID) -> Bool {
        columnLayout.isColumnVisible(column)
    }

    func listHeaderNoteColumnDragEnded() {
        handleColumnsMoved()
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, !event.modifierFlags.contains(.command), let appState {
            MainWindowKeyViewLoop.moveFromMainCanvas(appState: appState)
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class ImageListTableView: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    weak var host: ImageListNSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dataSource = self
        delegate = self
        target = self
        doubleAction = #selector(doubleClickRow)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        dataSource = self
        delegate = self
        target = self
        doubleAction = #selector(doubleClickRow)
    }

    override func tile() {
        super.tile()
        host?.placeHeaderAboveTable()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        host?.imagePaths.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let host, let tableColumn, row >= 0, row < host.imagePaths.count else { return nil }
        let path = host.imagePaths[row]
        guard let columnID = ImageListColumnID(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let rowData = host.rowDataByPath[path]

        if columnID == .comments {
            let identifier = NSUserInterfaceItemIdentifier("ImageListCommentCell")
            let cell: ImageListCommentCell
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? ImageListCommentCell {
                cell = reused
            } else {
                cell = ImageListCommentCell()
                cell.identifier = identifier
            }
            let info = host.commentInfoByPath[path] ?? ImageListCommentInfo(indicator: .blank, fullComment: "")
            cell.configure(
                info: info,
                backgroundColor: host.rowBackground(for: path),
                colors: host.themeColors
            )
            return cell
        }

        if columnID == .thumbnail {
            let identifier = NSUserInterfaceItemIdentifier("ImageListThumbCell")
            let cell: ImageListThumbnailCell
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? ImageListThumbnailCell {
                cell = reused
            } else {
                cell = ImageListThumbnailCell()
                cell.identifier = identifier
            }
            let thumbHeight = max(28, host.rowHeight - 4)
            let thumbWidth = thumbHeight * 2
            cell.configure(
                path: path,
                thumbWidth: thumbWidth,
                thumbHeight: thumbHeight,
                backgroundColor: host.rowBackground(for: path),
                cache: host.thumbnailCache,
                refreshToken: host.thumbnailRefreshToken
            )
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("ImageListTextCell")
        let cell: ImageListTextCell
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? ImageListTextCell {
            cell = reused
        } else {
            cell = ImageListTextCell()
            cell.identifier = identifier
        }
        let text = textValue(for: columnID, rowData: rowData, path: path)
        cell.configure(
            text: text,
            alignment: columnID.textAlignment,
            textColor: host.textColor(for: path),
            backgroundColor: host.rowBackground(for: path),
            lineBreakMode: columnID == .date ? .byClipping : .byTruncatingMiddle
        )
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        host?.rowHeight ?? 48
    }

    func tableView(
        _ tableView: NSTableView,
        shouldReorderColumn columnIndex: Int,
        toColumn newColumnIndex: Int
    ) -> Bool {
        true
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        host?.handleTableHeaderClick(tableColumn)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {}

    func reloadCommentColumnRows(in paths: [String], host: ImageListNSView) {
        guard host.isCommentsColumnVisible else { return }
        var rows = IndexSet()
        for path in paths {
            if let row = host.imagePaths.firstIndex(of: path) {
                rows.insert(row)
            }
        }
        guard !rows.isEmpty else { return }
        reloadRows(in: rows, columnIDs: [.comments])
    }

    func reloadRows(in rowIndexes: IndexSet, columnIDs: Set<ImageListColumnID>) {
        guard !rowIndexes.isEmpty, !columnIDs.isEmpty else { return }
        let columnIndexes = IndexSet(
            tableColumns.enumerated().compactMap { index, column in
                guard let id = ImageListColumnID(rawValue: column.identifier.rawValue),
                      columnIDs.contains(id) else { return nil }
                return index
            }
        )
        guard !columnIndexes.isEmpty else { return }
        reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
    }

    private func textValue(for column: ImageListColumnID, rowData: ImageListRowData?, path: String) -> String {
        switch column {
        case .permissions: return rowData?.permissions ?? "----------"
        case .date: return rowData?.dateText ?? ""
        case .size: return rowData?.sizeText ?? ""
        case .dimensions: return rowData?.dimensionsText ?? ""
        case .name:
            let raw = rowData?.nameText ?? (path as NSString).lastPathComponent
            if host?.columnLayout.isColumnVisible(.ext) == true {
                return ImageListRowFormatting.nameOmittingExtension(raw, path: path)
            }
            return raw
        case .ext:
            return rowData?.extensionText ?? (path as NSString).pathExtension
        case .comments:
            return host?.commentInfoByPath[path]?.indicator.displayText ?? ""
        case .thumbnail: return ""
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard let host, row >= 0, row < host.imagePaths.count else {
            super.mouseDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control), !flags.contains(.command) {
            super.mouseDown(with: event)
            return
        }
        let path = host.imagePaths[row]
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        host.listDelegate?.imageListDidClick(
            index: row,
            path: path,
            shiftPressed: flags.contains(.shift),
            cmdPressed: flags.contains(.command),
            ctrlPressed: flags.contains(.control)
        )
    }

    @objc private func doubleClickRow() {
        guard let host, selectedRow >= 0, selectedRow < host.imagePaths.count else { return }
        let path = host.imagePaths[selectedRow]
        host.listDelegate?.imageListDidOpenBrowse(index: selectedRow, path: path)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let host, let appState = host.appState else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        guard row >= 0 else { return }
        ThumbnailContextMenu.show(for: event, clickedIndex: row, in: self, appState: appState)
    }
}

@MainActor
private final class ImageListThumbnailCell: NSTableCellView {
    private let thumbView = NSImageView()
    private var loadTask: Task<Void, Never>?
    private var configuredPath: String?
    private var configuredRefreshToken = -1
    private var loadingPath: String?
    private var loadingRefreshToken = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(thumbView)
        NSLayoutConstraint.activate([
            thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 40),
            thumbView.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        path: String,
        thumbWidth: CGFloat,
        thumbHeight: CGFloat,
        backgroundColor: NSColor,
        cache: ThumbnailCache?,
        refreshToken: Int
    ) {
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        if let width = thumbView.constraints.first(where: { $0.firstAttribute == .width }) {
            width.constant = thumbWidth
        }
        if let height = thumbView.constraints.first(where: { $0.firstAttribute == .height }) {
            height.constant = thumbHeight
        }

        let pathChanged = configuredPath != path
        let tokenChanged = configuredRefreshToken != refreshToken
        configuredPath = path
        configuredRefreshToken = refreshToken

        if !pathChanged, !tokenChanged {
            if thumbView.image != nil { return }
            if loadTask != nil, loadingPath == path, loadingRefreshToken == refreshToken { return }
        }

        loadTask?.cancel()
        loadingPath = path
        loadingRefreshToken = refreshToken
        if pathChanged || tokenChanged {
            thumbView.image = nil
        }
        let pixelSize = Int(max(28, thumbHeight))
        loadTask = Task { @MainActor in
            guard let cache,
                  let cgImage = await cache.generateThumbnail(for: path, size: pixelSize) else {
                if loadingPath == path, loadingRefreshToken == refreshToken {
                    loadingPath = nil
                }
                return
            }
            guard !Task.isCancelled, configuredPath == path, configuredRefreshToken == refreshToken else { return }
            thumbView.image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
            if loadingPath == path {
                loadingPath = nil
            }
        }
    }

    func applyHighlight(backgroundColor: NSColor) {
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
    }
}

@MainActor
private final class ImageListCommentCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var commentInfo = ImageListCommentInfo(indicator: .blank, fullComment: "")
    private var themeColors = ThemeColors.dark

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 16)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    func configure(info: ImageListCommentInfo, backgroundColor: NSColor, colors: ThemeColors) {
        commentInfo = info
        themeColors = colors
        label.stringValue = info.indicator.displayText
        applyHighlight(backgroundColor: backgroundColor)
    }

    func applyHighlight(backgroundColor: NSColor) {
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        let tip = commentInfo.tooltipText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tip.isEmpty else { return }
        ListPromptTooltip.shared.scheduleShow(text: tip, colors: themeColors, anchorView: self)
    }

    override func mouseExited(with event: NSEvent) {
        ListPromptTooltip.shared.hide(for: self)
    }
}

@MainActor
private final class ImageListTextCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        text: String,
        alignment: NSTextAlignment,
        textColor: NSColor,
        backgroundColor: NSColor,
        lineBreakMode: NSLineBreakMode = .byTruncatingMiddle
    ) {
        label.stringValue = text
        label.alignment = alignment
        label.lineBreakMode = lineBreakMode
        applyHighlight(textColor: textColor, backgroundColor: backgroundColor)
    }

    func applyHighlight(textColor: NSColor, backgroundColor: NSColor) {
        label.textColor = textColor
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
    }
}

struct ImageListNSViewRepresentable: NSViewRepresentable {
    @Environment(AppState.self) private var appState

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> ImageListNSView {
        let view = ImageListNSView()
        view.listDelegate = context.coordinator
        view.appState = appState
        view.thumbnailCache = appState.thumbnailCache
        context.coordinator.listView = view
        appState.listViewHost = view
        context.coordinator.syncFromAppState()
        return view
    }

    func updateNSView(_ nsView: ImageListNSView, context: Context) {
        context.coordinator.syncFromAppState()
    }

    @MainActor
    final class Coordinator: NSObject, ImageListDelegate {
        let appState: AppState
        weak var listView: ImageListNSView?

        init(appState: AppState) {
            self.appState = appState
        }

        private var eventSubscriptions: EventBusSubscriptionBag?
        private var didLoadColumnLayout = false

        func syncFromAppState() {
            guard let listView else { return }
            if !didLoadColumnLayout {
                listView.applyColumnLayoutFromSettings(appState.config)
                didLoadColumnLayout = true
            }
            let paths = appState.fileData.displayedImages
            if listView.imagePaths != paths {
                listView.rowDataByPath = ImageListRowFormatting.buildRowDataMap(
                    paths: paths,
                    metadataCache: appState.metadataCache
                )
                listView.imagePaths = paths
            }
            listView.currentPath = appState.fileData.currentImagePath
            listView.selectedPaths = appState.selection.selectedFiles
            listView.multiSelectMode = appState.selection.multiSelectMode
            listView.rowHeight = CGFloat(appState.config.int(forKey: "list_view_row_height", default: 48))
            listView.thumbnailRefreshToken = appState.thumbnailInvalidationGeneration
            listView.themeColors = appState.theme.colors
            let mode = SortMode(rawValue: appState.config.string(forKey: "sort_mode", default: "date")) ?? .date
            let reversed = appState.config.bool(forKey: "sort_reversed", default: false)
            listView.updateSortIndicators(mode: mode, reversed: reversed)
            let commentsVisible = listView.columnLayout.isColumnVisible(.comments)
            listView.updateCommentsColumnActive(commentsVisible)
            installSelectionObserverIfNeeded()
            if appState.fileData.currentViewMode == .list {
                listView.ensureActiveRowOnScreen()
            }
        }

        private func installSelectionObserverIfNeeded() {
            guard eventSubscriptions == nil else { return }
            let bag = EventBusSubscriptionBag(bus: appState.eventBus)
            eventSubscriptions = bag
            bag.subscribe(.selectionChanged) { [weak self] _ in
                self?.syncSelectionVisuals()
            }
            bag.subscribe(.currentImageChanged) { [weak self] _ in
                self?.syncSelectionVisuals()
            }
            bag.subscribe(.viewModeChanged) { [weak self] _ in
                guard let self, self.appState.fileData.currentViewMode == .list else { return }
                self.syncSelectionVisuals()
                self.listView?.ensureActiveRowOnScreen()
                DispatchQueue.main.async { [weak self] in
                    self?.listView?.ensureActiveRowOnScreen()
                }
            }
        }

        private func syncSelectionVisuals() {
            guard let listView else { return }
            listView.selectedPaths = appState.selection.selectedFiles
            listView.multiSelectMode = appState.selection.multiSelectMode
            listView.currentPath = appState.fileData.currentImagePath
        }

        func imageListDidSelect(index: Int, path: String) {
            if appState.selection.multiSelectMode {
                SelectionService.clearSelection(appState: appState)
            }
            SelectionService.selectThumbnail(appState: appState, index: index, addToSelection: false)
        }

        func imageListDidClick(
            index: Int,
            path: String,
            shiftPressed: Bool,
            cmdPressed: Bool,
            ctrlPressed: Bool
        ) {
            SelectionService.handleThumbnailClick(
                appState: appState,
                index: index,
                cmdPressed: cmdPressed,
                shiftPressed: shiftPressed,
                ctrlPressed: ctrlPressed
            )
            if !shiftPressed, !cmdPressed, !ctrlPressed {
                SelectionService.openBrowseFromThumbnailActivation(
                    appState: appState,
                    path: path,
                    isDoubleClick: false
                )
            }
        }

        func imageListDidOpenBrowse(index: Int, path: String) {
            SelectionService.openBrowseFromThumbnailActivation(
                appState: appState,
                path: path,
                isDoubleClick: true
            )
        }

        func imageListShowContextMenu(for event: NSEvent, clickedIndex: Int, in view: NSView) {}

        func imageListDidRequestColumnSort(_ mode: SortMode, toggleReverse: Bool) {
            appState.applyListColumnHeaderSort(mode, toggleReverse: toggleReverse)
            guard let listView else { return }
            let reversed = appState.config.bool(forKey: "sort_reversed", default: false)
            listView.updateSortIndicators(mode: mode, reversed: reversed)
        }

        func imageListColumnLayoutDidChange(_ layout: ImageListColumnLayout) {
            layout.save(to: appState.config, eventBus: appState.eventBus)
        }
    }
}
