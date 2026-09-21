import AppKit

@MainActor
protocol ImageListHeaderDelegate: AnyObject {
    func listHeaderDidRequestSort(for column: ImageListColumnID)
    func listHeaderDidToggleColumnVisibility(_ column: ImageListColumnID, visible: Bool)
    func listHeaderSortIndicator(for column: ImageListColumnID) -> (active: Bool, reversed: Bool)
    func listHeaderDirectoryAnnotation(forNameColumnWidth: CGFloat) -> String?
    func listHeaderIsColumnVisible(_ column: ImageListColumnID) -> Bool
    func listHeaderDidRequestDefaultColumnOrder()
    func listHeaderNoteColumnDragEnded()
}

/// Column header: click to sort, drag to reorder, right-click for visibility menu.
@MainActor
final class ImageListTableHeaderView: NSTableHeaderView {
    weak var headerDelegate: ImageListHeaderDelegate?

    /// List header matches row height; AppKit `tile()` must not shrink it.
    var pinnedHeight: CGFloat = 48 {
        didSet {
            guard abs(oldValue - pinnedHeight) > 0.5 else { return }
            var f = frame
            f.size.height = pinnedHeight
            super.frame = f
        }
    }

    override var frame: NSRect {
        get { super.frame }
        set {
            var adjusted = newValue
            if pinnedHeight > 0 {
                adjusted.size.height = pinnedHeight
            }
            super.frame = adjusted
        }
    }

    private var pressLocation: NSPoint?
    private var pressedColumnIndex = -1
    private var suppressClickSort = false
    private var handledSortClick = false

    private let clickDragThreshold: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        pressLocation = convert(event.locationInWindow, from: nil)
        pressedColumnIndex = column(at: pressLocation ?? .zero)
        handledSortClick = false
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressLocation = nil
            pressedColumnIndex = -1
        }
        super.mouseUp(with: event)

        guard event.buttonNumber == 0,
              let tableView,
              let start = pressLocation else { return }
        let end = convert(event.locationInWindow, from: nil)
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance < clickDragThreshold else {
            headerDelegate?.listHeaderNoteColumnDragEnded()
            return
        }

        let columnIndex = pressedColumnIndex >= 0 ? pressedColumnIndex : column(at: end)
        guard columnIndex >= 0, columnIndex < tableView.tableColumns.count else { return }
        let colID = ImageListColumnID(rawValue: tableView.tableColumns[columnIndex].identifier.rawValue)
        if let colID, colID.sortMode != nil, claimSortClick() {
            headerDelegate?.listHeaderDidRequestSort(for: colID)
            needsDisplay = true
        }
    }

    func noteColumnMovedByUser() {
        suppressClickSort = true
        handledSortClick = true
        headerDelegate?.listHeaderNoteColumnDragEnded()
        DispatchQueue.main.async { [weak self] in
            self?.suppressClickSort = false
        }
    }

    /// True if this header click should trigger a sort (first claimant wins).
    func claimSortClick() -> Bool {
        if suppressClickSort || handledSortClick { return false }
        handledSortClick = true
        return true
    }

    override func rightMouseDown(with event: NSEvent) {
        showColumnVisibilityMenu(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let tableView, let headerDelegate else { return }
        for (index, tableColumn) in tableView.tableColumns.enumerated() {
            guard let colID = ImageListColumnID(rawValue: tableColumn.identifier.rawValue) else { continue }
            let headerRect = headerRect(ofColumn: index)
            guard headerRect.intersects(dirtyRect) else { continue }
            if colID == .name,
               let directory = headerDelegate.listHeaderDirectoryAnnotation(forNameColumnWidth: headerRect.width) {
                drawDirectoryAnnotation(directory, in: headerRect)
            }
        }
    }

    private func showColumnVisibilityMenu(with event: NSEvent) {
        guard let headerDelegate else { return }
        let menu = NSMenu()
        for column in ImageListColumnID.columnSelectorMenuOrder {
            let visible = headerDelegate.listHeaderIsColumnVisible(column)
            let mark = visible ? "✓" : " "
            let item = NSMenuItem(
                title: "\(mark) \(column.menuTitle)",
                action: #selector(toggleColumnVisibility(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = column
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let resetItem = NSMenuItem(
            title: "Use Default Order",
            action: #selector(useDefaultColumnOrder(_:)),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func useDefaultColumnOrder(_ sender: NSMenuItem) {
        headerDelegate?.listHeaderDidRequestDefaultColumnOrder()
    }

    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? ImageListColumnID,
              let headerDelegate else { return }
        let visible = headerDelegate.listHeaderIsColumnVisible(column)
        headerDelegate.listHeaderDidToggleColumnVisibility(column, visible: !visible)
    }

    private func drawDirectoryAnnotation(_ text: String, in headerRect: NSRect) {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let color = NSColor(calibratedRed: 0.78, green: 0.78, blue: 0.98, alpha: 1)
        let margin: CGFloat = 30
        let maxWidth = max(20, headerRect.width - margin - 60)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let elided = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: headerRect.height),
            options: [.usesLineFragmentOrigin],
            attributes: attributes
        )
        let drawRect = NSRect(
            x: headerRect.minX,
            y: headerRect.minY,
            width: headerRect.width - margin,
            height: headerRect.height
        )
        let fitted = NSMutableAttributedString(
            string: text,
            attributes: attributes
        )
        if elided.width > maxWidth {
            fitted.mutableString.setString(
                "…" + String(text.suffix(max(8, Int(maxWidth / 7))))
            )
        }
        fitted.draw(with: drawRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
    }
}
