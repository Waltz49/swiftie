import AppKit
import CoreImage
import Foundation

/// Browse view with zoom and pan. Port of `files/browse_view_handler.py` (phase 1).
final class BrowseImageNSView: NSView {
    weak var appState: AppState?
    var imagePath: String? {
        didSet { loadImage() }
    }

    var numberOverlayVisible = false {
        didSet { needsDisplay = true }
    }

    var overlayIndex = 0
    var overlayCount = 0
    var onActualSizeModeChanged: ((Bool) -> Void)?
    var onExitBrowse: (() -> Void)?

    private var sourceImage: NSImage? {
        didSet {
            cachedCIImage = nil
            cachedCIImageIdentity = nil
        }
    }
    private var cachedCIImage: CIImage?
    private var cachedCIImageIdentity: ObjectIdentifier?
    private var scaleFactor: CGFloat = 1.0
    private var scrollOffset = CGPoint.zero
    private var isActualSize = false
    private var preferredActualSize = false
    private var dragStart: CGPoint?
    private var scrollAtDragStart = CGPoint.zero
    /// Pinch zoom anchor (Python `zoom_center_point` at gesture start).
    private var magnifyAnchor: CGPoint?
    private var rotationDegrees: CGFloat = 0
    private var isFlippedHorizontally = false
    private var isFlippedVertically = false
    private var themeColors = ThemeColors.dark
    private var loadTask: Task<Void, Never>?
    private var emptyStateMessage = "No image selected"
    /// Manual zoom active (Python `browse_zoom_pinned`).
    private var zoomPinned = false
    /// Last anchor used for cursor/pinch zoom; reused when preserving view across images.
    private var lastZoomAnchorInView = CGPoint.zero

    private struct PreservedViewState {
        let targetPath: String
        let scaleFactor: CGFloat
        let anchor: CGPoint
        let nx: CGFloat
        let ny: CGFloat
    }

    private var pendingPreservedView: PreservedViewState?
    private var cursorHideTrackingArea: NSTrackingArea?
    private var isRefreshingCursorHideTracking = false

    override var isFlipped: Bool { true }

    func applyTheme(_ colors: ThemeColors) {
        themeColors = colors
        needsDisplay = true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        appState?.syncBrowseCursorAutoHide()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let rect = bounds
        if let cursorHideTrackingArea, cursorHideTrackingArea.rect == rect {
            return
        }
        isRefreshingCursorHideTracking = true
        if let cursorHideTrackingArea {
            removeTrackingArea(cursorHideTrackingArea)
        }
        let area = NSTrackingArea(
            rect: rect,
            options: [
                .mouseEnteredAndExited,
                .mouseMoved,
                .activeInKeyWindow,
                .inVisibleRect,
                .assumeInside,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorHideTrackingArea = area
        isRefreshingCursorHideTracking = false
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseEntered(with event: NSEvent) {
        appState?.browseCursorAutoHide.noteEnteredHideZone()
    }

    override func mouseExited(with event: NSEvent) {
        if isRefreshingCursorHideTracking { return }
        appState?.browseCursorAutoHide.noteExitedHideZone()
    }

    override func resetCursorRects() {
        discardCursorRects()
        if appState?.browseCursorAutoHide.pointerHiddenOnCanvas == true {
            addCursorRect(bounds, cursor: BrowseCursorAutoHideController.canvasBlankCursor)
        }
    }

    func resetView() {
        scaleFactor = 1.0
        scrollOffset = .zero
        isActualSize = false
        zoomPinned = false
        pendingPreservedView = nil
        resetTransforms()
        needsDisplay = true
    }

    func zoomIn() { applyZoom(factor: scaleFactor * 1.15, anchor: bounds.center) }
    func zoomOut() { applyZoom(factor: scaleFactor / 1.15, anchor: bounds.center) }

    func setActualSizeMode(_ enabled: Bool) {
        if preferredActualSize != enabled {
            onActualSizeModeChanged?(enabled)
        }
        applyDisplayMode(actualSize: enabled)
    }

    func applyDisplayMode(actualSize: Bool) {
        preferredActualSize = actualSize
        applyCurrentDisplayMode()
    }

    private var contentRevision = 0

    func setImage(path: String?, actualSize: Bool, contentRevision: Int = 0) {
        let pathChanged = imagePath != path
        let modeChanged = preferredActualSize != actualSize
        let contentChanged = self.contentRevision != contentRevision
        preferredActualSize = actualSize
        self.contentRevision = contentRevision
        if pathChanged {
            capturePreserveSnapshot(forNewPath: path)
            imagePath = path
        } else if contentChanged {
            loadImage()
        } else if modeChanged {
            applyCurrentDisplayMode()
        }
    }

    private func applyCurrentDisplayMode() {
        guard sourceImage != nil else { return }
        isActualSize = preferredActualSize
        if preferredActualSize {
            zoomPinned = false
            scaleFactor = 1.0
            scrollOffset = .zero
        } else {
            fitToWindow()
        }
        needsDisplay = true
    }

    private func finishImageLoad() {
        guard sourceImage != nil else { return }
        if let pending = pendingPreservedView, pending.targetPath == imagePath {
            pendingPreservedView = nil
            preferredActualSize = false
            isActualSize = false
            applyScaleAndScroll(
                scale: pending.scaleFactor,
                anchor: pending.anchor,
                nx: pending.nx,
                ny: pending.ny,
                image: sourceImage!
            )
            zoomPinned = true
            clampScroll()
        } else {
            pendingPreservedView = nil
            applyCurrentDisplayMode()
        }
        needsDisplay = true
        appState?.browseCursorAutoHide.reassertAfterCanvasContentChange()
    }

    private func capturePreserveSnapshot(forNewPath path: String?) {
        guard let path,
              appState?.config.bool(forKey: "browse_preserve_zoom_on_image_change", default: false) == true,
              zoomPinned,
              let image = sourceImage else {
            pendingPreservedView = nil
            return
        }
        let draw = imageDrawRect(for: image)
        guard draw.width > 0, draw.height > 0 else {
            pendingPreservedView = nil
            return
        }
        let anchor = preserveAnchorForNavigation()
        let (nx, ny) = normalizedImagePoint(in: draw, anchor: anchor)
        pendingPreservedView = PreservedViewState(
            targetPath: path,
            scaleFactor: scaleFactor,
            anchor: anchor,
            nx: nx,
            ny: ny
        )
    }

    private func preserveAnchorForNavigation() -> CGPoint {
        if bounds.contains(lastZoomAnchorInView) {
            return lastZoomAnchorInView
        }
        return bounds.center
    }

    func rotateClockwise() {
        rotationDegrees = (rotationDegrees + 90).truncatingRemainder(dividingBy: 360)
        needsDisplay = true
    }

    func rotateCounterclockwise() {
        rotationDegrees = (rotationDegrees - 90).truncatingRemainder(dividingBy: 360)
        needsDisplay = true
    }

    func flipHorizontal() {
        isFlippedHorizontally.toggle()
        needsDisplay = true
    }

    func flipVertical() {
        isFlippedVertically.toggle()
        needsDisplay = true
    }

    func resetTransforms() {
        rotationDegrees = 0
        isFlippedHorizontally = false
        isFlippedVertically = false
        needsDisplay = true
    }

    func panBy(dx: CGFloat, dy: CGFloat) {
        guard canPan() else { return }
        scrollOffset.x += dx
        scrollOffset.y += dy
        clampScroll()
        needsDisplay = true
    }

    /// Fit image width to the browse canvas and scroll to the top (Python ^W).
    func fitToCanvasWidth() {
        guard let image = sourceImage else { return }
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0 else { return }
        preferredActualSize = false
        isActualSize = false
        onActualSizeModeChanged?(false)
        scaleFactor = bounds.width / imageSize.width
        scrollOffset = CGPoint(x: 0, y: 0)
        zoomPinned = true
        needsDisplay = true
    }

    /// Fit image height to the browse viewport (Swift-only ⌥=).
    func fitToCanvasHeight() {
        guard let image = sourceImage else { return }
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0, bounds.height > 0 else { return }
        preferredActualSize = false
        isActualSize = false
        onActualSizeModeChanged?(false)
        scaleFactor = bounds.height / imageSize.height
        scrollOffset = CGPoint(x: 0, y: 0)
        zoomPinned = true
        needsDisplay = true
    }

    private func loadImage() {
        loadTask?.cancel()
        resetTransforms()
        guard let imagePath else {
            sourceImage = nil
            pendingPreservedView = nil
            needsDisplay = true
            return
        }
        let ignoreExif = appState?.config.ignoreExifRotation ?? false
        if let image = BrowseImageLoader.loadImage(from: imagePath, ignoreExifRotation: ignoreExif) {
            emptyStateMessage = "No image selected"
            sourceImage = image
            finishImageLoad()
            return
        }
        loadImageFromCacheOrAsync(path: imagePath)
    }

    private func loadImageFromCacheOrAsync(path: String) {
        guard let appState else {
            sourceImage = nil
            needsDisplay = true
            return
        }
        if let preview = appState.previewPaneCache.cachedImage(for: path) {
            sourceImage = preview
            finishImageLoad()
            return
        }

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            for size in [8192, 4096, 2048, 1024, 512] {
                if Task.isCancelled { return }
                if let cg = await appState.thumbnailCache.cachedThumbnail(for: normalized, size: size) {
                    guard self.imagePath == path else { return }
                    self.sourceImage = NSImage(
                        cgImage: cg,
                        size: NSSize(width: cg.width, height: cg.height)
                    )
                    self.finishImageLoad()
                    return
                }
            }
            if let cg = await appState.thumbnailCache.generateThumbnail(for: normalized, size: 8192) {
                guard !Task.isCancelled, self.imagePath == path else { return }
                self.sourceImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                self.finishImageLoad()
                return
            }
            guard !Task.isCancelled, self.imagePath == path else { return }
            self.pendingPreservedView = nil
            self.applyEmptyBrowseState(for: path)
        }
    }

    private func applyEmptyBrowseState(for path: String) {
        if PhotosLibraryBrowseLoader.isAccessBlocked(for: path) {
            emptyStateMessage = PhotosLibraryBrowseLoader.blockedUserMessage()
            appState?.status.show(
                "Photos access required — enable Prowser in System Settings → Privacy & Security → Photos"
            )
        } else {
            emptyStateMessage = "No image selected"
        }
        sourceImage = nil
        needsDisplay = true
    }

    private func fitToWindow() {
        guard let image = sourceImage else { return }
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        let fit = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        scaleFactor = fit
        scrollOffset = .zero
        isActualSize = false
        zoomPinned = false
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = bounds.size
        super.setFrameSize(newSize)
        if zoomPinned, sourceImage != nil {
            scrollOffset.x -= (newSize.width - oldSize.width) / 2
            scrollOffset.y -= (newSize.height - oldSize.height) / 2
            clampScroll()
        } else if !isActualSize, sourceImage != nil {
            fitToWindow()
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(themeColors.browseBorderColor).setFill()
        dirtyRect.fill()

        guard let image = sourceImage else {
            drawEmptyState()
            return
        }

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let drawRect = imageDrawRect(for: image)

        if themeColors.browseUseCheckerboard {
            drawCheckerboard(in: drawRect)
        } else {
            NSColor(themeColors.browseTransparencyColor).setFill()
            drawRect.fill()
        }

        context.saveGState()
        context.translateBy(x: drawRect.midX, y: drawRect.midY)
        if isFlippedHorizontally { context.scaleBy(x: -1, y: 1) }
        if isFlippedVertically { context.scaleBy(x: 1, y: -1) }
        if rotationDegrees != 0 {
            context.rotate(by: rotationDegrees * .pi / 180)
        }
        let centered = NSRect(
            x: -drawRect.width / 2,
            y: -drawRect.height / 2,
            width: drawRect.width,
            height: drawRect.height
        )
        let zoomSharpen = appState?.config.bool(forKey: "browse_zoom_sharpen", default: false) == true
        let drewSharpened = zoomSharpen && scaleFactor > 1.0
            && drawSharpenedZoomedImage(image, in: centered, context: context)
        if !drewSharpened {
            image.draw(in: centered, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        }
        context.restoreGState()

        if numberOverlayVisible {
            drawNumberOverlay(in: bounds)
        }

        if shouldDrawBrowseLockOverlay() {
            PadlockOverlayRenderer.draw(in: bounds, style: .browse)
        }
    }

    private func shouldDrawBrowseLockOverlay() -> Bool {
        guard let appState,
              appState.config.bool(forKey: "allow_thumbnail_locking", default: false),
              appState.fileData.currentViewMode == .browse,
              let path = imagePath else { return false }
        return PrsortIO.isFileLocked(path)
    }

    private static let browseOverlayBaseFontSize: CGFloat = 196
    private static let browseOverlayMargin: CGFloat = 20
    private static let browseOverlayShadowOffset: CGFloat = 6

    /// Port of `image_browser_window._extract_imagegen_digits`.
    private static func extractImagegenDigits(from path: String) -> String? {
        let basename = (path as NSString).lastPathComponent
        guard let regex = try? NSRegularExpression(
            pattern: #"^imagegen-(\d{4})\.(webp|png|jpg|jpeg)$"#,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(basename.startIndex..., in: basename)
        guard let match = regex.firstMatch(in: basename, range: range),
              match.numberOfRanges > 1,
              let digitRange = Range(match.range(at: 1), in: basename) else {
            return nil
        }
        return String(basename[digitRange])
    }

    private func browseOverlayMainLine(for path: String) -> (text: String, fontSize: CGFloat) {
        if let digits = Self.extractImagegenDigits(from: path) {
            return (digits, Self.browseOverlayBaseFontSize)
        }
        let basename = (path as NSString).lastPathComponent
        let fontSize = max(1, floor(Self.browseOverlayBaseFontSize * 0.25))
        return (basename, fontSize)
    }

    private func browseOverlaySizeText() -> String? {
        guard let image = sourceImage else { return nil }
        let pixels: NSSize
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            pixels = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        } else {
            pixels = image.size
        }
        let width = Int(pixels.width.rounded())
        let height = Int(pixels.height.rounded())
        guard width > 0, height > 0 else { return nil }
        return "\(width) x \(height)"
    }

    private func impactFont(size: CGFloat) -> NSFont {
        NSFont(name: "Impact", size: size) ?? NSFont.boldSystemFont(ofSize: size)
    }

    /// Python `update_number_overlay`: Impact, white text + black shadow, name/size at different point sizes.
    private func drawNumberOverlay(in rect: NSRect) {
        guard let path = imagePath else { return }
        let (mainText, mainFontSize) = browseOverlayMainLine(for: path)
        guard !mainText.isEmpty else { return }

        let mainFont = impactFont(size: mainFontSize)
        let contentWidth = max(1, rect.width - Self.browseOverlayMargin * 2)
        var topY = Self.browseOverlayMargin

        let mainHeight = drawBrowseOverlayLine(
            mainText,
            font: mainFont,
            topY: topY,
            contentWidth: contentWidth,
            in: rect
        )
        // Below main line (Python QLabel stack; Qt `size_y = y + main_text_height - 20` overlaps in practice).
        topY += mainHeight + Self.browseOverlaySizeGap

        if let sizeText = browseOverlaySizeText() {
            // Size line scales from the 196pt base so basename mode is not stuck at 12pt.
            let sizeFontSize = max(20, floor(Self.browseOverlayBaseFontSize * 0.25))
            let sizeFont = impactFont(size: sizeFontSize)
            drawBrowseOverlayLine(
                sizeText,
                font: sizeFont,
                topY: topY,
                contentWidth: contentWidth,
                in: rect
            )
        }
    }

    private static let browseOverlaySizeGap: CGFloat = 10

    @discardableResult
    private func drawBrowseOverlayLine(
        _ text: String,
        font: NSFont,
        topY: CGFloat,
        contentWidth: CGFloat,
        in rect: NSRect
    ) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right

        let whiteAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let blackAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]

        let lineHeight = overlayLineHeight(text: text, font: font, width: contentWidth)
        let lineRect = NSRect(
            x: rect.maxX - contentWidth - Self.browseOverlayMargin,
            y: topY,
            width: contentWidth,
            height: lineHeight
        )
        let shadowRect = lineRect.offsetBy(
            dx: -Self.browseOverlayShadowOffset,
            dy: Self.browseOverlayShadowOffset
        )
        (text as NSString).draw(with: shadowRect, options: [.usesLineFragmentOrigin], attributes: blackAttrs)
        (text as NSString).draw(with: lineRect, options: [.usesLineFragmentOrigin], attributes: whiteAttrs)
        return lineHeight
    }

    /// Layout height for a single overlay line (matches Qt `QFontMetrics.boundingRect` more closely than NSString boundingRect).
    private func overlayLineHeight(text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    override func scrollWheel(with event: NSEvent) {
        appState?.browseCursorAutoHide.noteMouseActivity()
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            let delta = event.deltaY
            let factor = delta > 0 ? scaleFactor * 1.1 : scaleFactor / 1.1
            applyZoom(factor: factor, anchor: zoomAnchorPoint(for: event))
            return
        }
        if canPan() {
            scrollOffset.x -= event.deltaX
            scrollOffset.y -= event.deltaY
            clampScroll()
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        appState?.browseCursorAutoHide.noteMouseActivity()
        if event.phase == .began {
            magnifyAnchor = zoomAnchorPoint(for: event)
        }
        let anchor = magnifyAnchor ?? zoomAnchorPoint(for: event)
        applyZoom(factor: scaleFactor * (1.0 + event.magnification), anchor: anchor)
        if event.phase == .ended || event.phase == .cancelled {
            magnifyAnchor = nil
        }
    }

    override func mouseDown(with event: NSEvent) {
        appState?.browseCursorAutoHide.noteMouseActivity()
        guard sourceImage != nil else { return }
        dragStart = convert(event.locationInWindow, from: nil)
        scrollAtDragStart = scrollOffset
    }

    override func rightMouseDown(with event: NSEvent) {
        onExitBrowse?()
    }

    override func mouseDragged(with event: NSEvent) {
        appState?.browseCursorAutoHide.noteMouseActivity()
        guard let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard canPan() else { return }
        scrollOffset.x = scrollAtDragStart.x - (point.x - dragStart.x)
        scrollOffset.y = scrollAtDragStart.y - (point.y - dragStart.y)
        clampScroll()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, !event.modifierFlags.contains(.command), let appState {
            MainWindowKeyViewLoop.moveFromMainCanvas(appState: appState)
            return
        }
        super.keyDown(with: event)
    }

    private static let unsharpIntensity: NSNumber = 0.55

    private func unsharpRadius(forScale scale: CGFloat) -> NSNumber {
        NSNumber(value: Double(min(2.5, 0.9 + scale * 0.3)))
    }

    private func ciImage(for image: NSImage) -> CIImage? {
        if let cachedCIImage, cachedCIImageIdentity == ObjectIdentifier(image) {
            return cachedCIImage
        }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        let ciImage = CIImage(cgImage: cgImage)
        cachedCIImage = ciImage
        cachedCIImageIdentity = ObjectIdentifier(image)
        return ciImage
    }

    /// Scale the visible region first, then apply `CIUnsharpMask` so zoomed-in pixels stay crisp.
    private func drawSharpenedZoomedImage(_ image: NSImage, in centered: NSRect, context: CGContext) -> Bool {
        guard let ciImage = ciImage(for: image) else { return false }
        let srcExtent = ciImage.extent
        guard srcExtent.width > 1, srcExtent.height > 1, centered.width > 1, centered.height > 1 else {
            return false
        }

        let clip = context.boundingBoxOfClipPath.intersection(centered)
        guard clip.width > 1, clip.height > 1 else { return true }
        // Avoid allocating a full scaled bitmap if the clip box is unbounded.
        guard clip.width <= 8192, clip.height <= 8192 else { return false }

        let u0 = (clip.minX - centered.minX) / centered.width
        let v0 = (clip.minY - centered.minY) / centered.height
        let u1 = (clip.maxX - centered.minX) / centered.width
        let v1 = (clip.maxY - centered.minY) / centered.height
        let crop = CGRect(
            x: srcExtent.minX + u0 * srcExtent.width,
            y: srcExtent.minY + (1 - v1) * srcExtent.height,
            width: (u1 - u0) * srcExtent.width,
            height: (v1 - v0) * srcExtent.height
        )
        guard crop.width > 0, crop.height > 0 else { return true }

        let cropped = ciImage.cropped(to: crop)
        let croppedExtent = cropped.extent
        guard croppedExtent.width > 0, croppedExtent.height > 0 else { return true }

        let sx = clip.width / croppedExtent.width
        let sy = clip.height / croppedExtent.height
        var scaled = cropped.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        scaled = scaled.transformed(
            by: CGAffineTransform(translationX: -scaled.extent.origin.x, y: -scaled.extent.origin.y)
        )
        let sharpened = scaled.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: unsharpRadius(forScale: scaleFactor),
            kCIInputIntensityKey: Self.unsharpIntensity,
        ])

        context.saveGState()
        context.translateBy(x: clip.minX, y: clip.maxY)
        context.scaleBy(x: 1, y: -1)
        let ciContext = CIContext(cgContext: context, options: [.cacheIntermediates: false])
        ciContext.draw(sharpened, in: CGRect(origin: .zero, size: clip.size), from: sharpened.extent)
        context.restoreGState()
        return true
    }

    private func imageDrawRect(for image: NSImage) -> NSRect {
        let imageSize = image.size
        let width = imageSize.width * scaleFactor
        let height = imageSize.height * scaleFactor
        let x = (bounds.width - width) / 2 - scrollOffset.x
        let y = (bounds.height - height) / 2 - scrollOffset.y
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// View coordinates of the point that should stay fixed while zooming (cursor / pinch center).
    private func zoomAnchorPoint(for event: NSEvent) -> CGPoint {
        if let window {
            return convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }
        return convert(event.locationInWindow, from: nil)
    }

    private func normalizedImagePoint(in drawRect: NSRect, anchor: CGPoint) -> (CGFloat, CGFloat) {
        let nx = min(max((anchor.x - drawRect.minX) / drawRect.width, 0), 1)
        let ny = min(max((anchor.y - drawRect.minY) / drawRect.height, 0), 1)
        return (nx, ny)
    }

    private func applyScaleAndScroll(
        scale: CGFloat,
        anchor: CGPoint,
        nx: CGFloat,
        ny: CGFloat,
        image: NSImage
    ) {
        scaleFactor = min(max(scale, 0.05), 20.0)
        let imageSize = image.size
        let afterW = imageSize.width * scaleFactor
        let afterH = imageSize.height * scaleFactor
        scrollOffset.x = (bounds.width - afterW) / 2 - (anchor.x - nx * afterW)
        scrollOffset.y = (bounds.height - afterH) / 2 - (anchor.y - ny * afterH)
    }

    private func applyZoom(factor: CGFloat, anchor: CGPoint) {
        guard let image = sourceImage else { return }
        let before = imageDrawRect(for: image)
        guard before.width > 0, before.height > 0 else { return }

        let (nx, ny) = normalizedImagePoint(in: before, anchor: anchor)
        if preferredActualSize {
            preferredActualSize = false
            isActualSize = false
            onActualSizeModeChanged?(false)
        }

        applyScaleAndScroll(scale: factor, anchor: anchor, nx: nx, ny: ny, image: image)
        lastZoomAnchorInView = anchor
        zoomPinned = true
        clampScroll()
        needsDisplay = true
    }

    private func canPan() -> Bool {
        guard let image = sourceImage else { return false }
        let draw = imageDrawRect(for: image)
        return draw.width > bounds.width + 1 || draw.height > bounds.height + 1
    }

    private func clampScroll() {
        guard let image = sourceImage else { return }
        let draw = imageDrawRect(for: image)
        let overflowX = max(0, draw.width - bounds.width)
        let overflowY = max(0, draw.height - bounds.height)
        scrollOffset.x = min(max(scrollOffset.x, -overflowX / 2), overflowX / 2)
        scrollOffset.y = min(max(scrollOffset.y, -overflowY / 2), overflowY / 2)
    }

    private func drawCheckerboard(in rect: NSRect) {
        guard rect.width > 0, rect.height > 0 else { return }

        let tile: CGFloat = 8
        // Match Python `_draw_diamond_pattern`: 128 base, 96 on alternating cells.
        let base = NSColor(calibratedRed: 128.0 / 255.0, green: 128.0 / 255.0, blue: 128.0 / 255.0, alpha: 1)
        let alternate = NSColor(calibratedRed: 96.0 / 255.0, green: 96.0 / 255.0, blue: 96.0 / 255.0, alpha: 1)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        base.setFill()
        rect.fill()

        let startCol = Int(floor(rect.minX / tile))
        let startRow = Int(floor(rect.minY / tile))
        var row = startRow
        var y = CGFloat(startRow) * tile
        while y < rect.maxY {
            var col = startCol
            var x = CGFloat(startCol) * tile
            while x < rect.maxX {
                guard (row + col) % 2 == 0 else {
                    x += tile
                    col += 1
                    continue
                }
                let color = alternate
                color.setFill()
                NSRect(x: x, y: y, width: tile, height: tile).fill()
                x += tile
                col += 1
            }
            y += tile
            row += 1
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawEmptyState() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: themeColors.thumbnailText.nsColor,
            .paragraphStyle: paragraph,
        ]
        let rect = bounds.insetBy(dx: 28, dy: 28)
        (emptyStateMessage as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin],
            attributes: attrs
        )
    }
}

private extension NSRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
