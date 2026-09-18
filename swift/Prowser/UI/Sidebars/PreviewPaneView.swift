import AppKit
import SwiftUI

/// Sidebar preview of the active image. Port of `preview_widget.py`.
struct PreviewPaneView: View {
    @Environment(AppState.self) private var appState
    @State private var previewImage: NSImage?
    @State private var loadedPath: String?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let previewImage {
                    let display = PreviewPaneLayout.fitDisplaySize(
                        imageSize: previewImage.size,
                        viewportSize: geometry.size
                    )

                    Image(nsImage: previewImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: display.width, height: display.height)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .contentShape(Rectangle())
                        .onTapGesture { openBrowse() }
                        .help("Click to open in browse view")
                } else {
                    Text("No image selected")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(appState.theme.colors.sidebarBackground)
        .onChange(of: appState.fileData.currentImagePath) { _, path in
            Task { await reloadPreview(path: path) }
        }
        .onAppear {
            appState.previewPaneInLayout = true
            restoreFromSessionCache()
            Task { await reloadPreview(path: appState.fileData.currentImagePath) }
        }
        .onDisappear {
            appState.previewPaneInLayout = false
        }
    }

    @MainActor
    private func openBrowse() {
        guard appState.fileData.currentImagePath != nil else { return }
        appState.fileData.setViewMode(.browse)
    }

    @MainActor
    private func restoreFromSessionCache() {
        guard let path = appState.fileData.currentImagePath,
              let cached = appState.previewPaneCache.cachedImage(for: path) else { return }
        previewImage = cached
        loadedPath = path
    }

    @MainActor
    private func reloadPreview(path: String?) async {
        guard let path else {
            previewImage = nil
            loadedPath = nil
            appState.previewPaneCache.clear()
            return
        }
        if path == loadedPath, previewImage != nil { return }

        if let cached = appState.previewPaneCache.cachedImage(for: path) {
            previewImage = cached
            loadedPath = path
            return
        }

        loadedPath = path
        let pixelSize = max(256, Int(appState.leftSidebarWidth * 2))
        let cgImage = await appState.thumbnailCache.generateThumbnail(for: path, size: pixelSize)
        // The active image may have changed during the await; do not apply a stale result.
        guard loadedPath == path else { return }

        let image: NSImage?
        if let cgImage {
            image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } else {
            image = NSImage(contentsOfFile: path)
        }
        previewImage = image
        if let image {
            appState.previewPaneCache.remember(path: path, image: image)
        }
    }
}
