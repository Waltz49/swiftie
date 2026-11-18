import SwiftUI

@MainActor
struct FilterMenuCommandsContent: View {
    @Bindable var appState: AppState
    let commandsEnabled: Bool

    var body: some View {
        Group {
            let snapshot = FilterPresetMenu.model(appState: appState)
            let _ = appState.filterSettings.filterPattern
            let _ = appState.config.getSavedFilters()

            FilterNoFilterMenuButton(appState: appState, selected: snapshot.noFilterSelected)

            if !snapshot.presets.isEmpty {
                Divider()
            }

            ForEach(Array(snapshot.presets.enumerated()), id: \.offset) { _, entry in
                FilterPresetMenuButton(appState: appState, entry: entry)
            }

            Divider()

            Button("Edit...") {
                appState.presentFilterEditSheet()
            }
        }
        .disabled(!commandsEnabled)
    }
}

private struct FilterNoFilterMenuButton: View {
    @Bindable var appState: AppState
    let selected: Bool

    var body: some View {
        Toggle(isOn: Binding(
            get: { selected },
            set: { newValue in
                if newValue, !selected {
                    appState.applyFilenameFilterPattern("*")
                }
            }
        )) {
            Text("No Filter (*)")
        }
    }
}

private struct FilterPresetMenuButton: View {
    @Bindable var appState: AppState
    let entry: FilterPresetMenu.PresetEntry

    var body: some View {
        Toggle(isOn: Binding(
            get: { entry.isSelected },
            set: { newValue in
                if newValue, !entry.isSelected {
                    appState.applyFilenameFilterPattern(entry.applyPattern)
                }
            }
        )) {
            Text(entry.displayTitle)
        }
    }
}