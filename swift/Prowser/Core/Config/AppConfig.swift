import CoreGraphics
import Foundation

/// Reads and writes `~/.swift-prowser/data/settings.json`.
@Observable
@MainActor
final class AppConfig {
    private let paths: ProfilePaths
    private var settings: [String: Any] = [:]
    private var settingsSnapshot: [String: Any]?
    private var settingsDraft: [String: Any]?
    private let encoder = JSONSerialization.self

    /// Session-only debug flag. Off at launch unless `--debug`; never written to settings.json.
    private var sessionDebugEnabled = false
    /// Set once at launch from ``AppState`` so Settings/debug writes match the View log file.
    private var boundSessionViewLogURL: URL?

    /// True while the settings window is open (edits stay in memory until OK).
    var isSettingsSessionActive: Bool { settingsDraft != nil }

    func applyLaunchDebugFlag(_ enabled: Bool) {
        sessionDebugEnabled = enabled
    }

    func bindSessionViewLogURL(_ url: URL) {
        boundSessionViewLogURL = url
    }

    private func appendDebugModeEnabledSessionLine() {
        let url = sessionViewLogFileURL
        SessionViewLog.appendLine(
            "[\(SessionViewLog.debugTimestamp())] Debug mode enabled\n",
            logFileURL: url
        )
    }

    func uiThemeAtSettingsOpen() -> String? {
        settingsSnapshot?["ui_theme"] as? String
    }

    init(profilePath: String?) {
        paths = ProfilePaths(profilePath: profilePath)
        settings = Self.defaultSettings()
    }

    var profilePaths: ProfilePaths { paths }
    var prowserHome: URL { paths.prowserHome }
    var dataDirectory: URL { paths.dataDirectory }
    var imageRecognitionCacheDirectory: URL { paths.imageRecognitionCacheDirectory }
    var settingsFile: URL { paths.settingsFile }
    var thumbnailCacheDirectory: URL { paths.thumbnailCacheDirectory }
    var metadataCacheDirectory: URL { paths.metadataCacheDirectory }
    var logsDirectory: URL { paths.logsDirectory }
    var namedPipePath: String { paths.namedPipePath }

    /// Resolved temp work directory (settings override or profile `tmp/`).
    var temporaryFilesDirectory: URL {
        let path = ProwserTempFiles.resolveTemporaryFilesDirectory(
            settings: readSettings(),
            prowserHome: paths.prowserHome
        )
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

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

    /// Python `get_restore_state` (nil when no usable paths).
    func getRestoreState() -> RestoreStateSnapshot? {
        let dict = restoreStateDict()
        var lastFile = dict["last_file"] as? String
        if let file = lastFile, file.isEmpty || !FileManager.default.fileExists(atPath: file) {
            lastFile = nil
        }
        var lastDirectory = dict["last_directory"] as? String
        if let directory = lastDirectory, directory.isEmpty || !FileManager.default.fileExists(atPath: directory) {
            lastDirectory = nil
        }
        guard lastFile != nil || lastDirectory != nil else { return nil }
        return RestoreStateSnapshot(
            lastFile: lastFile,
            lastDirectory: lastDirectory,
            lastViewMode: dict["last_view_mode"] as? String ?? "thumbnail",
            lastMacOSSpaceMode: dict["last_macos_space_mode"] as? Bool
        )
    }

    /// Python `save_restore_state` — always marks restore enabled (same as Python).
    func saveRestoreState(
        filePath: String?,
        directory: String?,
        viewMode: String,
        macosSpaceMode: Bool?
    ) {
        var restore = restoreStateDict()
        restore["enabled"] = true
        if let filePath, !filePath.isEmpty {
            restore["last_file"] = filePath
        } else {
            restore["last_file"] = NSNull()
        }
        if let directory, !directory.isEmpty {
            restore["last_directory"] = directory
        } else {
            restore["last_directory"] = NSNull()
        }
        restore["last_view_mode"] = viewMode
        if let macosSpaceMode {
            restore["last_macos_space_mode"] = macosSpaceMode
        } else {
            restore["last_macos_space_mode"] = NSNull()
        }
        updateSetting("restore_state", value: restore)
        if let directory, !directory.isEmpty {
            mutateSettings { $0["last_directory"] = directory }
        }
    }

    /// Update last file/folder/view without changing the launch-restore toggle.
    func updateRestoreSnapshot(
        filePath: String?,
        directory: String?,
        viewMode: String,
        macosSpaceMode: Bool?
    ) {
        var restore = restoreStateDict()
        if let filePath, !filePath.isEmpty {
            restore["last_file"] = filePath
        } else {
            restore["last_file"] = NSNull()
        }
        if let directory, !directory.isEmpty {
            restore["last_directory"] = directory
        } else {
            restore["last_directory"] = NSNull()
        }
        restore["last_view_mode"] = viewMode
        if let macosSpaceMode {
            restore["last_macos_space_mode"] = macosSpaceMode
        }
        updateSetting("restore_state", value: restore)
        if let directory, !directory.isEmpty {
            mutateSettings { $0["last_directory"] = directory }
        }
    }

    func updateRestoreMacOSSpaceMode(_ enabled: Bool) {
        var restore = restoreStateDict()
        restore["last_macos_space_mode"] = enabled
        updateSetting("restore_state", value: restore)
    }

    func clearRestoreState() {
        var restore = restoreStateDict()
        restore["enabled"] = true
        restore["last_file"] = NSNull()
        restore["last_directory"] = NSNull()
        restore["last_view_mode"] = "thumbnail"
        restore["last_macos_space_mode"] = NSNull()
        updateSetting("restore_state", value: restore)
    }
    var imageExtensions: [String] {
        let raw: [String]
        let stored = readSettings()
        if let list = stored["image_extensions"] as? [String], !list.isEmpty {
            raw = list
        } else {
            raw = Self.defaultImageExtensions
        }
        let normalized = raw.map { Self.normalizeExtension($0) }
        let supported = Set(ThemeDefaults.knownExtensionList)
        let filtered = normalized.filter { supported.contains($0) }
        return filtered.isEmpty ? Self.defaultImageExtensions : filtered
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
        settingsDraft = nil
        settingsSnapshot = nil
        migrateRestoreStateIfNeeded()
        mergeMissingDefaults()
    }

    func beginSettingsSession() {
        guard settingsDraft == nil else { return }
        settingsSnapshot = Self.deepCopySettings(settings)
        settingsDraft = Self.deepCopySettings(settings)
    }

    /// ⌘I thumbnail overlay keys — always written to disk immediately (Python `update_setting` on cycle).
    func setThumbnailOverlayDisplaySettings(filenameVisible: Bool, showImageSize: Bool) {
        settings["thumbnail_filename_visible"] = filenameVisible
        settings["show_image_size"] = showImageSize
        if var draft = settingsDraft {
            draft["thumbnail_filename_visible"] = filenameVisible
            draft["show_image_size"] = showImageSize
            settingsDraft = draft
        }
        if var snap = settingsSnapshot {
            snap["thumbnail_filename_visible"] = filenameVisible
            snap["show_image_size"] = showImageSize
            settingsSnapshot = snap
        }
        saveSettings()
    }

    func commitSettingsSession() {
        guard let draft = settingsDraft else { return }
        settings = Self.deepCopySettings(draft)
        settingsDraft = nil
        settingsSnapshot = nil
        saveSettings()
    }

    func cancelSettingsSession() {
        defer {
            settingsDraft = nil
            settingsSnapshot = nil
        }
        guard let snap = settingsSnapshot else { return }
        settings = Self.deepCopySettings(snap)
        saveSettings()
    }

    func saveSettings() {
        mergeMissingDefaults()
        var toWrite = settings
        toWrite.removeValue(forKey: "debug_mode")
        guard JSONSerialization.isValidJSONObject(toWrite),
              let data = try? JSONSerialization.data(withJSONObject: toWrite, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: paths.settingsFile, options: .atomic)
    }

    func updateSetting(_ key: String, value: Any?) {
        if key == "debug_mode" {
            let wasEnabled = sessionDebugEnabled
            sessionDebugEnabled = value as? Bool ?? false
            if sessionDebugEnabled, !wasEnabled {
                appendDebugModeEnabledSessionLine()
            }
            return
        }
        mutateSettings { storage in
            if let value {
                storage[key] = value
            } else {
                storage.removeValue(forKey: key)
            }
        }
    }

    func setValue(_ value: Any, forKey key: String) {
        if key == "debug_mode" {
            let wasEnabled = sessionDebugEnabled
            sessionDebugEnabled = value as? Bool ?? false
            if sessionDebugEnabled, !wasEnabled {
                appendDebugModeEnabledSessionLine()
            }
            return
        }
        mutateSettings { storage in
            storage[key] = value
        }
    }

    /// Writes multiple keys then saves once when not in a settings session.
    func replaceSettingsValues(_ values: [String: Any], keys: [String]) {
        mutateSettings { storage in
            for key in keys {
                if let value = values[key] {
                    storage[key] = value
                }
            }
        }
    }

    func rawSettings() -> [String: Any] { readSettings() }

    func getSavedFilters() -> [String] {
        let filters = readSettings()["saved_filters"] as? [String] ?? []
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
        if key == "debug_mode" { return sessionDebugEnabled }
        return boolValue(key, default: defaultValue)
    }

    /// Console output for `--debug` / Settings → Debug mode.
    func debugLog(_ message: String) {
        guard bool(forKey: "debug_mode") else { return }
        let line = "\(SessionViewLog.debugTimestamp()) \(message)"
        SessionViewLog.appendLine(line, logFileURL: sessionViewLogFileURL)
        NSLog("%@", message)
    }

    /// Path for Tools → Debug → View log (⌃-L).
    var sessionViewLogFileURL: URL {
        if let boundSessionViewLogURL { return boundSessionViewLogURL }
        return SessionViewLog.logFileURL(config: self)
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

    /// Active search-model download folder (user override or `ImageRecognitionDownloadDefaults.defaultBaseURL`).
    func imageRecognitionModelDownloadBaseURL() -> String {
        let raw = string(forKey: ImageRecognitionDownloadDefaults.settingsOverrideKey, default: "")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        }
        return ImageRecognitionDownloadDefaults.defaultBaseURL
    }

    func clearImageRecognitionModelDownloadBaseURLOverride() {
        updateSetting(ImageRecognitionDownloadDefaults.settingsOverrideKey, value: nil)
    }

    var imageRecognitionModelDownloadBaseURLOverride: String? {
        let raw = string(forKey: ImageRecognitionDownloadDefaults.settingsOverrideKey, default: "")
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func stringArray(forKey key: String) -> [String] {
        (readSettings()[key] as? [String]) ?? []
    }

    func optionalStringArray(forKey key: String, count: Int) -> [String?] {
        let raw = readSettings()[key] as? [Any] ?? []
        return (0..<count).map { index in
            guard index < raw.count else { return nil }
            if raw[index] is NSNull { return nil }
            return raw[index] as? String
        }
    }

    func setOptionalStringArray(_ key: String, values: [String?]) {
        mutateSettings { storage in
            storage[key] = values.map { $0 as Any? ?? NSNull() }
        }
    }

    func rootDirectories() -> [String] {
        let raw = readSettings()["root_directories"] as? [String]
        return raw?.isEmpty == false ? raw! : ThemeDefaults.defaultRootDirectories
    }

    /// Top-level `/` entries offered as toggles on the Directories tab (not user-added custom paths).
    static func filesystemRootDirectoryPaths() -> [String] {
        let excluded: Set<String> = [
            ".nofollow", ".resolve", ".vol", ".Trashes", ".fseventsd",
            ".Spotlight-V100", ".DocumentRevisions-V100", ".MobileBackups",
            ".PKInstallSandboxManager-SystemSoftware", ".file",
        ]
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/") else { return [] }
        return entries
            .filter { entry in
                var isDir: ObjCBool = false
                let path = "/\(entry)"
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
                    && isDir.boolValue
                    && !excluded.contains(entry)
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { "/\($0)" }
    }

    static func standardizedRootDirectoryPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    /// User-added custom roots first, then standard `/` toggles; drops duplicate paths (by standardized path).
    static func orderRootDirectoriesForFileTree(_ paths: [String]) -> [String] {
        let filesystemRoots = Set(filesystemRootDirectoryPaths().map { standardizedRootDirectoryPath($0) })
        var seen = Set<String>()
        var custom: [String] = []
        var standard: [String] = []
        for path in paths {
            let normalized = standardizedRootDirectoryPath(path)
            guard seen.insert(normalized).inserted else { continue }
            if filesystemRoots.contains(normalized) {
                standard.append(path)
            } else {
                custom.append(path)
            }
        }
        custom.sort { comparePathsForFileTreeSort($0, $1) }
        standard.sort { comparePathsForFileTreeSort($0, $1) }
        return custom + standard
    }

    static func caseInsensitiveFileTreeName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    static func comparePathsForFileTreeSort(_ lhs: String, _ rhs: String) -> Bool {
        caseInsensitiveFileTreeName(lhs).localizedCaseInsensitiveCompare(caseInsensitiveFileTreeName(rhs)) == .orderedAscending
    }

    /// True for top-level `/` toggles on the Directories tab (not user-added custom paths).
    static func isFilesystemRootTogglePath(_ path: String) -> Bool {
        let filesystemRoots = Set(filesystemRootDirectoryPaths().map { standardizedRootDirectoryPath($0) })
        return filesystemRoots.contains(standardizedRootDirectoryPath(path))
    }

    func rootDirectoriesForFileTree() -> [String] {
        Self.orderRootDirectoriesForFileTree(rootDirectories())
    }

    /// Settings keys that affect file tree roots, filtering, or image discovery (Python `tree_settings_changed` + filters/extensions).
    static let treeRelatedSettingsKeys: [String] = [
        "root_directories",
        "show_hidden_directories",
        "always_show_work",
        "follow_symlinks",
        "ignore_directories",
        "search_depth",
        "shift_cmd_depth",
        "filter_pattern",
        "filtered_tree",
        "image_extensions",
    ]

    /// True when any tree-related value differs between session open and current draft (call before commit).
    func treeRelatedSettingsChangedInCurrentSession() -> Bool {
        guard let snap = settingsSnapshot, let draft = settingsDraft else { return false }
        for key in Self.treeRelatedSettingsKeys {
            if !Self.settingsValuesEqual(snap[key], draft[key]) { return true }
        }
        return false
    }

    static func settingsValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        if lhs == nil && rhs == nil { return true }
        if lhs == nil || rhs == nil { return false }
        guard let leftData = settingsValueFingerprint(lhs),
              let rightData = settingsValueFingerprint(rhs) else {
            return String(describing: lhs!) == String(describing: rhs!)
        }
        return leftData == rightData
    }

    private static func settingsValueFingerprint(_ value: Any?) -> Data? {
        guard let value else { return Data([0x00]) }
        guard JSONSerialization.isValidJSONObject(["v": value]) else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["v": value], options: [.sortedKeys])
    }

    func favoriteDirectories() -> [String?] {
        optionalStringArray(forKey: "favorite_directories", count: 9)
    }

    func moveDestinations() -> [String?] {
        optionalStringArray(forKey: "move_destinations", count: 9)
    }

    /// Recent directories for File → Recent (most recent last in storage; returned newest-first).
    func recentDirectories(limit: Int = 15) -> [String] {
        let raw = readSettings()["directory_menu_history"] as? [String] ?? []
        return Array(raw.reversed().prefix(limit))
    }

    func recordRecentDirectory(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = readSettings()["directory_menu_history"] as? [String] ?? []
        history.removeAll { $0 == trimmed }
        history.append(trimmed)
        let maxSize = 20
        if history.count > maxSize {
            history.removeFirst(history.count - maxSize)
        }
        updateSetting("directory_menu_history", value: history)
    }

    func excludeDirectories() -> [[String: Any]] {
        readSettings()["exclude_directories"] as? [[String: Any]] ?? []
    }

    func setExcludeDirectories(_ entries: [[String: Any]]) {
        mutateSettings { $0["exclude_directories"] = entries }
    }

    func sectionExpanded(_ key: String) -> Bool {
        let defaults = Self.defaultInformationSectionExpanded
        guard let saved = readSettings()["information_section_expanded"] as? [String: Bool] else {
            return defaults[key] ?? true
        }
        return saved[key] ?? defaults[key] ?? true
    }

    func setSectionExpanded(_ key: String, expanded: Bool) {
        guard Self.defaultInformationSectionExpanded.keys.contains(key) else { return }
        var state = (readSettings()["information_section_expanded"] as? [String: Bool]) ?? Self.defaultInformationSectionExpanded
        guard state[key] != expanded else { return }
        state[key] = expanded
        updateSetting("information_section_expanded", value: state)
    }

    func allSectionKeys() -> [String] {
        Array(Self.defaultInformationSectionExpanded.keys).sorted()
    }

    static let defaultInformationSectionExpanded: [String: Bool] = [
        "filename": true,
        "references": true,
        "image_model": true,
        "prompt": true,
        "title": true,
        "description": true,
        "negative_prompt": true,
        "input_to_active_job": true,
        "output_of_active_job": true,
    ]

    func applySettingsChange(emit: AppEventBus) {
        guard !isSettingsSessionActive else { return }
        emit.emit(.settingsChanged)
    }

    /// Collapsible section expanded flags for a settings tab (single dictionary read).
    func settingsGroupsExpanded(storageKey: String) -> [String: Bool] {
        readSettings()[storageKey] as? [String: Bool] ?? [:]
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
            settings["restore_state"] = [
                "enabled": true,
                "last_file": NSNull(),
                "last_directory": settings["last_directory"] as Any? ?? NSNull(),
                "last_view_mode": "thumbnail",
                "last_macos_space_mode": NSNull(),
            ]
        }
        if var dict = settings["restore_state"] as? [String: Any] {
            dict["enabled"] = true
            settings["restore_state"] = dict
        }
    }

    private func restoreStateDict() -> [String: Any] {
        let stored = readSettings()
        if let dict = stored["restore_state"] as? [String: Any] {
            return dict
        }
        if let enabled = stored["restore_state"] as? Bool {
            return ["enabled": enabled]
        }
        return ["enabled": true]
    }

    private func stringValue(_ key: String) -> String? {
        readSettings()[key] as? String
    }

    private func boolValue(_ key: String, default defaultValue: Bool) -> Bool {
        if let value = readSettings()[key] as? Bool { return value }
        return defaultValue
    }

    private func numberValue(_ key: String, default defaultValue: Double) -> Double {
        if let value = readSettings()[key] as? Double { return value }
        if let value = readSettings()[key] as? Int { return Double(value) }
        return defaultValue
    }

    private func readSettings() -> [String: Any] {
        settingsDraft ?? settings
    }

    private func mutateSettings(_ mutate: (inout [String: Any]) -> Void) {
        if var draft = settingsDraft {
            mutate(&draft)
            draft.removeValue(forKey: "debug_mode")
            settingsDraft = draft
            return
        }
        mutate(&settings)
        settings.removeValue(forKey: "debug_mode")
        saveSettings()
    }

    private static func deepCopySettings(_ source: [String: Any]) -> [String: Any] {
        guard JSONSerialization.isValidJSONObject(source),
              let data = try? JSONSerialization.data(withJSONObject: source),
              let copy = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return source
        }
        return copy
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
            "information_section_expanded": defaultInformationSectionExpanded,
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
            "browse_zoom_sharpen": false,
            "browse_preserve_zoom_on_image_change": false,
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
            "image_editor_app": "Preview",
            "raise_status_bar_on_cursor_near_bottom": true,
            "similarity_metric": "cosine",
            "resnet_model": "resnet18",
            "clip_model_name": "openai/clip-vit-base-patch32",
            "clip_similarity_threshold": 0.20,
            "clip_prompt": "",
            "clip_recursive": false,
            "cnn_recursive": false,
            "cnn_search_dir_enabled": false,
            "cnn_search_dir": "",
            "clip_search_dir_enabled": false,
            "clip_search_dir": "",
            "cnn_feature_batch_size": 16,
            "caption_lms_host": "localhost:1234",
            "caption_system_prompt": "Analyze the provided image thoroughly and write a highly detailed, visually rich, {CAPTION_WORD_COUNT}-word caption.",
            "caption_user_prompt": "Carefully study the attached image and provide a comprehensive, vivid, and nuanced {CAPTION_WORD_COUNT}-word caption.",
            "caption_max_words": 200,
            "caption_temperature": 0.7,
            "caption_last_lm_model_key": "",
            "edit_exif_usercomment_instructions": "",
            "edit_exif_usercomment_instructions_visible": false,
            "imagegen_lora_model_key": "",
            "slideshow2_enlargement": 1.2,
            "slideshow2_speed": 8,
            "slideshow2_high_quality_scaling": false,
            "slideshow3_speed": 1,
            "list_view_row_height": 48,
            "list_view_column_order": "thumbnail,name,ext,date,size,dimensions,permissions,comments",
            "list_view_hidden_columns": "comments,ext",
            "background_clip_enabled": false,
            "background_clip_gather_thumbnails": true,
            "background_clip_extract_faces": false,
            "shift_cmd_depth": 4,
            "search_depth": 4,
            "image_creation_directory": ["path": NSNull(), "enabled": false] as [String: Any],
            "temporary_files_directory": NSNull(),
            "ignore_directories": [
                ["path": NSNull(), "enabled": false],
                ["path": NSNull(), "enabled": false],
                ["path": NSNull(), "enabled": false],
            ],
            "drag_drop_auto_date_change": false,
            "allow_thumbnail_locking": false,
            "allow_quick_mass_rename": false,
            "destination_menu_action": "move",
            "slideshow_overlap_percent": 100,
            "imagegen_max_generation_dimension": 1024,
            "imagegen_job_cooldown_seconds": 0,
            "imagegen_inter_copy_cooldown_seconds": 23,
            "imagegen_add_chat_prefix_postfix": true,
            "imagegen_fast_open_action": "from_text",
            "imagegen_output_format": "png",
            "imagegen_low_ram": true,
            "imagegen_include_triggers_in_exif": false,
            "imagegen_unload_models_when_queue_held": false,
            "use_prompt_filter_exits": false,
            "text_ai_exit": "",
            "image_ai_exit": "",
            "general_settings_groups_expanded": [
                "general": true,
                "thumbnails": true,
                "image_viewing": true,
                "image_generation": true,
            ] as [String: Bool],
            "directories_settings_groups_expanded": [
                "root_directories": true,
                "scanning_options": true,
                "depth": true,
                "image_creation_temp_files": true,
                "ignore_directories": true,
            ] as [String: Bool],
        ]
    }

    func ignoreDirectories() -> [[String: Any]] {
        let raw = readSettings()["ignore_directories"] as? [[String: Any]] ?? []
        if raw.count >= 3 { return Array(raw.prefix(3)) }
        var padded = raw
        while padded.count < 3 {
            padded.append(["path": NSNull(), "enabled": false])
        }
        return padded
    }

    func setIgnoreDirectories(_ entries: [[String: Any]]) {
        mutateSettings { $0["ignore_directories"] = entries }
    }

    func imageCreationDirectory() -> (path: String?, enabled: Bool) {
        guard let dict = readSettings()["image_creation_directory"] as? [String: Any] else {
            return (nil, false)
        }
        let path = dict["path"] as? String
        let enabled = dict["enabled"] as? Bool ?? false
        return (path, enabled)
    }

    func setImageCreationDirectory(path: String?, enabled: Bool) {
        mutateSettings {
            $0["image_creation_directory"] = [
                "path": path as Any? ?? NSNull(),
                "enabled": enabled,
            ]
        }
    }

    func temporaryFilesDirectoryRaw() -> String? {
        let stored = readSettings()
        if stored["temporary_files_directory"] is NSNull { return nil }
        let value = stored["temporary_files_directory"] as? String
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
    }

    func setTemporaryFilesDirectory(_ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        mutateSettings {
            $0["temporary_files_directory"] = trimmed.isEmpty ? NSNull() : trimmed
        }
        ProwserTempFiles.invalidateCache()
    }

    func settingsGroupExpanded(storageKey: String, groupKey: String, default defaultValue: Bool = true) -> Bool {
        guard let dict = readSettings()[storageKey] as? [String: Bool] else { return defaultValue }
        return dict[groupKey] ?? defaultValue
    }

    func setSettingsGroupExpanded(storageKey: String, groupKey: String, expanded: Bool) {
        mutateSettings { storage in
            var dict = storage[storageKey] as? [String: Bool] ?? [:]
            dict[groupKey] = expanded
            storage[storageKey] = dict
        }
    }

    func splitterSizes(forKey key: String, default defaultValue: [CGFloat]) -> [CGFloat] {
        guard let raw = rawSettings()[key] as? [Any], raw.count == 3 else { return defaultValue }
        let sizes = raw.compactMap { value -> CGFloat? in
            if let intValue = value as? Int { return CGFloat(intValue) }
            if let doubleValue = value as? Double { return CGFloat(doubleValue) }
            return nil
        }
        guard sizes.count == 3, sizes.reduce(0, +) > 0 else { return defaultValue }
        return sizes
    }

    func saveSplitterSizes(_ key: String, sizes: [CGFloat]) {
        let ints = sizes.map { Int(round($0)) }
        updateSetting(key, value: ints)
    }
}
