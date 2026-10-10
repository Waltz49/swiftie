import AppKit
import SwiftUI

@MainActor
final class ExpandPlacementCanvasView: NSView {
    var onPlacementChanged: (() -> Void)?

    private var sourcePath: String = ""
    private var sourceImage: CGImage?
    private var canvasW = 1024
    private var canvasH = 1024
    private var placementX = 0
    private var placementY = 0
    private var placementW = ExpandPlacementMath.minPlacementEdge
    private var placementH = ExpandPlacementMath.minPlacementEdge
    private var relativePlacement: ExpandPlacementMath.RelativePlacement?

    private var canvasRect = CGRect.zero
    private var displayScale: CGFloat = 1

    private var dragMode: String?
    private var pressLocation = CGPoint.zero
    private var pressPlacement = (0, 0, 0, 0)

    private let handleSize: CGFloat = 14
    private let handleHitPad: CGFloat = 8
    private let targetBorderWidth: CGFloat = 4
    private let margin: CGFloat = 20

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    func configure(sourcePath: String, canvasW: Int, canvasH: Int) {
        let newW = max(ExpandPlacementMath.minPlacementEdge, canvasW)
        let newH = max(ExpandPlacementMath.minPlacementEdge, canvasH)
        if sourcePath != self.sourcePath {
            self.sourcePath = sourcePath
            reloadSourceImage()
            resetInitialPlacement(emit: false)
        }
        if newW != self.canvasW || newH != self.canvasH {
            relativePlacement = ExpandPlacementMath.storeRelative(
                placementX: placementX,
                placementY: placementY,
                placementW: placementW,
                placementH: placementH,
                canvasW: self.canvasW,
                canvasH: self.canvasH
            )
            self.canvasW = newW
            self.canvasH = newH
            applyRelativePlacement()
            onPlacementChanged?()
        }
        needsDisplay = true
    }

    func setCanvasPlacement(px: Int, py: Int, pw: Int, ph: Int, emit: Bool = false) {
        let maxW = max(ExpandPlacementMath.minPlacementEdge, canvasW)
        let maxH = max(ExpandPlacementMath.minPlacementEdge, canvasH)
        let pwI = max(ExpandPlacementMath.minPlacementEdge, min(pw, maxW))
        let phI = max(ExpandPlacementMath.minPlacementEdge, min(ph, maxH))
        let pxI = max(0, min(px, canvasW - pwI))
        let pyI = max(0, min(py, canvasH - phI))
        placementX = pxI
        placementY = pyI
        placementW = pwI
        placementH = phI
        clampPlacementPosition()
        storeRelative()
        needsDisplay = true
        if emit { onPlacementChanged?() }
    }

    func canvasPlacement() -> (Int, Int, Int, Int) {
        (placementX, placementY, placementW, placementH)
    }

    private func reloadSourceImage() {
        if sourcePath.isEmpty {
            sourceImage = nil
            return
        }
        sourceImage = ImageGenOutpaintMask.loadCGImage(path: sourcePath)
    }

    private func sourceAspect() -> Double {
        guard let sourceImage else { return 1 }
        let h = sourceImage.height
        guard h > 0 else { return 1 }
        return Double(sourceImage.width) / Double(h)
    }

    private func resetInitialPlacement(emit: Bool) {
        applyDefaultCenteredFit(emit: emit)
    }

    private func applyDefaultCenteredFit(emit: Bool) {
        let fit = ExpandPlacementMath.centeredFit(
            canvasW: canvasW,
            canvasH: canvasH,
            sourceAspect: sourceAspect()
        )
        placementX = fit.x
        placementY = fit.y
        placementW = fit.w
        placementH = fit.h
        clampPlacementPosition()
        storeRelative()
        needsDisplay = true
        if emit { onPlacementChanged?() }
    }

    private func storeRelative() {
        relativePlacement = ExpandPlacementMath.storeRelative(
            placementX: placementX,
            placementY: placementY,
            placementW: placementW,
            placementH: placementH,
            canvasW: canvasW,
            canvasH: canvasH
        )
    }

    private func applyRelativePlacement() {
        guard let rel = relativePlacement else {
            resetInitialPlacement(emit: false)
            return
        }
        let applied = ExpandPlacementMath.applyRelative(rel, canvasW: canvasW, canvasH: canvasH)
        placementX = applied.x
        placementY = applied.y
        placementW = applied.w
        placementH = applied.h
        clampPlacementPosition()
        storeRelative()
    }

    private func clampPlacementPosition() {
        let clamped = ExpandPlacementMath.clampPosition(
            x: placementX,
            y: placementY,
            w: placementW,
            h: placementH,
            canvasW: canvasW,
            canvasH: canvasH
        )
        placementX = clamped.0
        placementY = clamped.1
    }

    private func updateCanvasGeometry() {
        let border = targetBorderWidth
        let availW = max(1, bounds.width - 2 * margin - 2 * border)
        let availH = max(1, bounds.height - 2 * margin - 2 * border)
        let scale = min(availW / CGFloat(canvasW), availH / CGFloat(canvasH))
        let drawW = max(1, CGFloat(canvasW) * scale)
        let drawH = max(1, CGFloat(canvasH) * scale)
        let frameW = drawW + 2 * border
        let offX = (bounds.width - frameW) / 2 + border
        let offY = (bounds.height - (drawH + 2 * border)) / 2 + border
        canvasRect = CGRect(x: offX, y: offY, width: drawW, height: drawH)
        displayScale = scale
    }

    private func canvasToDisplay(cx: Int, cy: Int, cw: Int, ch: Int) -> CGRect {
        CGRect(
            x: canvasRect.minX + CGFloat(cx) * displayScale,
            y: canvasRect.minY + CGFloat(cy) * displayScale,
            width: max(1, CGFloat(cw) * displayScale),
            height: max(1, CGFloat(ch) * displayScale)
        )
    }

    private func displayToCanvasDelta(dx: CGFloat, dy: CGFloat) -> (Int, Int) {
        guard displayScale > 0 else { return (0, 0) }
        return (Int(round(dx / displayScale)), Int(round(dy / displayScale)))
    }

    private func placementDisplayRect() -> CGRect {
        canvasToDisplay(cx: placementX, cy: placementY, cw: placementW, ch: placementH).intersection(canvasRect)
    }

    private func handleDisplayRect() -> CGRect {
        let pr = placementDisplayRect()
        return CGRect(
            x: pr.maxX - handleSize + 1,
            y: pr.maxY - handleSize + 1,
            width: handleSize,
            height: handleSize
        )
    }

    private func handleHitRect() -> CGRect {
        handleDisplayRect().insetBy(dx: -handleHitPad, dy: -handleHitPad)
    }

    private func hitTest(at point: CGPoint) -> String? {
        guard canvasRect.contains(point) else { return nil }
        if handleHitRect().contains(point) { return "resize" }
        if placementDisplayRect().contains(point) { return "move" }
        return nil
    }

    private func endDrag() {
        if dragMode != nil {
            window?.invalidateCursorRects(for: self)
        }
        dragMode = nil
        NSCursor.arrow.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let pos = convert(event.locationInWindow, from: nil)
        updateCanvasGeometry()
        guard let mode = dragMode else {
            updateHoverCursor(at: pos)
            return
        }
        let dx = pos.x - pressLocation.x
        let dy = pos.y - pressLocation.y
        let (cdx, cdy) = displayToCanvasDelta(dx: dx, dy: dy)
        let (px, py, pw, ph) = pressPlacement
        if mode == "move" {
            placementX = px + cdx
            placementY = py + cdy
            clampPlacementPosition()
        } else {
            let freeAspect = event.modifierFlags.contains(.option)
            let resized = ExpandPlacementMath.applyResizeDrag(
                px: px,
                py: py,
                pw: pw,
                ph: ph,
                cdx: cdx,
                cdy: cdy,
                sourceAspect: sourceAspect(),
                canvasW: canvasW,
                canvasH: canvasH,
                freeAspect: freeAspect
            )
            placementX = px
            placementY = py
            placementW = resized.w
            placementH = resized.h
            clampPlacementPosition()
        }
        storeRelative()
        needsDisplay = true
        onPlacementChanged?()
    }

    override func mouseUp(with event: NSEvent) {
        endDrag()
    }

    override func mouseMoved(with event: NSEvent) {
        let pos = convert(event.locationInWindow, from: nil)
        updateCanvasGeometry()
        updateHoverCursor(at: pos)
    }

    private func updateHoverCursor(at pos: CGPoint) {
        guard dragMode == nil else { return }
        switch hitTest(at: pos) {
        case "resize":
            NSCursor.crosshair.set()
        case "move":
            NSCursor.openHand.set()
        default:
            NSCursor.arrow.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        window?.acceptsMouseMovedEvents = true
    }

    override func mouseExited(with event: NSEvent) {
        if dragMode == nil { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            updateCanvasGeometry()
            let pos = convert(event.locationInWindow, from: nil)
            if placementDisplayRect().contains(pos) {
                applyDefaultCenteredFit(emit: true)
                return
            }
        }
        updateCanvasGeometry()
        let pos = convert(event.locationInWindow, from: nil)
        guard let mode = hitTest(at: pos) else {
            super.mouseDown(with: event)
            return
        }
        dragMode = mode
        pressLocation = pos
        pressPlacement = canvasPlacement()
        if mode == "resize" {
            NSCursor.crosshair.set()
        } else {
            NSCursor.closedHand.set()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let options: NSTrackingArea.Options = [.mouseMoved, .activeInKeyWindow, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        updateCanvasGeometry()

        let workFill = NSColor(calibratedRed: 0.35, green: 0.35, blue: 0.35, alpha: 1)
        ctx.setFillColor(workFill.cgColor)
        ctx.fill(bounds)

        let canvasFill = NSColor(calibratedRed: 72 / 255, green: 72 / 255, blue: 72 / 255, alpha: 1)
        ctx.setFillColor(canvasFill.cgColor)
        ctx.fill(canvasRect)

        guard let sourceImage else {
            let text = "Image unavailable" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 13),
            ]
            let size = text.size(withAttributes: attrs)
            let point = CGPoint(
                x: canvasRect.midX - size.width / 2,
                y: canvasRect.midY - size.height / 2
            )
            text.draw(at: point, withAttributes: attrs)
            paintTargetBorder(ctx: ctx)
            return
        }

        let pr = placementDisplayRect()
        if !pr.isEmpty {
            ctx.saveGState()
            ctx.clip(to: canvasRect)
            let nsImage = NSImage(
                cgImage: sourceImage,
                size: NSSize(width: sourceImage.width, height: sourceImage.height)
            )
            nsImage.draw(
                in: pr,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
            ctx.restoreGState()

            ctx.setStrokeColor(NSColor(calibratedRed: 100 / 255, green: 180 / 255, blue: 1, alpha: 1).cgColor)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(pr.insetBy(dx: 0.5, dy: 0.5))

            let hr = handleDisplayRect()
            ctx.setFillColor(NSColor(calibratedRed: 80 / 255, green: 160 / 255, blue: 1, alpha: 1).cgColor)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.fill(hr)
            ctx.stroke(hr)
        }

        paintTargetBorder(ctx: ctx)
    }

    private func paintTargetBorder(ctx: CGContext) {
        let outer = canvasRect.insetBy(dx: -targetBorderWidth, dy: -targetBorderWidth)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(targetBorderWidth)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.stroke(outer)
        let inner = canvasRect.insetBy(dx: -0.5, dy: -0.5)
        ctx.setStrokeColor(NSColor(calibratedWhite: 30 / 255, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(inner)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 520, height: 360)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        needsDisplay = true
    }
}

@MainActor
struct ExpandPlacementCanvasRepresentable: NSViewRepresentable {
    let sourcePath: String
    let canvasWidth: Int
    let canvasHeight: Int
    var placement: (x: Int, y: Int, w: Int, h: Int)?
    var onPlacementChanged: ((Int, Int, Int, Int) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ExpandPlacementCanvasView {
        let view = ExpandPlacementCanvasView(frame: .zero)
        view.onPlacementChanged = { [weak view] in
            guard let view else { return }
            let p = view.canvasPlacement()
            context.coordinator.onPlacementChanged?(p.0, p.1, p.2, p.3)
        }
        context.coordinator.onPlacementChanged = onPlacementChanged
        context.coordinator.apply(
            to: view,
            sourcePath: sourcePath,
            canvasW: canvasWidth,
            canvasH: canvasHeight,
            placement: placement
        )
        return view
    }

    func updateNSView(_ view: ExpandPlacementCanvasView, context: Context) {
        context.coordinator.onPlacementChanged = onPlacementChanged
        context.coordinator.apply(
            to: view,
            sourcePath: sourcePath,
            canvasW: canvasWidth,
            canvasH: canvasHeight,
            placement: placement
        )
    }

    @MainActor
    final class Coordinator {
        var onPlacementChanged: ((Int, Int, Int, Int) -> Void)?
        private var lastSourcePath = ""
        private var lastCanvasW = 0
        private var lastCanvasH = 0
        private var appliedPlacementKey = ""

        func apply(
            to view: ExpandPlacementCanvasView,
            sourcePath: String,
            canvasW: Int,
            canvasH: Int,
            placement: (x: Int, y: Int, w: Int, h: Int)?
        ) {
            let sizeChanged = canvasW != lastCanvasW || canvasH != lastCanvasH
            let sourceChanged = sourcePath != lastSourcePath
            view.configure(sourcePath: sourcePath, canvasW: canvasW, canvasH: canvasH)
            lastSourcePath = sourcePath
            lastCanvasW = canvasW
            lastCanvasH = canvasH

            if let placement {
                let key = "\(placement.x),\(placement.y),\(placement.w),\(placement.h)"
                if key != appliedPlacementKey || sourceChanged {
                    view.setCanvasPlacement(
                        px: placement.x,
                        py: placement.y,
                        pw: placement.w,
                        ph: placement.h,
                        emit: false
                    )
                    appliedPlacementKey = key
                }
            } else if sourceChanged {
                appliedPlacementKey = ""
            }
            if sizeChanged, !sourceChanged {
                _ = view.canvasPlacement()
            }
        }
    }
}
