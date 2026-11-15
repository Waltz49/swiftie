import SwiftUI

@MainActor
struct ImageGenerationSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var promptModificationExpanded = false
    @State private var cooldownTimesExpanded = false
    @State private var miscellaneousExpanded = false
    @State private var pythonEnvironmentExpanded = false

    var body: some View {
        SettingsCollapsibleTabLayout(
            onExpandAll: {
                promptModificationExpanded = true
                cooldownTimesExpanded = true
                miscellaneousExpanded = true
                pythonEnvironmentExpanded = true
            },
            onCollapseAll: {
                promptModificationExpanded = false
                cooldownTimesExpanded = false
                miscellaneousExpanded = false
                pythonEnvironmentExpanded = false
            }
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Image Generation").font(.title2)
                ImageGenerationSettingsSection(
                    promptModificationExpanded: $promptModificationExpanded,
                    cooldownTimesExpanded: $cooldownTimesExpanded,
                    miscellaneousExpanded: $miscellaneousExpanded,
                    pythonEnvironmentExpanded: $pythonEnvironmentExpanded
                )
            }
        }
    }
}
