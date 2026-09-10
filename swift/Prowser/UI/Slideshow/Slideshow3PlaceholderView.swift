import SwiftUI

struct Slideshow3PlaceholderView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            Text("Floating Frames Slideshow")
                .font(.title3)
            Text("Coming soon — use Panning (⇧S) or Multiple Images (S) for now.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Return to Thumbnails") {
                appState.fileData.setViewMode(.thumbnail)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .foregroundStyle(.white)
        .onExitCommand {
            appState.fileData.setViewMode(.thumbnail)
        }
    }
}
