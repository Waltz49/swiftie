import SwiftUI

/// Prev/next source controls for edit and expand panels (Python `image_gen_source_nav`).
@MainActor
struct ImageGenSourceNavBar: View {
    @Environment(AppState.self) private var appState
    let currentPath: String?
    let onSelectPath: (String) -> Void

    var body: some View {
        ImageGenSourceNavRow(currentPath: currentPath, onSelectPath: onSelectPath) {
            if let currentPath {
                Text(URL(fileURLWithPath: currentPath).lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Color.clear
            }
        }
    }
}
