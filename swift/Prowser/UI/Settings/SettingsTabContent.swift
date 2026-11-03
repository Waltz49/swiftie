import SwiftUI

/// Shared settings detail pane for each tab (Preferences window and string scanner).
enum SettingsTabContent {
    @ViewBuilder
    @MainActor
    static func detail(for tab: SettingsTab) -> some View {
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
        case .caches:
            CacheSettingsTab()
        case .modelsSearch:
            ModelsSearchSettingsTab()
        case .faceRecognition:
            FaceRecognitionSettingsTab()
        case .imageGeneration:
            ImageGenerationSettingsTab()
        case .lora:
            LoRASettingsTab()
        }
    }
}
