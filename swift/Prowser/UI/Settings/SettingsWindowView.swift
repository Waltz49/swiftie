import SwiftUI

@MainActor
struct SettingsWindowView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.visibleTabs(), selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            settingsDetail(for: selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(SettingsDialogChrome.background)
        .persistedDialogGeometry(
            DialogGeometryKey.settings,
            defaultWidth: 920,
            defaultHeight: 680,
            minWidth: 760,
            minHeight: 520,
            sizeFallbackKey: DialogGeometryKey.settingsSizeFallback
        )
        .onAppear {
            appState.theme.captureSnapshot()
        }
        .onDisappear {
            ThemeColorPanelController.shared.closeIfOpen()
            appState.theme.commitPreview()
            appState.config.saveSettings()
            appState.eventBus.emit(.settingsChanged)
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserOpenSettingsTab)) { notification in
            if let raw = notification.userInfo?["tab"] as? String,
               let tab = SettingsTab(rawValue: raw) {
                selectedTab = tab
            }
        }
    }

    @ViewBuilder
    private func settingsDetail(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsTab()
        case .favorites:
            FavoritesSettingsTab()
        case .directories:
            DirectoriesSettingsTab()
        case .extensions:
            ExtensionsSettingsTab()
        case .destinations:
            DestinationsSettingsTab()
        case .excludes:
            ExcludesSettingsTab()
        case .theme:
            ThemeSettingsTab()
        case .maps:
            MapsEditorSettingsTab()
        case .slideshow:
            SlideshowSettingsTab()
        case .similarity:
            ModelsSearchSettingsTab()
        case .faces:
            FaceRecognitionSettingsTab()
        case .captioning:
            CaptioningSettingsTab()
        case .lora:
            LoRASettingsTab()
        case .caches:
            CacheSettingsTab()
        }
    }
}
