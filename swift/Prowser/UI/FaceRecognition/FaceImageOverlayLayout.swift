import AppKit
import CoreGraphics
import Foundation

/// Maps dlib face boxes (top-left image origin) into a flipped overlay view.
struct FaceImageOverlayLayout: Sendable {
    let pixelWidth: CGFloat
    let pixelHeight: CGFloat
    let scale: CGFloat
    let imageDrawRect: CGRect

    static let contentInset: CGFloat = 10

    static func compute(viewBounds: CGRect, pixelWidth: Int, pixelHeight: Int) -> FaceImageOverlayLayout {
        let pw = CGFloat(max(1, pixelWidth))
        let ph = CGFloat(max(1, pixelHeight))
        let target = viewBounds.insetBy(dx: contentInset, dy: contentInset)
        let fit = min(target.width / pw, target.height / ph)
        let drawW = pw * fit
        let drawH = ph * fit
        let ox = target.minX + (target.width - drawW) / 2
        let oy = target.minY + (target.height - drawH) / 2
        return FaceImageOverlayLayout(
            pixelWidth: pw,
            pixelHeight: ph,
            scale: fit,
            imageDrawRect: CGRect(x: ox, y: oy, width: drawW, height: drawH)
        )
    }

    func faceBoxRect(top: Int, right: Int, bottom: Int, left: Int) -> CGRect {
        CGRect(
            x: imageDrawRect.minX + CGFloat(left) * scale,
            y: imageDrawRect.minY + CGFloat(top) * scale,
            width: max(1, CGFloat(right - left) * scale),
            height: max(1, CGFloat(bottom - top) * scale)
        )
    }

    func imageCoordinates(forViewPoint point: CGPoint) -> (x: CGFloat, y: CGFloat)? {
        guard imageDrawRect.contains(point) else { return nil }
        let ix = (point.x - imageDrawRect.minX) / scale
        let iy = (point.y - imageDrawRect.minY) / scale
        return (ix, iy)
    }

    func containsFace(top: Int, right: Int, bottom: Int, left: Int, viewPoint: CGPoint) -> Bool {
        guard let (ix, iy) = imageCoordinates(forViewPoint: viewPoint) else { return false }
        return ix >= CGFloat(left) && ix <= CGFloat(right) && iy >= CGFloat(top) && iy <= CGFloat(bottom)
    }

    /// Draw into a flipped AppKit view (`isFlipped == true`); Quartz bitmaps use a bottom-left origin.
    static func drawCGImageTopLeft(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        context.restoreGState()
    }
}

enum FaceAssignPlaceholder {
    static let add = "Add..."
}
