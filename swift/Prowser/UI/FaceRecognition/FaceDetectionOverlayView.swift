import AppKit
import Foundation

/// Draws a face-detection preview with boxes aligned to encoded image pixels (EXIF-corrected).
final class FaceDetectionOverlayView: NSView {
    let cgImage: CGImage
    let detections: [FaceEngine.FaceDetection]
    var onPick: ((FaceEngine.FaceDetection) -> Void)?
    var retainedActionTargets: [NSObject] = []

    init(cgImage: CGImage, detections: [FaceEngine.FaceDetection]) {
        self.cgImage = cgImage
        self.detections = detections
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let layout = FaceImageOverlayLayout.compute(
            viewBounds: bounds,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height
        )
        if let ctx = NSGraphicsContext.current?.cgContext {
            FaceImageOverlayLayout.drawCGImageTopLeft(cgImage, in: layout.imageDrawRect, context: ctx)
        }
        NSColor.systemRed.setStroke()
        for det in detections {
            let rect = layout.faceBoxRect(
                top: det.location.top,
                right: det.location.right,
                bottom: det.location.bottom,
                left: det.location.left
            )
            NSBezierPath(rect: rect).lineWidth = 2
            NSBezierPath(rect: rect).stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let layout = FaceImageOverlayLayout.compute(
            viewBounds: bounds,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height
        )
        for det in detections.reversed() {
            if layout.containsFace(
                top: det.location.top,
                right: det.location.right,
                bottom: det.location.bottom,
                left: det.location.left,
                viewPoint: point
            ) {
                onPick?(det)
                return
            }
        }
    }
}
