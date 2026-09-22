import SwiftUI

@MainActor
struct DirectoriesSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var rootDirectories: [String] = []
    @State private var newRootPath = ""
    @State private var temporaryFilesPath = ""
    @State private var ignoreEntries: [IgnoreEntry] = IgnoreEntry.defaults()
    @State private var rootExpanded = true
    @State private var scanningExpanded = true
    @State private var depthExpanded = true
    @State private var filesExpanded = true
    @State private var ignoreExpanded = true

    struct IgnoreEntry: Identifiable {
        let id = UUID()
        var enabled: Bool
        var path: String

        static func defaults() -> [IgnoreEntry] {
            (0..<3).map { _ in IgnoreEntry(enabled: false, path: "") }
        }
    }

    /// Top-level directories under `/` for root toggles (refreshed from the filesystem in `load()`).
    @State private var filesystemRootDirectories: [String] = []

    /// Column count that keeps row heights as equal as possible (matches Python settings grid: 3 or 4 columns).
    private static func rootDirectoryGridColumnCount(itemCount: Int) -> Int {
        guard itemCount > 0 else { return 1 }
        let rowsWith3 = (itemCount + 2) / 3
        let rowsWith4 = (itemCount + 3) / 4
        return rowsWith4 <= rowsWith3 ? 4 : 3
    }

    /// Distribute `paths` in column-major order (fill each column top-to-bottom, then next column).
    private static func columnMajorColumns(paths: [String], columnCount: Int) -> [[String]] {
        let count = paths.count
        guard count > 0 else { return [] }
        let cols = max(1, columnCount)
        let rowCount = (count + cols - 1) / cols
        return (0..<cols).map { col in
            (0..<rowCount).compactMap { row -> String? in
                let index = col * rowCount + row
                return index < count ? paths[index] : nil
            }
        }
    }

    private var defaultTempPath: String {
        ProwserTempFiles.displayPath(
            ProwserTempFiles.defaultTemporaryFilesDirectory(prowserHome: appState.config.prowserHome)
        )
    }

    var body: some View {
        SettingsCollapsibleTabLayout(
            onExpandAll: { setAllGroupsExpanded(true) },
            onCollapseAll: { setAllGroupsExpanded(false) }
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Directories").font(.title2)

                CollapsibleSettingsSection(title: "Root Directories", stateKey: "root_directories", isExpanded: $rootExpanded) {
                    Text("Directories shown at the top of the file tree.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    rootDirectoriesToggleGrid

                    HStack {
                        SettingsPathTextField(title: "Custom path", text: $newRootPath)
                        Button("Add") {
                            let expanded = SettingsPathValidation.expandedPath(newRootPath)
                            guard !expanded.isEmpty, !rootDirectories.contains(expanded) else { return }
                            rootDirectories.append(expanded)
                            newRootPath = ""
                            persistRoots()
                        }
                    }

                    ForEach(rootDirectories.filter { !filesystemRootDirectories.contains($0) }, id: \.self) { path in
                        HStack {
                            Text(SettingsPathValidation.displayPath(path))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Remove") {
                                rootDirectories.removeAll { $0 == path }
                                persistRoots()
                            }
                        }
                    }
                }

                CollapsibleSettingsSection(title: "Scanning Options", stateKey: "scanning_options", isExpanded: $scanningExpanded) {
                    SettingsPreferencePanel {
                        SettingsPreferenceToggleRow(
                            title: "Process hidden directories",
                            subtitle: "Process hidden directories in searches and other operations.",
                            tooltip: "Process directories starting with a period in searches and file operations.",
                            isOn: boolBinding("show_hidden_directories")
                        )
                        SettingsPreferenceToggleRow(
                            title: "Always show directories that start with 'work'",
                            subtitle: "Show an empty directories in tree starting with 'work'.",
                            tooltip: "Always show directories that start with 'work...' in the file tree.",
                            isOn: boolBinding("always_show_work")
                        )
                        SettingsPreferenceToggleRow(
                            title: "Follow symlinks",
                            subtitle: "Including system volumes",
                            tooltip: "Follow symbolic and hard links when scanning directories in the tree view.",
                            isOn: boolBinding("follow_symlinks")
                        )
                    }
                }

                CollapsibleSettingsSection(title: "Directory Search Depths", stateKey: "depth", isExpanded: $depthExpanded) {
                    SettingsPreferencePanel {
                        depthStepper(title: "⇧⌘↩ depth", key: "shift_cmd_depth", defaultValue: 4)
                        depthStepper(title: "Search depth", key: "search_depth", defaultValue: 4)
                    }
                }

                CollapsibleSettingsSection(
                    title: "Temporary Files",
                    stateKey: "image_creation_temp_files",
                    isExpanded: $filesExpanded
                ) {

                    HStack {
                        SettingsPathTextField(
                            title: "Temporary files",
                            text: $temporaryFilesPath,
                            prompt: Text("Default: \(defaultTempPath)"),
                            onCommit: persistTemporaryFiles
                        )
                        Button("Choose…") {
                            SettingsSupport.pickDirectory(into: $temporaryFilesPath)
                            persistTemporaryFiles()
                        }
                    }
                    Text("Work files for wallpaper, convert, resize, and similar operations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                CollapsibleSettingsSection(title: "Ignore Directories", stateKey: "ignore_directories", isExpanded: $ignoreExpanded) {
                    ForEach($ignoreEntries) { entry in
                        HStack {
                            SettingsPreferenceSwitch(isOn: entry.enabled)
                                .onChange(of: entry.wrappedValue.enabled) { _, _ in persistIgnoreDirectories() }
                            SettingsPathTextField(
                                title: "Path",
                                text: entry.path,
                                onCommit: persistIgnoreDirectories
                            )
                            Button("Choose…") {
                                let index = ignoreEntries.firstIndex(where: { $0.id == entry.id })
                                guard let index else { return }
                                SettingsSupport.pickDirectory(into: Binding(
                                    get: { ignoreEntries[index].path },
                                    set: { ignoreEntries[index].path = $0; persistIgnoreDirectories() }
                                ))
                            }
                        }
                    }
                    Text("Skipped during scans and file operations when enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { load() }
        .onChange(of: rootExpanded) { _, value in
            appState.config.setSettingsGroupExpanded(storageKey: "directories_settings_groups_expanded", groupKey: "root_directories", expanded: value)
        }
        .onChange(of: scanningExpanded) { _, value in
            appState.config.setSettingsGroupExpanded(storageKey: "directories_settings_groups_expanded", groupKey: "scanning_options", expanded: value)
        }
        .onChange(of: depthExpanded) { _, value in
            appState.config.setSettingsGroupExpanded(storageKey: "directories_settings_groups_expanded", groupKey: "depth", expanded: value)
        }
        .onChange(of: filesExpanded) { _, value in
            appState.config.setSettingsGroupExpanded(storageKey: "directories_settings_groups_expanded", groupKey: "image_creation_temp_files", expanded: value)
        }
        .onChange(of: ignoreExpanded) { _, value in
            appState.config.setSettingsGroupExpanded(storageKey: "directories_settings_groups_expanded", groupKey: "ignore_directories", expanded: value)
        }
    }

    @ViewBuilder
    private var rootDirectoriesToggleGrid: some View {
        let columns = Self.columnMajorColumns(
            paths: filesystemRootDirectories,
            columnCount: Self.rootDirectoryGridColumnCount(itemCount: filesystemRootDirectories.count)
        )
        SettingsPreferenceCompactToggleColumnGrid(
            columns: columns,
            columnRowTitles: { ($0 as NSString).lastPathComponent }
        ) { path in
            rootDirectoryToggle(path: path)
        }
    }

    private func rootDirectoryToggle(path: String) -> some View {
        SettingsPreferenceCompactToggleRow(
            title: (path as NSString).lastPathComponent,
            tooltip: path,
            expandLabel: true,
            isOn: Binding(
                get: { rootDirectories.contains(path) },
                set: { enabled in
                    if enabled {
                        if !rootDirectories.contains(path) { rootDirectories.append(path) }
                    } else {
                        rootDirectories.removeAll { $0 == path }
                    }
                    persistRoots()
                }
            )
        )
    }

    private func setAllGroupsExpanded(_ expanded: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            rootExpanded = expanded
            scanningExpanded = expanded
            depthExpanded = expanded
            filesExpanded = expanded
            ignoreExpanded = expanded
        }
    }

    private func depthStepper(title: String, key: String, defaultValue: Int) -> some View {
        SettingsPreferenceFormRow(label: title) {
            Stepper(
                value: Binding(
                    get: { appState.config.int(forKey: key, default: defaultValue) },
                    set: { newValue in
                        appState.config.setValue(max(1, min(10, newValue)), forKey: key)
                        settingsChanged()
                    }
                ),
                in: 1...10
            ) {
                Text("\(appState.config.int(forKey: key, default: defaultValue))")
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsDialogChrome.rowTitle)
                    .monospacedDigit()
                    .frame(width: 24)
            }
        }
    }

    private func load() {
        filesystemRootDirectories = AppConfig.filesystemRootDirectoryPaths()
        rootDirectories = appState.config.rootDirectories()
        if let rawTemp = appState.config.temporaryFilesDirectoryRaw(), !rawTemp.isEmpty {
            temporaryFilesPath = SettingsPathValidation.displayPath(rawTemp)
        } else {
            temporaryFilesPath = ""
        }
        ignoreEntries = appState.config.ignoreDirectories().map { dict in
            let raw = dict["path"] as? String ?? ""
            return IgnoreEntry(
                enabled: dict["enabled"] as? Bool ?? false,
                path: raw.isEmpty ? "" : SettingsPathValidation.displayPath(raw)
            )
        }
        if ignoreEntries.count < 3 {
            ignoreEntries.append(contentsOf: IgnoreEntry.defaults().suffix(3 - ignoreEntries.count))
        }
        let groups = appState.config.settingsGroupsExpanded(storageKey: "directories_settings_groups_expanded")
        rootExpanded = groups["root_directories"] ?? true
        scanningExpanded = groups["scanning_options"] ?? true
        depthExpanded = groups["depth"] ?? true
        filesExpanded = groups["image_creation_temp_files"] ?? true
        ignoreExpanded = groups["ignore_directories"] ?? true
    }

    private func persistRoots() {
        appState.config.setValue(rootDirectories, forKey: "root_directories")
        settingsChanged()
    }

    private func persistTemporaryFiles() {
        let trimmed = temporaryFilesPath.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.config.setTemporaryFilesDirectory(
            trimmed.isEmpty ? nil : SettingsPathValidation.expandedPath(trimmed)
        )
        settingsChanged()
    }

    private func persistIgnoreDirectories() {
        let entries: [[String: Any]] = ignoreEntries.map { entry in
            let path = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                "path": path.isEmpty ? NSNull() : SettingsPathValidation.expandedPath(path),
                "enabled": entry.enabled,
            ] as [String: Any]
        }
        appState.config.setIgnoreDirectories(entries)
        settingsChanged()
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        SettingsSupport.boolBinding(config: appState.config, key: key, onChange: settingsChanged)
    }

    private func settingsChanged() {
        appState.config.applySettingsChange(emit: appState.eventBus)
    }
}
