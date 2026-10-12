import AppKit
import SwiftUI

@MainActor
final class InfillPaintCanvasView: NSView {
    var onMaskChanged: (() -> Void)?

    private static let brushMin = 4
    private static let brushMax = 256
    private static let brushDefault = 32
    private static let brushStep = 4
    private static let undoLimit = 50
    private static let viewMargin: CGFloat = 12
    private static let viewScaleMax = 8.0
    private static let zoomWheelFactor = 1.15

    private var sourcePath = ""
    private var maxSide = 1024
    private var sourceImage: CGImage?
    private var imageW = 1
    private var imageH = 1
    private var maskImage: CGImage?
    /// Top-left mask bitmap (same orientation as on-screen image).
    private var maskRep: NSBitmapImageRep?

    private var imageRect = CGRect.zero
    private var fitScale: CGFloat = 1
    private var viewScale: CGFloat = 1
    private var panX: CGFloat = 0
    private var panY: CGFloat = 0
    private var displayScale: CGFloat = 1

    private var brushRadius = brushDefault
    private var painting = false
    private var hasPaint = false
    private var undoStack: [CGImage] = []
    private var redoStack: [CGImage] = []
    private var cursorPos = CGPoint.zero
    private var cursorVisible = false
    private var magnifyAnchor: CGPoint?

    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        clearButton.bezelStyle = .roundRect
        clearButton.isBordered = true
        clearButton.target = self
        clearButton.action = #selector(clearMaskAction)
        clearButton.isHidden = true
        addSubview(clearButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(sourcePath: String, maxSide: Int) {
        let newMax = max(256, maxSide)
        if sourcePath != self.sourcePath || newMax != self.maxSide {
            self.sourcePath = sourcePath
            self.maxSide = newMax
            reloadSource()
        }
    }

    func setBrushRadius(_ radius: Int) {
        brushRadius = max(Self.brushMin, min(Self.brushMax, radius))
        needsDisplay = true
    }

    func adjustBrushRadius(delta: Int) {
        setBrushRadius(brushRadius + delta)
    }

    func hasPaintMask() -> Bool { hasPaint }

    func maskCGImage() -> CGImage? { maskImage }

    func loadMask(_ image: CGImage) -> Bool {
        guard installMaskPixels(from: image) else { return false }
        syncHasPaint()
        undoStack.removeAll()
        redoStack.removeAll()
        updateClearButton()
        needsDisplay = true
        onMaskChanged?()
        return true
    }

    private func installMaskPixels(from image: CGImage) -> Bool {
        guard image.width == imageW, image.height == imageH else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: imageW, height: imageH)
        maskRep = rep
        syncMaskImageFromRep()
        return true
    }

    func loadMaskPNGData(_ data: Data) -> Bool {
        guard let rep = NSBitmapImageRep(data: data),
              let cg = rep.cgImage else { return false }
        return loadMask(cg)
    }

    func maskPNGData() -> Data? {
        guard let maskImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: maskImage)
        return rep.representation(using: .png, properties: [:])
    }

    @objc private func clearMaskAction() {
        clearMask()
    }

    func clearMask() {
        guard hasPaint else { return }
        pushUndo()
        resetMaskPixels()
        hasPaint = false
        redoStack.removeAll()
        updateClearButton()
        needsDisplay = true
        onMaskChanged?()
    }

    func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        if let current = snapshotMaskImage() { redoStack.append(current) }
        guard installMaskPixels(from: previous) else { return false }
        syncHasPaint()
        updateClearButton()
        needsDisplay = true
        onMaskChanged?()
        return true
    }

    func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        if let current = snapshotMaskImage() { undoStack.append(current) }
        guard installMaskPixels(from: next) else { return false }
        syncHasPaint()
        updateClearButton()
        needsDisplay = true
        onMaskChanged?()
        return true
    }

    @objc func undo(_ sender: Any?) {
        _ = undo()
    }

    @objc func redo(_ sender: Any?) {
        _ = redo()
    }

    func reloadSourceFromDisk() {
        reloadSource()
    }

    private func reloadSource() {
        resetView()
        sourceImage = nil
        imageW = 1
        imageH = 1
        if !sourcePath.isEmpty,
           let loaded = ImageRecognitionImageLoader.loadCGImage(path: sourcePath) {
            let (w, h) = ImageGenInfillMath.fitInfillPaintDims(
                width: loaded.width,
                height: loaded.height,
                maxSide: maxSide
            )
            if loaded.width != w || loaded.height != h {
                sourceImage = ImageGenOutpaintMask.resizeImagePublic(loaded, width: w, height: h)
            } else {
                sourceImage = loaded
            }
            imageW = max(1, sourceImage?.width ?? 1)
            imageH = max(1, sourceImage?.height ?? 1)
        }
        resetMaskPixels()
        hasPaint = false
        undoStack.removeAll()
        redoStack.removeAll()
        updateClearButton()
        needsDisplay = true
        onMaskChanged?()
    }

    private func resetMaskPixels() {
        _ = ensureMaskRep(reset: true)
        clearMaskRep()
        syncMaskImageFromRep()
    }

    @discardableResult
    private func ensureMaskRep(reset: Bool) -> Bool {
        if reset || maskRep == nil || maskRep?.pixelsWide != imageW || maskRep?.pixelsHigh != imageH {
            guard imageW > 0, imageH > 0 else {
                maskRep = nil
                maskImage = nil
                return false
            }
            maskRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: imageW,
                pixelsHigh: imageH,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
            maskRep?.size = NSSize(width: imageW, height: imageH)
            clearMaskRep()
        }
        return maskRep != nil
    }

    /// NSBitmapImageRep uses bottom-left CG coords; flip so image Y matches the flipped view pointer.
    private func withTopLeftMaskCGContext(_ work: (CGContext) -> Void) {
        guard let rep = maskRep else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        nsCtx.imageInterpolation = .high
        NSGraphicsContext.current = nsCtx
        let cg = nsCtx.cgContext
        cg.saveGState()
        cg.translateBy(x: 0, y: CGFloat(imageH))
        cg.scaleBy(x: 1, y: -1)
        work(cg)
        cg.restoreGState()
    }

    private func clearMaskRep() {
        guard let rep = maskRep else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.current = nsCtx
        nsCtx.cgContext.clear(CGRect(x: 0, y: 0, width: imageW, height: imageH))
    }

    private func syncMaskImageFromRep() {
        maskImage = maskRep?.cgImage
    }

    private func resetView() {
        fitScale = 1
        viewScale = 1
        panX = 0
        panY = 0
    }

    private func currentDisplayScale() -> CGFloat {
        fitScale * viewScale
    }

    private func updateGeometry() {
        let availW = max(1, bounds.width - 2 * Self.viewMargin)
        let availH = max(1, bounds.height - 2 * Self.viewMargin)
        fitScale = min(availW / CGFloat(imageW), availH / CGFloat(imageH))
        viewScale = max(1, min(Self.viewScaleMax, viewScale))
        let scale = currentDisplayScale()
        let drawW = max(1, CGFloat(imageW) * scale)
        let drawH = max(1, CGFloat(imageH) * scale)
        let baseX = (bounds.width - drawW) / 2
        let baseY = (bounds.height - drawH) / 2
        clampPan(drawW: drawW, drawH: drawH, baseX: baseX, baseY: baseY)
        let offX = baseX + panX
        let offY = baseY + panY
        imageRect = CGRect(x: offX, y: offY, width: drawW, height: drawH)
        displayScale = drawW / CGFloat(imageW)
        positionClearButton()
    }

    private func clampPan(drawW: CGFloat, drawH: CGFloat, baseX: CGFloat, baseY: CGFloat) {
        let availW = max(1, bounds.width - 2 * Self.viewMargin)
        let availH = max(1, bounds.height - 2 * Self.viewMargin)
        if drawW <= availW { panX = 0 } else {
            let minOff = Self.viewMargin + availW - drawW
            let maxOff = Self.viewMargin
            panX = max(minOff - baseX, min(maxOff - baseX, panX))
        }
        if drawH <= availH { panY = 0 } else {
            let minOff = Self.viewMargin + availH - drawH
            let maxOff = Self.viewMargin
            panY = max(minOff - baseY, min(maxOff - baseY, panY))
        }
    }

    private func positionClearButton() {
        guard hasPaint, !imageRect.isEmpty else {
            clearButton.isHidden = true
            return
        }
        clearButton.sizeToFit()
        let inset: CGFloat = 6
        clearButton.frame.origin = CGPoint(
            x: imageRect.minX + inset,
            y: imageRect.maxY - clearButton.bounds.height - inset
        )
        clearButton.isHidden = false
    }

    private func imageBrushRadius() -> CGFloat {
        max(1, CGFloat(brushRadius) / max(1, viewScale))
    }

    private func displayBrushRadius() -> CGFloat {
        max(2, CGFloat(brushRadius) * fitScale)
    }

    /// Show brush ring after keyboard resize (Python unified dialog forwards `[` / `]` before first paint).
    func revealBrushCursorForKeyboardAdjust() {
        if !cursorVisible {
            cursorVisible = true
            cursorPos = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        needsDisplay = true
    }

    private func displayToImageCoords(_ pos: CGPoint) -> (CGFloat, CGFloat) {
        let relX = pos.x - imageRect.minX
        let relY = pos.y - imageRect.minY
        let scale = displayScale > 0 ? displayScale : 1
        return (relX / scale, relY / scale)
    }

    private func brushOverlapsImage(ix: CGFloat, iy: CGFloat) -> Bool {
        let r = imageBrushRadius()
        return !(ix + r < 0 || iy + r < 0 || ix - r >= CGFloat(imageW) || iy - r >= CGFloat(imageH))
    }

    private func pushUndo() {
        guard let snapshot = snapshotMaskImage() else { return }
        undoStack.append(snapshot)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func snapshotMaskImage() -> CGImage? {
        guard let maskImage else { return nil }
        let width = maskImage.width
        let height = maskImage.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(maskImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func syncHasPaint() {
        hasPaint = ImageGenInfillMask.maskHasPaint(maskImage)
    }

    private func updateClearButton() {
        positionClearButton()
    }

    private func stampBrush(ix: CGFloat, iy: CGFloat, erase: Bool) {
        guard brushOverlapsImage(ix: ix, iy: iy), ensureMaskRep(reset: false) else { return }
        let radius = imageBrushRadius()
        let rect = CGRect(
            x: ix - radius,
            y: iy - radius,
            width: radius * 2,
            height: radius * 2
        )
        withTopLeftMaskCGContext { cg in
            cg.setShouldAntialias(true)
            if erase {
                cg.setBlendMode(.clear)
                cg.setFillColor(CGColor(gray: 0, alpha: 0))
            } else {
                cg.setBlendMode(.normal)
                cg.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            }
            cg.fillEllipse(in: rect)
        }
        syncMaskImageFromRep()
        if erase {
            syncHasPaint()
        } else {
            hasPaint = true
        }
        updateClearButton()
    }

    private func drawSourceImage(in rect: NSRect) {
        guard let sourceImage else { return }
        let ns = NSImage(cgImage: sourceImage, size: NSSize(width: imageW, height: imageH))
        ns.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private func drawMaskOverlay(in rect: NSRect) {
        guard hasPaint, let maskImage, let tinted = Self.redTintedOverlay(from: maskImage) else { return }
        let ns = NSImage(cgImage: tinted, size: NSSize(width: imageW, height: imageH))
        ns.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 0.47,
            respectFlipped: true,
            hints: nil
        )
    }

    private static func redTintedOverlay(from mask: CGImage) -> CGImage? {
        let w = mask.width
        let h = mask.height
        guard let rgba = ImageGenInfillMask.ensureRGBA(mask) else { return nil }
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = rgba.dataProvider?.data as Data? else { return nil }
        guard let out = ctx.data else { return nil }
        let src = [UInt8](data)
        let dstBpr = ctx.bytesPerRow
        let dst = out.bindMemory(to: UInt8.self, capacity: dstBpr * h)
        let bpp = rgba.bitsPerPixel / 8
        let bpr = rgba.bytesPerRow
        for y in 0..<h {
            for x in 0..<w {
                let offset = y * bpr + x * bpp
                let alpha = bpp >= 4 ? src[offset + 3] : src[offset]
                let i = y * dstBpr + x * 4
                if alpha > 0 {
                    dst[i] = 255
                    dst[i + 1] = 60
                    dst[i + 2] = 60
                    dst[i + 3] = alpha
                } else {
                    dst[i] = 0
                    dst[i + 1] = 0
                    dst[i + 2] = 0
                    dst[i + 3] = 0
                }
            }
        }
        return ctx.makeImage()
    }

    override func draw(_ dirtyRect: NSRect) {
        updateGeometry()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor.windowBackgroundColor.setFill()
        ctx.fill(bounds)
        drawSourceImage(in: imageRect)
        drawMaskOverlay(in: imageRect)
        paintBrushCursor(ctx: ctx)
    }

    private func paintBrushCursor(ctx: CGContext) {
        guard cursorVisible else { return }
        let r = displayBrushRadius()
        let erase = optionEraseActive(for: nil)
        ctx.setShouldAntialias(true)
        ctx.setLineWidth(2)
        if erase {
            ctx.setStrokeColor(CGColor(red: 1, green: 140 / 255, blue: 40 / 255, alpha: 1))
        } else {
            ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        }
        ctx.strokeEllipse(in: CGRect(
            x: cursorPos.x - r,
            y: cursorPos.y - r,
            width: r * 2,
            height: r * 2
        ))
        ctx.setLineWidth(1)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.strokeEllipse(in: CGRect(
            x: cursorPos.x - r + 1,
            y: cursorPos.y - r + 1,
            width: max(0, r * 2 - 2),
            height: max(0, r * 2 - 2)
        ))
    }

    override func scrollWheel(with event: NSEvent) {
        if painting { super.scrollWheel(with: event); return }
        let zoomModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if zoomModifiers.contains(.control) || zoomModifiers.contains(.command) {
            let delta = event.scrollingDeltaY
            if delta != 0 {
                let factor = delta > 0 ? Self.zoomWheelFactor : (1 / Self.zoomWheelFactor)
                zoomAt(point: convert(event.locationInWindow, from: nil), factor: factor)
                return
            }
        }
        if canPanImage() {
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            if dx != 0 || dy != 0 {
                panX -= dx
                panY -= dy
                needsDisplay = true
            }
        }
    }

    override func magnify(with event: NSEvent) {
        if painting { return }
        if event.phase == .began {
            magnifyAnchor = convert(event.locationInWindow, from: nil)
        }
        let anchor = magnifyAnchor ?? convert(event.locationInWindow, from: nil)
        zoomAt(point: anchor, factor: 1.0 + event.magnification)
        if event.phase == .ended || event.phase == .cancelled {
            magnifyAnchor = nil
        }
    }

    private func canPanImage() -> Bool {
        currentDisplayScale() > fitScale + 0.001
    }

    private func optionEraseActive(for event: NSEvent?) -> Bool {
        let flags = event?.modifierFlags ?? NSEvent.modifierFlags
        return flags.intersection(.deviceIndependentFlagsMask).contains(.option)
    }

    private func zoomAt(point: CGPoint, factor: CGFloat) {
        updateGeometry()
        let old = currentDisplayScale()
        var newScale = old * factor
        let minScale = fitScale
        let maxScale = fitScale * Self.viewScaleMax
        newScale = max(minScale, min(maxScale, newScale))
        if abs(newScale - old) < 0.001 { return }
        viewScale = max(1, min(Self.viewScaleMax, newScale / fitScale))
        if imageRect.contains(point) {
            let (ix, iy) = displayToImageCoords(point)
            let drawW = CGFloat(imageW) * newScale
            let drawH = CGFloat(imageH) * newScale
            let baseX = (bounds.width - drawW) / 2
            let baseY = (bounds.height - drawH) / 2
            panX = point.x - ix * newScale - baseX
            panY = point.y - iy * newScale - baseY
        }
        updateGeometry()
        needsDisplay = true
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        updateGeometry()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        updateGeometry()
        window?.makeFirstResponder(self)
        let pos = convert(event.locationInWindow, from: nil)
        if !clearButton.isHidden, clearButton.frame.contains(pos) {
            super.mouseDown(with: event)
            return
        }
        let (ix, iy) = displayToImageCoords(pos)
        guard brushOverlapsImage(ix: ix, iy: iy) else { return }
        pushUndo()
        painting = true
        stampBrush(ix: ix, iy: iy, erase: optionEraseActive(for: event))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard painting else {
            mouseMoved(with: event)
            return
        }
        updateGeometry()
        let pos = convert(event.locationInWindow, from: nil)
        let (ix, iy) = displayToImageCoords(pos)
        stampBrush(ix: ix, iy: iy, erase: optionEraseActive(for: event))
        cursorPos = pos
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if painting {
            painting = false
            onMaskChanged?()
        }
        super.mouseUp(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        cursorPos = convert(event.locationInWindow, from: nil)
        cursorVisible = true
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        cursorVisible = true
        window?.makeFirstResponder(self)
    }

    override func mouseExited(with event: NSEvent) {
        cursorVisible = false
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 33 { // [
            adjustBrushRadius(delta: -Self.brushStep)
            return
        }
        if event.keyCode == 30 { // ]
            adjustBrushRadius(delta: Self.brushStep)
            return
        }
        if handleUndoRedoShortcut(event) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleUndoRedoShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private func handleUndoRedoShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "z" else {
            return false
        }
        return flags.contains(.shift) ? redo() : undo()
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 520, height: 360)
    }
}

@MainActor
struct InfillPaintCanvasRepresentable: NSViewRepresentable {
    let sourcePath: String
    let maxSide: Int
    var maskPNGData: Data?
    var onMaskChanged: ((Data?) -> Void)?
    var canvasRef: ((InfillPaintCanvasView) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> InfillPaintCanvasView {
        let view = InfillPaintCanvasView(frame: .zero)
        let coordinator = context.coordinator
        view.onMaskChanged = { [weak view, weak coordinator] in
            guard let view, let coordinator else { return }
            coordinator.canvasMaskDidChange(in: view)
        }
        context.coordinator.onMaskChanged = onMaskChanged
        context.coordinator.apply(to: view, sourcePath: sourcePath, maxSide: maxSide, maskPNGData: maskPNGData)
        canvasRef?(view)
        return view
    }

    func updateNSView(_ view: InfillPaintCanvasView, context: Context) {
        context.coordinator.onMaskChanged = onMaskChanged
        context.coordinator.apply(to: view, sourcePath: sourcePath, maxSide: maxSide, maskPNGData: maskPNGData)
        canvasRef?(view)
    }

    @MainActor
    final class Coordinator {
        var onMaskChanged: ((Data?) -> Void)?
        private var lastSource = ""
        private var lastMax = 0
        private var lastParentMaskData: Data?
        private var pendingLocalMaskData: Data?
        private var applyingParentMask = false

        func canvasMaskDidChange(in view: InfillPaintCanvasView) {
            let data = view.maskPNGData()
            guard !applyingParentMask else { return }
            pendingLocalMaskData = data
            onMaskChanged?(data)
        }

        func apply(to view: InfillPaintCanvasView, sourcePath: String, maxSide: Int, maskPNGData: Data?) {
            let sourceChanged = sourcePath != lastSource || maxSide != lastMax
            applyingParentMask = true
            view.configure(sourcePath: sourcePath, maxSide: maxSide)
            applyingParentMask = false
            lastSource = sourcePath
            lastMax = maxSide
            if sourceChanged {
                pendingLocalMaskData = nil
            }

            if !sourceChanged, let pendingLocalMaskData {
                if maskPNGData == pendingLocalMaskData {
                    lastParentMaskData = maskPNGData
                    self.pendingLocalMaskData = nil
                    return
                }
                if maskPNGData == lastParentMaskData {
                    return
                }
                self.pendingLocalMaskData = nil
            }

            guard sourceChanged || maskPNGData != lastParentMaskData else { return }
            lastParentMaskData = maskPNGData
            applyingParentMask = true
            if let maskPNGData {
                _ = view.loadMaskPNGData(maskPNGData)
            } else {
                applyingParentMask = true
                view.clearMask()
            }
            applyingParentMask = false
        }
    }
}
