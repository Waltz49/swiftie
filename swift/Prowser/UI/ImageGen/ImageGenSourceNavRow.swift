import SwiftUI

/// Prev/next controls flanking a center preview (Python ``ImageGenSourceNavRow``).
@MainActor
struct ImageGenSourceNavRow<Center: View>: View {
    @Environment(AppState.self) private var appState
    let currentPath: String?
    var navigationLocked: Bool = false
    let onSelectPath: (String) -> Void
    @ViewBuilder var center: () -> Center

    private var displayedImages: [String] {
        appState.fileData.displayedImages
    }

    private var currentIndex: Int? {
        guard let currentPath else { return nil }
        return displayedImages.firstIndex(of: currentPath)
    }

    private var navigationVisible: Bool {
        guard currentPath != nil else { return false }
        let mode = appState.fileData.currentViewMode
        guard mode == .browse || mode == .thumbnail else { return false }
        return true
    }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            if navigationVisible {
                navButton(delta: -1, symbol: "chevron.left", help: "Previous source image")
            }
            center()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            if navigationVisible {
                navButton(delta: 1, symbol: "chevron.right", help: "Next source image")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func navButton(delta: Int, symbol: String, help: String) -> some View {
        Button {
            navigate(delta: delta)
        } label: {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(navigationLocked || !canNavigate(delta: delta))
        .help(help)
    }

    private func canNavigate(delta: Int) -> Bool {
        guard let index = currentIndex else { return false }
        let next = index + delta
        return next >= 0 && next < displayedImages.count
    }

    func navigate(delta: Int) {
        guard let index = currentIndex else { return }
        let next = index + delta
        guard displayedImages.indices.contains(next) else { return }
        onSelectPath(displayedImages[next])
    }
}
