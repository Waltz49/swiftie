import AppKit

@MainActor
protocol ImageListHeaderDelegate: AnyObject {
    func listHeaderDidRequestSort(for column: ImageListColumnID)
    func listHeaderDidToggleColumnVisibility(_ column: ImageListColumnID, visible: Bool)
    func listHeaderSortIndicator(for column: ImageListColumnID) -> (active: Bool, reversed: Bool)
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

}
