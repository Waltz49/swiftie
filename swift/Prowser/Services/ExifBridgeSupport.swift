import Foundation

/// Shared registry bridge for Python EXIF read/write parity (`exif/exif_utils.py`, piexif).
@MainActor
enum ExifBridgeSupport {
    static weak var registry: ImageGenRegistryBridge?

    static var isAvailable: Bool {
        registry?.isAvailable == true
    }
}
