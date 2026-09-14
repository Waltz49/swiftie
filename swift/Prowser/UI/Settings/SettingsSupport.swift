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
        case .caches: return "externaldrive"
        }
    }

    static func visibleTabs() -> [SettingsTab] {
        SettingsTab.allCases
    }

    /// Session-only; updated when Settings closes with OK or Cancel (Python `_last_tab_id`).
    private(set) static var lastSessionTab: SettingsTab = .general

    static func rememberSessionTab(_ tab: SettingsTab) {
        let visible = visibleTabs()
        lastSessionTab = visible.contains(tab) ? tab : (visible.first ?? .general)
    }

    static func resolvedOpenTab(explicit: SettingsTab?) -> SettingsTab {
        if let explicit {
            return visibleTabs().contains(explicit) ? explicit : .general
        }
        let visible = visibleTabs()
        if visible.contains(lastSessionTab) {
            return lastSessionTab
        }
        return visible.first ?? .general
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

    static func pickDirectory(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.wrappedValue = url.path
    }

    static func pickFile(into binding: Binding<String>, allowedTypes: [String] = []) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !allowedTypes.isEmpty {
            panel.allowedContentTypes = allowedTypes.compactMap { ext in
                guard !ext.isEmpty else { return nil }
                return .init(filenameExtension: ext)
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.wrappedValue = url.path
    }

    static func pickApplication(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.wrappedValue = url.deletingPathExtension().lastPathComponent
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
            Text("This tab is not available in the Swift-only image browser.")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
