import AppKit

@MainActor
protocol ImageListHeaderDelegate: AnyObject {
    func listHeaderDidRequestSort(for column: ImageListColumnID)
    func listHeaderDidToggleColumnVisibility(_ column: ImageListColumnID, visible: Bool)
    func listHeaderDidReorderColumns()
    func listHeaderSortIndicator(for column: ImageListColumnID) -> (active: Bool, reversed: Bool)
    func listHeaderDirectoryAnnotation(forNameColumnWidth: CGFloat) -> String?
    func listHeaderIsColumnVisible(_ column: ImageListColumnID) -> Bool
    func listHeaderNoteColumnDragEnded()
}

/// Column header: click to sort, drag to reorder, right-click for visibility menu.
@MainActor
final class ImageListTableHeaderView: NSTableHeaderView {
    weak var headerDelegate: ImageListHeaderDelegate?

    private var pressLocation: NSPoint?
    private var pressedColumnIndex = -1
    private var suppressClickSort = false

    private let clickDragThreshold: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        pressLocation = convert(event.locationInWindow, from: nil)
        pressedColumnIndex = tableView?.column(at: pressLocation ?? .zero) ?? -1
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressLocation = nil
            pressedColumnIndex = -1
        }
        super.mouseUp(with: event)

        guard event.buttonNumber == 0,
              !suppressClickSort,
              let tableView,
              let start = pressLocation else { return }
        let end = convert(event.locationInWindow, from: nil)
        let distance = hypot(end.x - start.x, end.y - start.y)
        guard distance < clickDragThreshold else {
            headerDelegate?.listHeaderNoteColumnDragEnded()
            return
        }

        let columnIndex = pressedColumnIndex >= 0 ? pressedColumnIndex : tableView.column(at: end)
        guard columnIndex >= 0, columnIndex < tableView.tableColumns.count else { return }
        let colID = ImageListColumnID(rawValue: tableView.tableColumns[columnIndex].identifier.rawValue)
        if let colID, colID.sortMode != nil {
            headerDelegate?.listHeaderDidRequestSort(for: colID)
            needsDisplay = true
        }
    }

    func noteColumnMovedByUser() {
        suppressClickSort = true
        headerDelegate?.listHeaderNoteColumnDragEnded()
        DispatchQueue.main.async { [weak self] in
            self?.suppressClickSort = false
        }
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
            let indicator = headerDelegate.listHeaderSortIndicator(for: colID)
            if indicator.active {
                drawSortCaret(in: headerRect, column: tableColumn, reversed: indicator.reversed)
            }
            if colID == .name,
               let directory = headerDelegate.listHeaderDirectoryAnnotation(forNameColumnWidth: headerRect.width) {
                drawDirectoryAnnotation(directory, in: headerRect)
            }
        }
    }

    private func showColumnVisibilityMenu(with event: NSEvent) {
        guard let headerDelegate else { return }
        let menu = NSMenu()
        for column in ImageListColumnID.defaultOrder {
            guard column.canHide else { continue }
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
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func toggleColumnVisibility(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? ImageListColumnID,
              let headerDelegate else { return }
        let visible = headerDelegate.listHeaderIsColumnVisible(column)
        headerDelegate.listHeaderDidToggleColumnVisibility(column, visible: !visible)
    }

    private func drawSortCaret(in headerRect: NSRect, column: NSTableColumn, reversed: Bool) {
        let title = column.title
        guard !title.isEmpty else { return }
        let font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let titleSize = (title as NSString).size(withAttributes: attributes)
        let alignment = column.headerCell.alignment
        var caretX = headerRect.minX + 4
        switch alignment {
        case .center:
            caretX = headerRect.midX + titleSize.width / 2 + 4
        case .right:
            caretX = headerRect.maxX - titleSize.width - 8
        default:
            caretX = headerRect.minX + titleSize.width + 8
        }
        let caretY = headerRect.midY
        let path = NSBezierPath()
        path.lineWidth = 1.5
        NSColor.white.setStroke()
        let half: CGFloat = 3
        if reversed {
            path.move(to: NSPoint(x: caretX - half, y: caretY - half))
            path.line(to: NSPoint(x: caretX, y: caretY + half))
            path.line(to: NSPoint(x: caretX + half, y: caretY - half))
        } else {
            path.move(to: NSPoint(x: caretX - half, y: caretY + half))
            path.line(to: NSPoint(x: caretX, y: caretY - half))
            path.line(to: NSPoint(x: caretX + half, y: caretY + half))
        }
        path.stroke()
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
