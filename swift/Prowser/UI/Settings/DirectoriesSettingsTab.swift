import SwiftUI

@MainActor
struct DirectoriesSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var rootDirectories: [String] = []
    @State private var newRootPath = ""

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Directories").font(.title2)

                SettingsSection(title: "Root Directories") {
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

                SettingsSection(title: "Scanning Options") {
                    Toggle("Process hidden directories", isOn: boolBinding("show_hidden_directories"))
                    Toggle("Always show directories starting with 'work'", isOn: boolBinding("always_show_work"))
                    Toggle("Follow symlinks in tree", isOn: boolBinding("follow_symlinks"))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            rootDirectories = appState.config.rootDirectories()
        }
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        SettingsSupport.boolBinding(config: appState.config, key: key, onChange: settingsChanged)
    }

    private func persistRoots() {
        appState.config.setValue(rootDirectories, forKey: "root_directories")
        settingsChanged()
    }

    private func settingsChanged() {
        appState.config.applySettingsChange(emit: appState.eventBus)
    }
}
