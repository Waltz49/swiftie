import SwiftUI

struct ImageListView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let images = appState.fileData.displayedImages
        let thumbnailRefreshToken = appState.thumbnailInvalidationGeneration
        let current = appState.fileData.currentImagePath
        let colors = appState.theme.colors
        let rowHeight = CGFloat(appState.config.int(forKey: "list_view_row_height", default: 48))
        let thumbSize = max(28, rowHeight - 8)

        List(selection: Binding(
            get: { current },
            set: { newPath in
                guard let newPath,
                      let index = images.firstIndex(of: newPath) else { return }
                appState.fileData.setCurrentIndex(index)
                appState.fileData.setCurrentImagePath(newPath)
            }
        )) {
            ForEach(images, id: \.self) { path in
                HStack {
                    ListThumbnail(
                        path: path,
                        cache: appState.thumbnailCache,
                        refreshToken: thumbnailRefreshToken
                    )
                        .frame(width: thumbSize, height: thumbSize)
                    VStack(alignment: .leading) {
                        Text((path as NSString).lastPathComponent)
                            .foregroundStyle(path == current ? colors.currentImageBorder : colors.text)
                        Text(fileSizeLabel(path: path))
                            .font(.caption)
                            .foregroundStyle(colors.sidebarMutedText)
                    }
                }
                .listRowBackground(
                    path == current
                        ? colors.currentImageBackground.opacity(0.35)
                        : colors.thumbnailGridBackground
                )
                .frame(height: rowHeight)
                .tag(path as String?)
            }
        }
        .scrollContentBackground(.hidden)
        .background(colors.thumbnailGridBackground)
        .onTapGesture(count: 2) {
            appState.fileData.setViewMode(.browse)
        }
    }

    private func fileSizeLabel(path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return "" }
        return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
    }
}

private struct ListThumbnail: View {
    let path: String
    let cache: ThumbnailCache
    let refreshToken: Int

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                Rectangle().fill(Color.secondary.opacity(0.15))
            }
        }
        .task(id: "\(path)-\(refreshToken)") {
            image = nil
            guard let cgImage = await cache.generateThumbnail(for: path, size: 96) else { return }
            image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        }
    }
}
