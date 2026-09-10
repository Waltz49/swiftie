import Foundation

/// Reads and writes `~/.prowser/data/settings.json` (compatible with Python `ImageBrowserConfig`).
@Observable
@MainActor
final class AppConfig {
    private let paths: ProfilePaths
    private var settings: [String: Any] = [:]
    private let encoder = JSONSerialization.self

    init(profilePath: String?) {
        paths = ProfilePaths(profilePath: profilePath)
        settings = Self.defaultSettings()
    }

    var prowserHome: URL { paths.prowserHome }
    var dataDirectory: URL { paths.dataDirectory }
    var settingsFile: URL { paths.settingsFile }
    var thumbnailCacheDirectory: URL { paths.thumbnailCacheDirectory }
    var metadataCacheDirectory: URL { paths.metadataCacheDirectory }
    var logsDirectory: URL { paths.logsDirectory }
    var namedPipePath: String { paths.namedPipePath }

    var restoreState: Bool { restoreStateDict()["enabled"] as? Bool ?? true }
    var lastDirectory: String? {
        if let dir = restoreStateDict()["last_directory"] as? String, !dir.isEmpty {
            return dir
        }
        return stringValue("last_directory")
    }

    struct RestoreStateSnapshot {
        var lastFile: String?
        var lastDirectory: String?
        var lastViewMode: String
        var lastMacOSSpaceMode: Bool?
    }

    /// Python `get_restore_state` (nil when disabled or paths missing).
    func getRestoreState() -> RestoreStateSnapshot? {
        guard restoreState else { return nil }
        let dict = restoreStateDict()
        let lastFile = dict["last_file"] as? String
        if let lastFile, !lastFile.isEmpty, !FileManager.default.fileExists(atPath: lastFile) {
            clearRestoreState()
            return nil
        }
        let lastDirectory = dict["last_directory"] as? String
        if let lastDirectory, !lastDirectory.isEmpty, !FileManager.default.fileExists(atPath: lastDirectory) {
            clearRestoreState()
            return nil
        }
        return RestoreStateSnapshot(
            lastFile: lastFile,
            lastDirectory: lastDirectory,
            lastViewMode: dict["last_view_mode"] as? String ?? "thumbnail",
            lastMacOSSpaceMode: dict["last_macos_space_mode"] as? Bool
        )
    }

    /// Python `save_restore_state`.
    func saveRestoreState(
        filePath: String?,
        directory: String?,
        viewMode: String,
        macosSpaceMode: Bool?
    ) {
        var restore = restoreStateDict()
        restore["enabled"] = restore["enabled"] as? Bool ?? true
        restore["last_file"] = filePath
        restore["last_directory"] = directory
        restore["last_view_mode"] = viewMode
        restore["last_macos_space_mode"] = macosSpaceMode
        updateSetting("restore_state", value: restore)
        if let directory {
            settings["last_directory"] = directory
        }
    }

    func setRestoreStateEnabled(_ enabled: Bool) {
        var restore = restoreStateDict()
        restore["enabled"] = enabled
        updateSetting("restore_state", value: restore)
    }

    func updateRestoreMacOSSpaceMode(_ enabled: Bool) {
        var restore = restoreStateDict()
        restore["last_macos_space_mode"] = enabled
        updateSetting("restore_state", value: restore)
    }

    func clearRestoreState() {
        var restore = restoreStateDict()
        restore["enabled"] = false
        restore["last_file"] = NSNull()
        restore["last_directory"] = NSNull()
        restore["last_view_mode"] = "thumbnail"
        restore["last_macos_space_mode"] = NSNull()
        updateSetting("restore_state", value: restore)
    }
    var imageExtensions: [String] {
        let raw: [String]
        if let list = settings["image_extensions"] as? [String], !list.isEmpty {
            raw = list
        } else {
            raw = Self.defaultImageExtensions
        }
        return raw.map { Self.normalizeExtension($0) }
    }

    /// Settings store extensions with a leading dot (e.g. `.webp`); paths use `pathExtension` without it.
    static func normalizeExtension(_ ext: String) -> String {
        let lower = ext.lowercased()
        if lower.hasPrefix(".") { return String(lower.dropFirst()) }
        return lower
    }

    var ignoreExifRotation: Bool { boolValue("ignore_exif_rotation", default: false) }
    var useExifDate: Bool { boolValue("use_exif_date", default: true) }
    var filteredTree: String { stringValue("filtered_tree") ?? "images" }
    var filterPattern: String? { stringValue("filter_pattern") }
    var savedFilters: [String] { getSavedFilters() }
    var sidebarWidth: CGFloat { CGFloat(numberValue("sidebar_width", default: 300)) }
    var rightSidebarWidth: CGFloat { CGFloat(numberValue("right_sidebar_width", default: 300)) }

    func loadSettings() {
        guard let data = try? Data(contentsOf: paths.settingsFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            mergeMissingDefaults()
            return
        }
        settings = json
        migrateRestoreStateIfNeeded()
        mergeMissingDefaults()
    }

    func saveSettings() {
        mergeMissingDefaults()
        guard JSONSerialization.isValidJSONObject(settings),
              let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: paths.settingsFile, options: .atomic)
    }

    func updateSetting(_ key: String, value: Any?) {
        if let value {
            settings[key] = value
        } else {
            settings.removeValue(forKey: key)
        }
        saveSettings()
    }

    func setValue(_ value: Any, forKey key: String) {
        settings[key] = value
        saveSettings()
    }

    func rawSettings() -> [String: Any] { settings }

    func getSavedFilters() -> [String] {
        let filters = settings["saved_filters"] as? [String] ?? []
        return filters.filter { filter in
            let trimmed = filter.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != "*"
        }
    }

    func saveFilters(_ filters: [String]) {
        var normalized: [String] = []
        var seen = Set<String>()
        for pattern in filters {
            let trimmed = FilterPatternFormatting.forStorage(pattern)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            normalized.append(trimmed)
        }
        updateSetting("saved_filters", value: normalized)
    }

    /// Mirrors Python `ImageBrowserConfig.normalize_filter_pattern`.
    static func normalizeFilterPattern(_ pattern: String?) -> String {
        guard let pattern, !pattern.isEmpty else { return "*" }
        var trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("*") {
            trimmed = String(trimmed.dropLast())
        }
        return trimmed + "*"
    }

    func bool(forKey key: String, default defaultValue: Bool = false) -> Bool {
        boolValue(key, default: defaultValue)
    }

    func int(forKey key: String, default defaultValue: Int = 0) -> Int {
        Int(numberValue(key, default: Double(defaultValue)))
    }

    func double(forKey key: String, default defaultValue: Double = 0) -> Double {
        numberValue(key, default: defaultValue)
    }

    func string(forKey key: String, default defaultValue: String = "") -> String {
        stringValue(key) ?? defaultValue
    }

    func stringArray(forKey key: String) -> [String] {
        (settings[key] as? [String]) ?? []
    }

    func optionalStringArray(forKey key: String, count: Int) -> [String?] {
        let raw = settings[key] as? [Any] ?? []
        return (0..<count).map { index in
            guard index < raw.count else { return nil }
            if raw[index] is NSNull { return nil }
            return raw[index] as? String
        }
    }

    func setOptionalStringArray(_ key: String, values: [String?]) {
        settings[key] = values.map { $0 as Any? ?? NSNull() }
        saveSettings()
    }

    func rootDirectories() -> [String] {
        let raw = settings["root_directories"] as? [String]
        return raw?.isEmpty == false ? raw! : ThemeDefaults.defaultRootDirectories
    }

    func favoriteDirectories() -> [String?] {
        optionalStringArray(forKey: "favorite_directories", count: 9)
    }

    func moveDestinations() -> [String?] {
        optionalStringArray(forKey: "move_destinations", count: 9)
    }

    /// Recent directories for File → Recent (most recent last in storage; returned newest-first).
    func recentDirectories(limit: Int = 15) -> [String] {
        let raw = settings["directory_menu_history"] as? [String] ?? []
        return Array(raw.reversed().prefix(limit))
    }

    func recordRecentDirectory(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = settings["directory_menu_history"] as? [String] ?? []
        history.removeAll { $0 == trimmed }
        history.append(trimmed)
        let maxSize = 20
        if history.count > maxSize {
            history.removeFirst(history.count - maxSize)
        }
        updateSetting("directory_menu_history", value: history)
    }

    func excludeDirectories() -> [[String: Any]] {
        settings["exclude_directories"] as? [[String: Any]] ?? []
    }

    func setExcludeDirectories(_ entries: [[String: Any]]) {
        settings["exclude_directories"] = entries
        saveSettings()
    }

    func applySettingsChange(emit: AppEventBus) {
        emit.emit(.settingsChanged)
    }

    func loadFromConfig(into filter: FilterSettingsModel) {
        filter.setFilterPattern(filterPattern, persist: false)
        filter.setFilteredTree(filteredTree, persist: false)
    }

    // MARK: - Private

    private func mergeMissingDefaults() {
        let defaults = Self.defaultSettings()
        for (key, value) in defaults where settings[key] == nil {
            settings[key] = value
        }
    }

    private func migrateRestoreStateIfNeeded() {
        if settings["restore_state"] is Bool {
            let enabled = settings["restore_state"] as? Bool ?? true
            settings["restore_state"] = [
                "enabled": enabled,
                "last_file": NSNull(),
                "last_directory": settings["last_directory"] as Any? ?? NSNull(),
                "last_view_mode": "thumbnail",
                "last_macos_space_mode": NSNull(),
            ]
        }
    }

    private func restoreStateDict() -> [String: Any] {
        if let dict = settings["restore_state"] as? [String: Any] {
            return dict
        }
        if let enabled = settings["restore_state"] as? Bool {
            return ["enabled": enabled]
        }
        return ["enabled": true]
    }

    private func stringValue(_ key: String) -> String? {
        settings[key] as? String
    }

    private func boolValue(_ key: String, default defaultValue: Bool) -> Bool {
        if let value = settings[key] as? Bool { return value }
        return defaultValue
    }

    private func numberValue(_ key: String, default defaultValue: Double) -> Double {
        if let value = settings[key] as? Double { return value }
        if let value = settings[key] as? Int { return Double(value) }
        return defaultValue
    }

    static let defaultImageExtensions = [
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "webp", "heic", "heif",
        "cr2", "nef", "arw", "dng", "orf", "rw2", "pef", "srw",
    ]

    static func defaultSettings() -> [String: Any] {
        [
            "debug_mode": false,
            "confirm_delete": true,
            "restore_state": [
                "enabled": true,
                "last_file": NSNull(),
                "last_directory": NSNull(),
                "last_view_mode": "thumbnail",
                "last_macos_space_mode": NSNull(),
            ] as [String: Any],
            "wrap_around": true,
            "use_exif_date": true,
            "ignore_exif_rotation": false,
            "filtered_tree": "images",
            "filter_pattern": "*",
            "saved_filters": [] as [String],
            "ui_theme": "dark",
            "file_tree_visible": true,
            "left_sidebar_visible": true,
            "preview_visible": true,
            "chat_visible": false,
            "jobs_visible": true,
            "right_sidebar_visible": true,
            "information_sidebar_visible": true,
            "shortcuts_sidebar_visible": true,
            "sidebar_width": 300,
            "right_sidebar_width": 300,
            "left_splitter_sizes": [200, 200, 200],
            "shortcuts_splitter_sizes": [150, 250, 120],
            "jobs_display_mode": "pane",
            "jobs_pane_compact": false,
            "file_tree_show_toolbar": true,
            "information_show_menu_bar": true,
            "chat_show_toolbar": true,
            "jobs_show_toolbar": true,
            "imagegen": [
                "job_queue_size_mode": "all",
                "job_queue_always_on_top": false,
                "show_progressive_images": false,
                "hold_job_queue": false,
            ],
            "sort_mode": "date",
            "sort_reversed": false,
            "image_extensions": defaultImageExtensions,
            "browse_view_actual_size": false,
            "thumbnail_filename_visible": false,
            "show_extensions": true,
            "show_image_size": false,
            "status_bar_visible": true,
            "thumbnail_cell_size": 150,
            "manual_thumbnail_size": false,
            "show_hidden_directories": false,
            "follow_symlinks": false,
            "always_show_work": false,
            "root_directories": ThemeDefaults.defaultRootDirectories,
            "favorite_directories": [
                NSHomeDirectory() + "/Downloads",
                NSNull(), NSNull(), NSNull(), NSNull(),
                NSNull(), NSNull(), NSNull(), NSNull(),
            ],
            "move_destinations": [
                NSNull(), NSNull(), NSNull(), NSNull(), NSNull(),
                NSNull(), NSNull(), NSNull(), NSNull(),
            ],
            "directory_menu_history": [] as [String],
            "exclude_directories": [],
            "user_theme_colors": ThemeDefaults.userThemeColors(),
            "dark_theme_colors": ThemeDefaults.darkThemeColors(),
            "light_theme_colors": ThemeDefaults.lightThemeColors(),
            "custom_themes": [:] as [String: Any],
            "slideshow_rate": 5000,
            "slideshow_transition_speed": 1300,
            "slideshow_direction": "right",
            "slideshow_max_rotation": 0,
            "slideshow_back_and_forth": false,
            "slideshow_overlap_delay": 0,
            "slideshow_preset_0": SlideshowPresetUtils.presetDefaults["0"]!,
            "slideshow_preset_9": SlideshowPresetUtils.presetDefaults["9"]!,
            "browse_image_history_save_after_ms": 3000,
            "space_key_mode": "exit",
            "map_application": "apple_maps",
            "slideshow2_enlargement": 1.2,
            "slideshow2_speed": 8,
            "slideshow2_high_quality_scaling": false,
            "slideshow3_speed": 1,
            "list_view_row_height": 48,
            "background_clip_enabled": false,
            "background_clip_gather_thumbnails": true,
            "background_clip_extract_faces": false,
        ]
    }
}
