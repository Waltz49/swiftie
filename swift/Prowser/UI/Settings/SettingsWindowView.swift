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
            DeferredSettingsTabView(
                title: "Maps and Editor",
                detail: "Map application preference and external image editor settings."
            )
        case .slideshow:
            SlideshowSettingsTab()
        case .similarity:
            DeferredSettingsTabView(
                title: "Models for Search",
                detail: "CLIP and similarity search model configuration."
            )
        case .faces:
            DeferredSettingsTabView(
                title: "Face Recognition",
                detail: "Face detection model paths and recognition settings."
            )
        case .captioning:
            DeferredSettingsTabView(
                title: "Captioning",
                detail: "Automatic image captioning model settings."
            )
        case .lora:
            DeferredSettingsTabView(
                title: "LoRA",
                detail: "LoRA model catalogs and download settings."
            )
        case .caches:
            CacheSettingsTab()
        }
    }
}
