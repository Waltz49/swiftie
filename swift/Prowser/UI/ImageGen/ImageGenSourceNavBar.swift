import SwiftUI

/// Prev/next source controls for edit and expand panels (Python `image_gen_source_nav`).
@MainActor
struct ImageGenSourceNavBar: View {
    @Environment(AppState.self) private var appState
    let currentPath: String?
    let onSelectPath: (String) -> Void

    private var displayedImages: [String] {
        appState.fileData.displayedImages
    }

    private var currentIndex: Int? {
        guard let currentPath else { return nil }
        return displayedImages.firstIndex(of: currentPath)
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                navigate(delta: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!canNavigate(delta: -1))
            .help("Previous source image")

            if let currentPath {
                Text(URL(fileURLWithPath: currentPath).lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)
            }

            Button {
                navigate(delta: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!canNavigate(delta: 1))
            .help("Next source image")
        }
    }

    private func canNavigate(delta: Int) -> Bool {
        guard let index = currentIndex else { return false }
        let next = index + delta
        return next >= 0 && next < displayedImages.count
    }

    private func navigate(delta: Int) {
        guard let index = currentIndex else { return }
        let next = index + delta
        guard displayedImages.indices.contains(next) else { return }
        onSelectPath(displayedImages[next])
    }
}
