import AppKit
import SwiftUI

@MainActor
protocol ImageListDelegate: AnyObject {
    func imageListDidSelect(index: Int, path: String)
    func imageListDidOpenBrowse(index: Int, path: String)
    func imageListShowContextMenu(for event: NSEvent, clickedIndex: Int, in view: NSView)
}

/// AppKit list view with right-click context menu support.
@MainActor
final class ImageListNSView: NSView {
    weak var listDelegate: ImageListDelegate?
    weak var appState: AppState?
    weak var thumbnailCache: ThumbnailCache?

    private let scrollView = NSScrollView()
    private let tableView = ImageListTableView(frame: .zero)

    var imagePaths: [String] = [] {
        didSet {
            tableView.host = self
            tableView.reloadData()
            syncSelection()
        }
    }

    var currentPath: String? {
        didSet { syncSelection() }
    }

    var rowHeight: CGFloat = 48 {
        didSet {
            tableView.rowHeight = rowHeight
            tableView.reloadData()
        }
    }

    var thumbnailRefreshToken = 0 {
        didSet { tableView.reloadData() }
    }

    var themeColors = ThemeColors.dark

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        tableView.host = self
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("image"))
        column.width = 400
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
        guard let host, row >= 0, row < host.imagePaths.count else { return nil }
        let path = host.imagePaths[row]
        let identifier = NSUserInterfaceItemIdentifier("ImageListRow")
        let cell: ImageListRowCell
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? ImageListRowCell {
            cell = reused
        } else {
            cell = ImageListRowCell()
            cell.identifier = identifier
        }
        let thumbSize = max(28, host.rowHeight - 8)
        cell.configure(
            path: path,
            selected: path == host.currentPath,
            thumbSize: thumbSize,
            cache: host.thumbnailCache,
            refreshToken: host.thumbnailRefreshToken,
            colors: host.themeColors
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let host, selectedRow >= 0, selectedRow < host.imagePaths.count else { return }
        let path = host.imagePaths[selectedRow]
        host.listDelegate?.imageListDidSelect(index: selectedRow, path: path)
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
private final class ImageListRowCell: NSTableCellView {
    private let thumbView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private var loadTask: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.lineBreakMode = .byTruncatingMiddle
        sizeLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [nameLabel, sizeLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        let row = NSStackView(views: [thumbView, textStack])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbView.widthAnchor.constraint(equalToConstant: 40),
            thumbView.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        path: String,
        selected: Bool,
        thumbSize: CGFloat,
        cache: ThumbnailCache?,
        refreshToken: Int,
        colors: ThemeColors
    ) {
        loadTask?.cancel()
        nameLabel.stringValue = (path as NSString).lastPathComponent
        nameLabel.textColor = selected ? NSColor(colors.currentImageBorder) : NSColor(colors.text)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? NSNumber {
            sizeLabel.stringValue = ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
        } else {
            sizeLabel.stringValue = ""
        }
        layer?.backgroundColor = selected
            ? NSColor(colors.currentImageBackground).withAlphaComponent(0.35).cgColor
            : NSColor(colors.thumbnailGridBackground).cgColor
        wantsLayer = true

        thumbView.image = nil
        let pixelSize = Int(max(28, thumbSize))
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

        func syncFromAppState() {
            guard let listView else { return }
            listView.imagePaths = appState.fileData.displayedImages
            listView.currentPath = appState.fileData.currentImagePath
            listView.rowHeight = CGFloat(appState.config.int(forKey: "list_view_row_height", default: 48))
            listView.thumbnailRefreshToken = appState.thumbnailInvalidationGeneration
            listView.themeColors = appState.theme.colors
        }

        func imageListDidSelect(index: Int, path: String) {
            appState.fileData.setCurrentIndex(index)
            appState.fileData.setCurrentImagePath(path)
        }

        func imageListDidOpenBrowse(index: Int, path: String) {
            appState.fileData.setCurrentIndex(index)
            appState.fileData.setCurrentImagePath(path)
            appState.fileData.setViewMode(.browse)
        }

        func imageListShowContextMenu(for event: NSEvent, clickedIndex: Int, in view: NSView) {}
    }
}
