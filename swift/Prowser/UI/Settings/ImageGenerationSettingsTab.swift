import SwiftUI

@MainActor
struct ImageGenerationSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var pythonEnvironmentExpanded = false

    var body: some View {
        SettingsCollapsibleTabLayout(
            onExpandAll: { pythonEnvironmentExpanded = true },
            onCollapseAll: { pythonEnvironmentExpanded = false }
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Image Generation").font(.title2)
                ImageGenerationSettingsSection(pythonEnvironmentExpanded: $pythonEnvironmentExpanded)
            }
        }
    }
}
