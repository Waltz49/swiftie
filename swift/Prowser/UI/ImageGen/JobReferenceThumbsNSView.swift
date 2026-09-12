import AppKit

/// Reference thumbnails for a job card in right-aligned rows that wrap to the
/// available width (Python ``_FlowReferenceThumbs`` in ``job_queue_panel.py``).
@MainActor
final class JobReferenceThumbsNSView: NSView {
    override var isFlipped: Bool { true }

    /// Click anywhere on the thumbs: one image → browse; several → custom-sort level
    /// (Python ``open_reference_thumbnail_paths``).
    var onOpenPaths: (([String]) -> Void)?

    private(set) var paths: [String] = []
    private(set) var referencesInvalid = false
    private var cells: [JobReferenceThumbCell] = []
    private var forcedColumns: Int?

    private static let thumbSize = JobQueueLayout.thumbSize
    private static let thumbGap = JobQueueLayout.thumbGap
    /// Python outer layout margins ``(0, 2, 0, 0)`` plus ``+4`` in ``_content_height``.
    private static let topInset: CGFloat = 2
    private static let heightSlack: CGFloat = 4

    var cellCount: Int { cells.count }

    /// Python ``_valid_preview_paths``.
    static func validPreviewPaths(_ paths: [String]) -> [String] {
        paths.compactMap { raw in
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
                return nil
            }
            return path
        }
    }

    /// Python ``JobCard._ref_count``: one placeholder cell when references are invalid.
    static func cellCount(paths: [String], referencesInvalid: Bool) -> Int {
        referencesInvalid ? 1 : validPreviewPaths(paths).count
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(paths: [String], referencesInvalid: Bool, colors: ThemeColors) {
        let valid = referencesInvalid ? [] : Self.validPreviewPaths(paths)
        if valid == self.paths, referencesInvalid == self.referencesInvalid, !cells.isEmpty || valid.isEmpty {
            cells.forEach { $0.applyTheme(colors) }
            return
        }
        self.paths = valid
        self.referencesInvalid = referencesInvalid
        cells.forEach { $0.removeFromSuperview() }
        cells = []
        if referencesInvalid {
            let cell = JobReferenceThumbCell(kind: .invalidPlaceholder)
            cell.applyTheme(colors)
            addSubview(cell)
            cells = [cell]
        } else {
            for path in valid {
                let cell = JobReferenceThumbCell(kind: .image(path: path))
                cell.applyTheme(colors)
                addSubview(cell)
                cells.append(cell)
            }
        }
        needsLayout = true
    }

    func applyTheme(_ colors: ThemeColors) {
        cells.forEach { $0.applyTheme(colors) }
    }

    /// Python ``reflow_to_width(..., force_cols=1)`` for the inline (beside status) layout.
    func setForcedColumns(_ columns: Int?) {
        guard columns != forcedColumns else { return }
        forcedColumns = columns
        needsLayout = true
    }

    /// Python ``_cols_for_width``.
    func columns(forWidth width: CGFloat) -> Int {
        if let forcedColumns { return max(1, forcedColumns) }
        let w = max(width, Self.thumbSize)
        let stride = Self.thumbSize + Self.thumbGap
        return max(1, Int((w + Self.thumbGap) / stride))
    }

    /// Python ``_content_height``.
    func contentHeight(forWidth width: CGFloat) -> CGFloat {
        let n = cells.count
        guard n > 0 else { return 0 }
        let cols = columns(forWidth: width)
        let rows = (n + cols - 1) / cols
        return CGFloat(rows) * (Self.thumbSize + Self.thumbGap) - Self.thumbGap + Self.heightSlack
    }

    /// Python ``_content_width`` (first row width).
    func contentWidth(forWidth width: CGFloat) -> CGFloat {
        let n = cells.count
        guard n > 0 else { return 0 }
        let count = min(columns(forWidth: width), n)
        return CGFloat(count) * Self.thumbSize + CGFloat(count - 1) * Self.thumbGap
    }

    override func layout() {
        super.layout()
        guard !cells.isEmpty else { return }
        let cols = columns(forWidth: bounds.width)
        let size = Self.thumbSize
        let gap = Self.thumbGap
        var index = 0
        var y = Self.topInset
        while index < cells.count {
            let rowCells = Array(cells[index ..< min(index + cols, cells.count)])
            let rowWidth = CGFloat(rowCells.count) * size + CGFloat(rowCells.count - 1) * gap
            // Rows are right-aligned (Python ``addStretch(1)`` before the cells).
            var x = bounds.width - rowWidth
            for cell in rowCells {
                cell.frame = NSRect(x: x, y: y, width: size, height: size)
                x += size + gap
            }
            y += size + gap
            index += cols
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !referencesInvalid, !paths.isEmpty else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard !referencesInvalid, !paths.isEmpty else {
            super.mouseDown(with: event)
            return
        }
        onOpenPaths?(paths)
    }
}

/// One 55px job thumbnail: EXIF-oriented image, hover-only 1px border, basename tooltip
/// (Python ``create_job_status_thumbnail_label`` / ``create_invalid_job_preview_label``).
@MainActor
final class JobReferenceThumbCell: NSView {
    enum Kind {
        case image(path: String)
        case invalidPlaceholder
    }

    override var isFlipped: Bool { true }

    private let kind: Kind
    private var image: NSImage?
    private var hovered = false
    private var borderColor = NSColor.gray
    private var trackingArea: NSTrackingArea?

    private static let imageCache = NSCache<NSString, NSImage>()

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        switch kind {
        case .image(let path):
            toolTip = (path as NSString).lastPathComponent
            image = Self.thumbnailImage(for: path)
        case .invalidPlaceholder:
            toolTip = "Reference files for this job are missing"
            image = AppAssets.nsImage(name: "job_invalid_ref_preview", fileExtension: "svg")
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyTheme(_ colors: ThemeColors) {
        borderColor = NSColor(colors.multiselectBorder)
        needsDisplay = true
    }

    /// Python ``load_dialog_thumbnail``: EXIF-corrected image, ``noimage`` placeholder otherwise.
    private static func thumbnailImage(for path: String) -> NSImage? {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(path)|\(mtime)" as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }
        let pixelSize = Int(JobQueueLayout.thumbSize * 2)
        let loaded = ImageDisplayLoader.orientedImage(for: path, maxPixelSize: pixelSize)
            ?? AppAssets.nsImage(name: "noimage")
        if let loaded {
            imageCache.setObject(loaded, forKey: key)
        }
        return loaded
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        // Let the flow container handle clicks (opens references).
        superview?.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        // 1px transparent border keeps the box size; only the hover state paints it.
        let inner = bounds.insetBy(dx: 1, dy: 1)
        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = min(inner.width / image.size.width, inner.height / image.size.height)
            let w = image.size.width * scale
            let h = image.size.height * scale
            let rect = NSRect(x: inner.midX - w / 2, y: inner.midY - h / 2, width: w, height: h)
            ImageDisplayLoader.draw(image, in: rect)
        }
        if hovered, case .image = kind {
            borderColor.setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
    }
}
