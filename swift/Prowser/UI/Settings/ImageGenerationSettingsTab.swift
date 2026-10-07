import SwiftUI

@MainActor
struct ImageGenerationSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Image Generation").font(.title2)
                ImageGenerationSettingsSection()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}
