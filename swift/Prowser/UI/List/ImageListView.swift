import SwiftUI

struct ImageListView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ImageListNSViewRepresentable()
            .background(appState.theme.colors.thumbnailGridBackground)
    }
}
