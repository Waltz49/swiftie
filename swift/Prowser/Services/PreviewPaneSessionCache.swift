import AppKit
import Foundation

/// Preview geometry, port of `preview_widget.py`.
enum PreviewPaneLayout {
    /// Port of `_update_image_display` fit mode: fit inside the viewport (10px margin), never upscale.
    static func fitDisplaySize(imageSize: NSSize, viewportSize: CGSize) -> CGSize {
        let availableWidth = max(viewportSize.width - 10, 1)
        let availableHeight = max(viewportSize.height - 10, 1)
        let scaleX = availableWidth / max(imageSize.width, 1)
        let scaleY = availableHeight / max(imageSize.height, 1)
        let scale = min(scaleX, scaleY, 1)
        return CGSize(
            width: max(imageSize.width * scale, 1),
            height: max(imageSize.height * scale, 1)
        )
    }

    /// Port of `preferred_content_height`: height to show the image at fit-to-width (title double-click).
    /// With no image loaded, Python returns the "No image selected" label height + 4.
    static func preferredContentHeight(imageSize: NSSize?, clientWidth: CGFloat) -> CGFloat {
        guard let imageSize, imageSize.width > 0 else { return SidebarPaneLayout.minPaneContent + 4 }
        let scale = min(max(clientWidth, 1) / imageSize.width, 1)
        return floor(imageSize.height * scale) + 10
    }
}

/// Holds the loaded preview image across pane hide/show (Python keeps `current_pixmap` on the
/// long-lived `PreviewWidget`; SwiftUI recreates `PreviewPaneView` state when the pane is hidden).
@MainActor
final class PreviewPaneSessionCache {
    private var imagePath: String?
    private var image: NSImage?

    func cachedImage(for path: String) -> NSImage? {
        guard let imagePath else { return nil }
        let requested = URL(fileURLWithPath: path).standardizedFileURL.path
        let stored = URL(fileURLWithPath: imagePath).standardizedFileURL.path
        guard requested == stored else { return nil }
        return image
    }

    /// Port of `preview_widget.preferred_content_height(client_width)`.
    func preferredContentHeight(for path: String?, clientWidth: CGFloat) -> CGFloat {
        let size = path.flatMap { cachedImage(for: $0) }?.size
        return PreviewPaneLayout.preferredContentHeight(imageSize: size, clientWidth: clientWidth)
    }

    func remember(path: String, image: NSImage) {
        imagePath = path
        self.image = image
    }

    func clear() {
        imagePath = nil
        image = nil
    }
}
