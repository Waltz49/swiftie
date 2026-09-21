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
    private let headerView = ImageListTableHeaderView(frame: .zero)
    private var columnMoveObserver: NSObjectProtocol?

    var imagePaths: [String] = [] {
        didSet {
            guard oldValue != imagePaths else { return }
            tableView.host = self
            tableView.reloadData()
            syncSelection()
            headerView.needsDisplay = true
        }
    }

    var rowDataByPath: [String: ImageListRowData] = [:] {
        didSet {
            tableView.reloadData()
        }
    }

    var currentPath: String? {
        didSet {
            guard oldValue != currentPath else { return }
            syncSelection()
            tableView.reloadData()
        }
    }

    var selectedPaths: Set<String> = [] {
        didSet {
            guard oldValue != selectedPaths else { return }
            tableView.reloadData()
        }
    }

    var multiSelectMode = false {
        didSet {
            guard oldValue != multiSelectMode else { return }
            tableView.reloadData()
        }
    }

    var rowHeight: CGFloat = 48 {
        didSet {
            tableView.rowHeight = rowHeight
            headerView.frame.size.height = rowHeight
            updateThumbnailColumnWidth()
            tableView.reloadData()
        }
    }

    var thumbnailRefreshToken = 0 {
        didSet {
            guard oldValue != thumbnailRefreshToken else { return }
            tableView.reloadData()
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
    }

    func applyColumnLayoutFromSettings(_ config: AppConfig) {
        columnLayout.load(from: config)
        rebuildTableColumns()
    }

    func updateSortIndicators(mode: SortMode, reversed: Bool) {
        sortMode = mode
        sortReversed = reversed
        refreshHeaderTitles()
        headerView.needsDisplay = true
    }

    private func configure() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView.host = self
        tableView.style = .plain
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.gridStyleMask = .solidVerticalGridLineMask
        tableView.gridColor = NSColor.separatorColor.withAlphaComponent(0.35)

        headerView.headerDelegate = self
        headerView.frame.size.height = rowHeight
        tableView.headerView = headerView

        scrollView.documentView = tableView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

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
    }

    private func handleColumnsMoved() {
        columnLayout.syncOrderFromTableColumns(tableView)
        listDelegate?.imageListColumnLayoutDidChange(columnLayout)
        headerView.needsDisplay = true
    }

    private func rebuildTableColumns() {
        while tableView.tableColumns.count > 0 {
            tableView.removeTableColumn(tableView.tableColumns[0])
        }
        for columnID in columnLayout.visibleColumns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(columnID.rawValue))
            column.title = columnID.title
            column.minWidth = columnID.minWidth
            column.width = width(for: columnID)
            column.headerCell.alignment = columnID.textAlignment
            if columnID == .name {
                column.resizingMask = [.autoresizingMask, .userResizingMask]
            } else {
                column.resizingMask = .userResizingMask
            }
            tableView.addTableColumn(column)
        }
        refreshHeaderTitles()
        tableView.reloadData()
        headerView.needsDisplay = true
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
            tableColumn.title = colID.title
        }
    }

    private func syncSelection() {
        guard let currentPath,
              let row = imagePaths.firstIndex(of: currentPath) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
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
    }

    func listHeaderDidToggleColumnVisibility(_ column: ImageListColumnID, visible: Bool) {
        columnLayout.setColumnVisible(column, visible: visible)
        listDelegate?.imageListColumnLayoutDidChange(columnLayout)
        rebuildTableColumns()
    }

    func listHeaderDidReorderColumns() {
        handleColumnsMoved()
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

    func listHeaderDirectoryAnnotation(forNameColumnWidth: CGFloat) -> String? {
        guard !imagePaths.isEmpty else { return nil }
        var directories = Set<String>()
        for path in imagePaths {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            directories.insert(dir)
        }
        if directories.count == 1, let only = directories.first {
            return InformationFormatting.normalizePathForDisplay(only)
        }
        return "Multiple directories"
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

    func numberOfRows(in tableView: NSTableView) -> Int {
        host?.imagePaths.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let host, let tableColumn, row >= 0, row < host.imagePaths.count else { return nil }
        let path = host.imagePaths[row]
        guard let columnID = ImageListColumnID(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let rowData = host.rowDataByPath[path]

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
            backgroundColor: host.rowBackground(for: path)
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

    func tableViewSelectionDidChange(_ notification: Notification) {}

    private func textValue(for column: ImageListColumnID, rowData: ImageListRowData?, path: String) -> String {
        switch column {
        case .permissions: return rowData?.permissions ?? "----------"
        case .date: return rowData?.dateText ?? ""
        case .size: return rowData?.sizeText ?? ""
        case .dimensions: return rowData?.dimensionsText ?? ""
        case .name: return rowData?.nameText ?? (path as NSString).lastPathComponent
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

        let needsThumbnailLoad = configuredPath != path
            || configuredRefreshToken != refreshToken
            || thumbView.image == nil
        configuredPath = path
        configuredRefreshToken = refreshToken
        guard needsThumbnailLoad else { return }

        loadTask?.cancel()
        thumbView.image = nil
        let pixelSize = Int(max(28, thumbHeight))
        loadTask = Task {
            guard let cache,
                  let cgImage = await cache.generateThumbnail(for: path, size: pixelSize) else { return }
            guard !Task.isCancelled else { return }
            thumbView.image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }
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

    func configure(text: String, alignment: NSTextAlignment, textColor: NSColor, backgroundColor: NSColor) {
        label.stringValue = text
        label.alignment = alignment
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
                listView.imagePaths = paths
                listView.rowDataByPath = ImageListRowFormatting.buildRowDataMap(
                    paths: paths,
                    metadataCache: appState.metadataCache
                )
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
            installSelectionObserverIfNeeded()
        }

        private func installSelectionObserverIfNeeded() {
            guard eventSubscriptions == nil else { return }
            let bag = EventBusSubscriptionBag(bus: appState.eventBus)
            eventSubscriptions = bag
            bag.subscribe(.selectionChanged) { [weak self] _ in
                self?.syncSelectionVisuals()
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
