import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case favorites
    case directories
    case extensions
    case destinations
    case excludes
    case theme
    case maps
    case slideshow
    case similarity
    case faces
    case captioning
    case lora
    case caches

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .favorites: return "Favorites"
        case .directories: return "Directories"
        case .extensions: return "File Types"
        case .destinations: return "Destinations"
        case .excludes: return "Excludes"
        case .theme: return "Theme"
        case .maps: return "Maps and Editor"
        case .slideshow: return "Slideshow"
        case .similarity: return "Models for Search"
        case .faces: return "Face Recognition"
        case .captioning: return "Captioning"
        case .lora: return "LoRA"
        case .caches: return "Caches"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .favorites: return "star"
        case .directories: return "folder"
        case .extensions: return "doc"
        case .destinations: return "arrow.right.circle"
        case .excludes: return "nosign"
        case .theme: return "paintpalette"
        case .maps: return "map"
        case .slideshow: return "play.rectangle"
        case .similarity: return "sparkle.magnifyingglass"
        case .faces: return "person.crop.rectangle"
        case .captioning: return "text.bubble"
        case .lora: return "cube"
        case .caches: return "externaldrive"
        }
    }

    static func visibleTabs() -> [SettingsTab] {
        SettingsTab.allCases.filter { tab in
            switch tab {
            case .faces: return BundleCapabilities.facesUIEnabled
            case .captioning, .lora, .similarity: return BundleCapabilities.imageGenUIEnabled
            default: return true
            }
        }
    }
}

@MainActor
enum SettingsSupport {
    static func boolBinding(
        config: AppConfig,
        key: String,
        default defaultValue: Bool = false,
        onChange: @escaping () -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { config.bool(forKey: key, default: defaultValue) },
            set: { newValue in
                config.setValue(newValue, forKey: key)
                onChange()
            }
        )
    }

    static func intBinding(
        config: AppConfig,
        key: String,
        default defaultValue: Int = 0,
        onChange: @escaping () -> Void
    ) -> Binding<Int> {
        Binding(
            get: { config.int(forKey: key, default: defaultValue) },
            set: { newValue in
                config.setValue(newValue, forKey: key)
                onChange()
            }
        )
    }

    static func stringBinding(
        config: AppConfig,
        key: String,
        default defaultValue: String = "",
        onChange: @escaping () -> Void
    ) -> Binding<String> {
        Binding(
            get: { config.string(forKey: key, default: defaultValue) },
            set: { newValue in
                config.setValue(newValue, forKey: key)
                onChange()
            }
        )
    }

    static func pickDirectory(into binding: Binding<String?>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.wrappedValue = url.path
    }
}

struct SettingsPathRow: View {
    let title: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline)
            Text(path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

@MainActor
struct DeferredSettingsTabView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2)
            Text(detail)
                .foregroundStyle(.secondary)
            Text("This tab will be completed in a later milestone (Python bridge or ImageGen UI).")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
