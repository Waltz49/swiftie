import SwiftUI

@MainActor
struct FindReferencesSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private let thumbSize: CGFloat = 96
    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 8)]

    var body: some View {
        let target = appState.findReferencesTargetPath ?? ""
        let targetName = (target as NSString).lastPathComponent

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ReferenceThumbnailCell(path: target, size: thumbSize, showLabel: false)
                Text("EXIF user comments referencing \"\(targetName)\". Click an image to open it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if appState.findReferencesMatches.isEmpty {
                Text("No references found.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(appState.findReferencesMatches, id: \.self) { path in
                            Button {
                                appState.openPaths([path])
                                dismiss()
                            } label: {
                                ReferenceThumbnailCell(path: path, size: thumbSize, showLabel: true)
                            }
                            .buttonStyle(.plain)
                            .help(path)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 380)
        .persistedDialogGeometry(
            DialogGeometryKey.findReferences,
            defaultWidth: 560,
            defaultHeight: 420,
            minWidth: 520,
            minHeight: 380
        )
    }
}

private struct ReferenceThumbnailCell: View {
    @Environment(AppState.self) private var appState

    let path: String
    let size: CGFloat
    let showLabel: Bool

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: size, height: size)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            if showLabel {
                Text((path as NSString).lastPathComponent)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: size + 8)
            }
        }
        .task(id: path) {
            let pixelSize = Int(size * 2)
            if let cg = await appState.thumbnailCache.generateThumbnail(for: path, size: pixelSize) {
                image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            } else if let loaded = NSImage(contentsOfFile: path) {
                image = loaded
            }
        }
    }
}
