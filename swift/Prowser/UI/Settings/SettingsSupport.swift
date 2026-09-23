import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Tab order matches `settings_dialog.py` `tab_widget.addTab` for ported tabs.
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
    case modelsSearch
    case faceRecognition
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
        case .modelsSearch: return "Models for Search"
        case .faceRecognition: return "Face Recognition"
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
        case .modelsSearch: return "magnifyingglass"
        case .faceRecognition: return "person.crop.circle"
        }
    }

    static func visibleTabs(minBundle: Bool = false) -> [SettingsTab] {
        if minBundle {
            return SettingsTab.allCases.filter { $0 != .faceRecognition }
        }
        return SettingsTab.allCases
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
        let current = SettingsPathValidation.expandedPath(binding.wrappedValue ?? "")
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.wrappedValue = SettingsPathValidation.displayPath(url.path)
    }

    static func pickDirectory(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let current = SettingsPathValidation.expandedPath(binding.wrappedValue)
        if !current.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: current, isDirectory: &isDir), isDir.boolValue {
                panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.wrappedValue = SettingsPathValidation.displayPath(url.path)
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
        let current = SettingsPathValidation.expandedPath(binding.wrappedValue)
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.wrappedValue = SettingsPathValidation.displayPath(url.path)
    }

    /// Load optional path slots from config for settings text fields (display `~/…` when possible).
    static func loadOptionalPathSlots(_ values: [String?]) -> [String?] {
        values.map { value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return SettingsPathValidation.displayPath(value)
        }
    }

    /// Persist optional path slots using expanded paths (Python `_display_to_path` on save).
    static func expandedOptionalPathSlots(_ values: [String?]) -> [String?] {
        values.map { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return SettingsPathValidation.expandedPath(trimmed)
        }
    }

    static func pickApplication(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.title = "Select Image Editor"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.application]
        // Match settings_dialog.py: always start in /Applications.
        panel.directoryURL = applicationsChooserDirectory()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding.wrappedValue = url.deletingPathExtension().lastPathComponent
    }

    /// Start directory for the external-editor chooser (`/Applications`, then `~/Applications`).
    private static func applicationsChooserDirectory() -> URL {
        let systemApps = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if FileManager.default.fileExists(atPath: systemApps.path) {
            return systemApps
        }
        let userApps = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
        if FileManager.default.fileExists(atPath: userApps.path) {
            return userApps
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Favorite slots accept a directory or image file (Python `browse_favorite_destination`).
    static func pickFavoriteDestination(into binding: Binding<String>, imageExtensions: [String]) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        let types = imageExtensions.compactMap { ext -> UTType? in
            let normalized = normalizeImageExtension(ext)
            guard !normalized.isEmpty else { return nil }
            return UTType(filenameExtension: normalized)
        }
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
        let current = SettingsPathValidation.expandedPath(binding.wrappedValue)
        if !current.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: current, isDirectory: &isDir) {
                panel.directoryURL = isDir.boolValue
                    ? URL(fileURLWithPath: current, isDirectory: true)
                    : URL(fileURLWithPath: current).deletingLastPathComponent()
            }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var isDir: ObjCBool = false
        let path = url.path
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            binding.wrappedValue = SettingsPathValidation.displayPath(path)
            return
        }
        let ext = url.pathExtension.lowercased()
        let allowed = Set(imageExtensions.map { normalizeImageExtension($0) })
        if allowed.contains(ext) {
            binding.wrappedValue = SettingsPathValidation.displayPath(path)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Invalid File"
        alert.informativeText = "Selected file is not an image file:\n\n\(path)"
        alert.alertStyle = .warning
        alert.runModal()
    }

    private static func normalizeImageExtension(_ ext: String) -> String {
        let lower = ext.lowercased()
        if lower.hasPrefix(".") { return String(lower.dropFirst()) }
        return lower
    }
}

struct SettingsPathRow: View {
    let title: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline)
            Text(SettingsPathValidation.displayPath(path))
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
        SettingsOutlinedGroupBox(title: { settingsOutlinedGroupBoxTitle(title) }) {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
