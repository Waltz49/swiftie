import SwiftUI

@MainActor
struct DirectoriesSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var rootDirectories: [String] = []
    @State private var newRootPath = ""
    @State private var imageCreationEnabled = false
    @State private var imageCreationPath = ""
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

    private let commonRoots: [String] = {
        let fm = FileManager.default
        let excluded: Set<String> = [
            ".nofollow", ".resolve", ".vol", ".Trashes", ".fseventsd", "cores",
            ".Spotlight-V100", ".DocumentRevisions-V100", ".MobileBackups",
        ]
        guard let entries = try? fm.contentsOfDirectory(atPath: "/") else { return [] }
        return entries
            .filter { entry in
                var isDir: ObjCBool = false
                let path = "/\(entry)"
                return fm.fileExists(atPath: path, isDirectory: &isDir)
                    && isDir.boolValue
                    && !excluded.contains(entry)
            }
            .sorted()
            .map { "/\($0)" }
    }()

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

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading) {
                        ForEach(commonRoots, id: \.self) { path in
                            Toggle((path as NSString).lastPathComponent, isOn: Binding(
                                get: { rootDirectories.contains(path) },
                                set: { enabled in
                                    if enabled {
                                        if !rootDirectories.contains(path) { rootDirectories.append(path) }
                                    } else {
                                        rootDirectories.removeAll { $0 == path }
                                    }
                                    persistRoots()
                                }
                            ))
                        }
                    }

                    HStack {
                        TextField("Custom path", text: $newRootPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            let expanded = (newRootPath as NSString).expandingTildeInPath
                            guard !expanded.isEmpty, !rootDirectories.contains(expanded) else { return }
                            rootDirectories.append(expanded)
                            newRootPath = ""
                            persistRoots()
                        }
                    }

                    ForEach(rootDirectories.filter { !commonRoots.contains($0) }, id: \.self) { path in
                        HStack {
                            Text(path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Remove") {
                                rootDirectories.removeAll { $0 == path }
                                persistRoots()
                            }
                        }
                    }
                }

                CollapsibleSettingsSection(title: "Scanning Options", stateKey: "scanning_options", isExpanded: $scanningExpanded) {
                    Toggle("Process hidden directories", isOn: boolBinding("show_hidden_directories"))
                    Toggle("Always show directories starting with 'work'", isOn: boolBinding("always_show_work"))
                    Toggle("Follow symlinks in tree", isOn: boolBinding("follow_symlinks"))
                }

                CollapsibleSettingsSection(title: "Directory Search Depths", stateKey: "depth", isExpanded: $depthExpanded) {
                    depthStepper(title: "⇧⌘↩ depth", key: "shift_cmd_depth", defaultValue: 4)
                    depthStepper(title: "Search depth", key: "search_depth", defaultValue: 4)
                }

                CollapsibleSettingsSection(
                    title: "Temporary Files",
                    stateKey: "image_creation_temp_files",
                    isExpanded: $filesExpanded
                ) {

                    HStack {
                        TextField("Temporary files", text: $temporaryFilesPath, prompt: Text("Default: \(defaultTempPath)"))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { persistTemporaryFiles() }
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
                            Toggle("", isOn: entry.enabled)
                                .labelsHidden()
                                .onChange(of: entry.wrappedValue.enabled) { _, _ in persistIgnoreDirectories() }
                            TextField("Path", text: entry.path)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { persistIgnoreDirectories() }
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
        HStack {
            Text(title)
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
                    .monospacedDigit()
                    .frame(width: 24)
            }
        }
    }

    private func load() {
        rootDirectories = appState.config.rootDirectories()
        let imageCreation = appState.config.imageCreationDirectory()
        imageCreationEnabled = imageCreation.enabled
        imageCreationPath = imageCreation.path ?? ""
        temporaryFilesPath = appState.config.temporaryFilesDirectoryRaw() ?? ""
        ignoreEntries = appState.config.ignoreDirectories().map { dict in
            IgnoreEntry(
                enabled: dict["enabled"] as? Bool ?? false,
                path: dict["path"] as? String ?? ""
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

    private func persistImageCreation() {
        let path = imageCreationPath.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.config.setImageCreationDirectory(
            path: path.isEmpty ? nil : (path as NSString).expandingTildeInPath,
            enabled: imageCreationEnabled
        )
        settingsChanged()
    }

    private func persistTemporaryFiles() {
        let trimmed = temporaryFilesPath.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.config.setTemporaryFilesDirectory(trimmed.isEmpty ? nil : (trimmed as NSString).expandingTildeInPath)
        settingsChanged()
    }

    private func persistIgnoreDirectories() {
        let entries: [[String: Any]] = ignoreEntries.map { entry in
            let path = entry.path.trimmingCharacters(in: .whitespacesAndNewlines)
            return [
                "path": path.isEmpty ? NSNull() : (path as NSString).expandingTildeInPath,
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
