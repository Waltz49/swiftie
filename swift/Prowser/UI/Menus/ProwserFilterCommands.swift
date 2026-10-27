import SwiftUI

/// Filter menu (separate type — `ProwserCommands` is at the ten-entry `CommandsBuilder` limit).
struct ProwserFilterCommands: Commands {
    @Bindable var appState: AppState

    private var allowBrowserMenuCommands: Bool {
        MainActor.assumeIsolated {
            _ = appState.menuCommandsRevision
            return appState.menuRefresh.browserMenuCommandsEnabled
        }
    }

    private var filterMenuEnabled: Bool {
        MainActor.assumeIsolated {
            _ = appState.fileData.currentViewMode
            let mode = appState.fileData.currentViewMode
            return mode == .thumbnail || mode == .list
        }
    }

    var body: some Commands {
        CommandMenu("Filter") {
            FilterMenuCommandsContent(
                appState: appState,
                commandsEnabled: allowBrowserMenuCommands && filterMenuEnabled
            )
        }
    }
}

@MainActor
private struct FilterMenuCommandsContent: View {
    @Bindable var appState: AppState
    let commandsEnabled: Bool

    var body: some View {
        Group {
            let snapshot = FilterPresetMenu.model(appState: appState)
            let _ = appState.filterSettings.filterPattern
            let _ = appState.config.getSavedFilters()

            Button("Edit...") {
                appState.presentFilterEditSheet()
            }

            Divider()

            FilterNoFilterMenuButton(appState: appState, selected: snapshot.noFilterSelected)

            if !snapshot.presets.isEmpty {
                Divider()
            }

            ForEach(Array(snapshot.presets.enumerated()), id: \.offset) { _, entry in
                FilterPresetMenuButton(appState: appState, entry: entry)
            }
        }
        .disabled(!commandsEnabled)
    }
}

private struct FilterNoFilterMenuButton: View {
    @Bindable var appState: AppState
    let selected: Bool

    var body: some View {
        Button(selected ? "✓ No Filter (*)" : "No Filter (*)") {
            Task { @MainActor in appState.applyFilenameFilterPattern("*") }
        }
    }
}

private struct FilterPresetMenuButton: View {
    @Bindable var appState: AppState
    let entry: FilterPresetMenu.PresetEntry

    var body: some View {
        Button(entry.isSelected ? "✓ \(entry.displayTitle)" : entry.displayTitle) {
            Task { @MainActor in appState.applyFilenameFilterPattern(entry.applyPattern) }
        }
    }
}
