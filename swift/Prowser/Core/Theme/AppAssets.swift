import AppKit
import SwiftUI

/// Bundled UI assets copied from repo-root `assets/`.
enum AppAssets {
    private static var bundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }

    static func url(name: String, fileExtension: String) -> URL? {
        bundle.url(forResource: name, withExtension: fileExtension, subdirectory: "Assets")
            ?? bundle.url(forResource: name, withExtension: fileExtension)
    }

    static func nsImage(name: String, fileExtension: String = "png") -> NSImage? {
        guard let url = url(name: name, fileExtension: fileExtension) else { return nil }
        return NSImage(contentsOf: url)
    }

    static func image(name: String, fileExtension: String = "png") -> Image? {
        guard let nsImage = nsImage(name: name, fileExtension: fileExtension) else { return nil }
        return Image(nsImage: nsImage)
    }
}

struct AppAssetIconButton: View {
    let normalName: String
    let hoverName: String
    var fileExtension: String = "png"
    var size: CGFloat = 24
    var tooltip: String = ""
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            let imageName = isHovered ? hoverName : normalName
            if let image = AppAssets.image(name: imageName, fileExtension: fileExtension) {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: size - 6, height: size - 6)
            } else {
                Image(systemName: "gearshape")
                    .frame(width: size, height: size)
            }
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.secondary.opacity(isHovered ? 0.8 : 0.35), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}
