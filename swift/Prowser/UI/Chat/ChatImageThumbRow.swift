import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ChatImageThumbMetrics {
    static let thumbSize: CGFloat = 64
    static let gap: CGFloat = 4
}

/// Accepts file URL drops and appends validated image paths (Python ``add_dropped_paths`` / ``validate_image_file``).
@MainActor
enum ChatImageThumbDrop {
    static func acceptFileURLs(
        from providers: [NSItemProvider],
        imageExtensions: [String],
        existingPaths: [String],
        maxImages: Int,
        onAppend: @escaping ([String]) -> Void
    ) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.isFileURL else { return }
                let path = url.standardizedFileURL.path
                Task { @MainActor in
                    let added = pathsToAppend(
                        incoming: [path],
                        existing: existingPaths,
                        maxImages: maxImages,
                        imageExtensions: imageExtensions
                    )
                    guard !added.isEmpty else { return }
                    onAppend(added)
                }
            }
        }
        return accepted
    }

    static func pathsToAppend(
        incoming: [String],
        existing: [String],
        maxImages: Int,
        imageExtensions: [String]
    ) -> [String] {
        var merged = existing.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let existingSet = Set(merged)
        var added: [String] = []
        for path in incoming {
            if merged.count >= maxImages { break }
            let abs = URL(fileURLWithPath: path).standardizedFileURL.path
            guard ChatUserPromptFavoriteImages.isValidImageFile(at: abs, imageExtensions: imageExtensions) else {
                continue
            }
            if existingSet.contains(abs) || merged.contains(abs) { continue }
            merged.append(abs)
            added.append(abs)
        }
        return added
    }
}

/// Flowing row of chat attachment thumbnails (Python ``ChatImageThumbRow`` / ``ChatImageThumb``).
@MainActor
struct ChatImageThumbRow: View {
    @Environment(AppState.self) private var appState
    @Binding var paths: [String]
    var allowRemove: Bool = false
    var canOpen: Bool = true
    var maxImages: Int = ChatSelectionImageTrigger.maxChatImages

    var body: some View {
        GeometryReader { geo in
            let cols = columnCount(width: geo.size.width, pathCount: paths.count)
            let rows = (paths.count + cols - 1) / cols
            let height = CGFloat(rows) * ChatImageThumbMetrics.thumbSize
                + CGFloat(max(0, rows - 1)) * ChatImageThumbMetrics.gap
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(ChatImageThumbMetrics.thumbSize), spacing: ChatImageThumbMetrics.gap), count: cols),
                alignment: .leading,
                spacing: ChatImageThumbMetrics.gap
            ) {
                ForEach(paths, id: \.self) { path in
                    ChatImageThumbCell(
                        path: path,
                        allowRemove: allowRemove,
                        canOpen: canOpen,
                        openPaths: paths,
                        onRemove: {
                            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
                            paths.removeAll {
                                URL(fileURLWithPath: $0).standardizedFileURL.path == normalized
                            }
                        }
                    )
                }
            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        }
        .frame(minHeight: paths.isEmpty ? 0 : ChatImageThumbMetrics.thumbSize)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            acceptDrop(providers)
        }
    }

    private func columnCount(width: CGFloat, pathCount: Int) -> Int {
        let cell = ChatImageThumbMetrics.thumbSize + ChatImageThumbMetrics.gap
        let byWidth = max(1, Int(width / cell))
        return min(byWidth, max(pathCount, 1))
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        ChatImageThumbDrop.acceptFileURLs(
            from: providers,
            imageExtensions: appState.config.imageExtensions,
            existingPaths: paths,
            maxImages: maxImages
        ) { added in
            paths.append(contentsOf: added)
        }
    }
}

@MainActor
private struct ChatImageThumbCell: View {
    let path: String
    let allowRemove: Bool
    let canOpen: Bool
    let openPaths: [String]
    let onRemove: () -> Void

    @State private var hoverRemove = false
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Color.gray.opacity(0.3))
                }
            }
            .frame(width: ChatImageThumbMetrics.thumbSize, height: ChatImageThumbMetrics.thumbSize)
            .clipped()

            if allowRemove, hoverRemove {
                ChatImageThumbRemoveBadge()
                    .padding(2)
            }
        }
        .frame(width: ChatImageThumbMetrics.thumbSize, height: ChatImageThumbMetrics.thumbSize)
        .contentShape(Rectangle())
        .onHover { isHovering in hoverRemove = allowRemove && isHovering }
        .onTapGesture {
            if allowRemove, hoverRemove {
                onRemove()
                return
            }
            guard canOpen else { return }
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            NotificationCenter.default.post(
                name: .prowserChatOpenImagePaths,
                object: nil,
                userInfo: ["paths": openPaths, "directory": dir]
            )
        }
        .onAppear {
            image = NSImage(contentsOfFile: path)
        }
    }
}

/// Red corner X overlay (Python ``ChatImageThumb`` remove affordance).
private struct ChatImageThumbRemoveBadge: View {
    var body: some View {
        ZStack {
            Color.white
            Color.black.padding(2)
            Canvas { context, size in
                let inset: CGFloat = 6
                var path = Path()
                path.move(to: CGPoint(x: inset, y: inset))
                path.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset))
                path.move(to: CGPoint(x: size.width - inset, y: inset))
                path.addLine(to: CGPoint(x: inset, y: size.height - inset))
                context.stroke(path, with: .color(Color(red: 220 / 255, green: 40 / 255, blue: 40 / 255)), lineWidth: 2)
            }
            .padding(4)
        }
        .frame(width: 24, height: 24)
    }
}
