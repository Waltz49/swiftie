import AppKit
import SwiftUI

/// Dimension helper icons shared by Resize Images (screen / square / reverse / import).
@MainActor
struct ImageGenDimHelperIconButton: View {
    let normalName: String
    let hoverName: String
    var tooltip: String = ""
    var graphicTooltipUsesButtonAsset: Bool = true
    var graphicTooltipIcon: NSImage? = nil
    var graphicTooltipIconPixelSize: CGFloat = ImageGenExifImport.importTooltipImageSide
    let action: () -> Void

    var body: some View {
        AppAssetIconButton(
            normalName: normalName,
            hoverName: hoverName,
            size: 22,
            iconSize: 16,
            tooltip: tooltip,
            graphicTooltipUsesButtonAsset: graphicTooltipUsesButtonAsset,
            graphicTooltipIcon: graphicTooltipIcon,
            graphicTooltipIconPixelSize: graphicTooltipIconPixelSize,
            action: action
        )
    }
}

enum ImageGenDimHelperScreen {
    static func pixelSize() -> (width: Int, height: Int) {
        let screen = NSScreen.main?.frame.size ?? NSSize(width: 1024, height: 1024)
        return (Int(screen.width.rounded()), Int(screen.height.rounded()))
    }
}

enum ImageGenDimHelperTooltips {
    static let importSize =
        "Import size from the\n"
        + "dimensions of the first source image."
    static let screenSize =
        "Set size to fit your screen.\n"
        + "Limited by aspect ratio lock and\n"
        + "max size from Settings Dialog."
    static let screenFit =
        "Fit to screen:\n"
        + "Scale to the largest size that fits\n"
        + "on screen while keeping the current aspect ratio.\n"
        + "Limited by max size from Settings."
    static let square = "Square:\nMake width and height equal."
    static let reverse = "Reverse:\nSwap width and height."
    static let aspect =
        "Keep width and height proportional\nwhen either dimension is changed."
    static let doubleArea =
        "Double the pixel area (width × height),\n"
        + "keeping aspect ratio.\n"
        + "Limited by min/max size and Settings."
    static let halfArea =
        "Halve the pixel area (width × height),\n"
        + "keeping aspect ratio.\n"
        + "Limited by min/max size and Settings."
}
