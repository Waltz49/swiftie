import AppKit
import SwiftUI

/// Sidebar preview of the active image. Port of `preview_widget.py`.
struct PreviewPaneView: View {
    @Environment(AppState.self) private var appState
    @State private var previewImage: NSImage?
    @State private var loadedPath: String?

    var body: some View {
        Group {
            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(4)
                    .contentShape(Rectangle())
                    .onTapGesture { openBrowse() }
                    .help("Click to open in browse view")
            } else {
                Text("No image selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(appState.theme.colors.sidebarBackground)
        .onChange(of: appState.fileData.currentImagePath) { _, path in
            Task { await reloadPreview(path: path) }
        }
        .onAppear {
            Task { await reloadPreview(path: appState.fileData.currentImagePath) }
        }
    }

    @MainActor
    private func openBrowse() {
        guard appState.fileData.currentImagePath != nil else { return }
        appState.fileData.setViewMode(.browse)
    }

    @MainActor
    private func reloadPreview(path: String?) async {
        guard let path else {
            previewImage = nil
            loadedPath = nil
            return
        }
        if path == loadedPath, previewImage != nil { return }
        loadedPath = path

        let pixelSize = max(256, Int(appState.leftSidebarWidth * 2))
        if let cgImage = await appState.thumbnailCache.generateThumbnail(for: path, size: pixelSize) {
            previewImage = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        } else if let image = NSImage(contentsOfFile: path) {
            previewImage = image
        } else {
            previewImage = nil
        }
    }
}
