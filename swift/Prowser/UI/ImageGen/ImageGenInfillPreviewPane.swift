import SwiftUI

@MainActor
struct ImageGenInfillPreviewPane: View {
    let sourcePath: String?
    var onSourcePathChanged: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = sourcePath {
                ImageGenSourceNavRow(currentPath: path, onSelectPath: { newPath in
                    onSourcePathChanged?(newPath)
                }) {
                    VStack(spacing: 8) {
                        if let image = NSImage(contentsOfFile: path) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Text(
                            "Paint mask in Pixelmator or the Python paint canvas "
                                + "(interactive paint canvas not yet available in Swift)."
                        )
                        .font(ImageGenInlineFieldLayout.infoLineFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(minHeight: 280)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Text("Infill requires an active source image.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
