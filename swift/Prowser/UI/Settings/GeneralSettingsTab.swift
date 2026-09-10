import SwiftUI

@MainActor
struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var filterDraft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("General").font(.title2)

                SettingsSection(title: "Behavior") {
                    Toggle("Confirm delete (⌘Delete)", isOn: boolBinding("confirm_delete", default: true))
                    Toggle("Wrap around when navigating", isOn: boolBinding("wrap_around", default: true))
                    Toggle("Restore state on launch", isOn: boolBinding("restore_state", default: true))
                    Toggle("Debug mode", isOn: boolBinding("debug_mode"))
                }

                SettingsSection(title: "Images") {
                    Toggle("Use EXIF rotation", isOn: Binding(
                        get: { !appState.config.ignoreExifRotation },
                        set: { useRotation in
                            appState.config.setValue(!useRotation, forKey: "ignore_exif_rotation")
                            Task {
                                await appState.thumbnailCache.updateExifSetting(ignore: !useRotation)
                            }
                            settingsChanged()
                        }
                    ))
                    Toggle("Prefer EXIF date for sorting", isOn: boolBinding("use_exif_date", default: true))
                }

                SettingsSection(title: "Thumbnails") {
                    Toggle("Show filenames on thumbnails", isOn: boolBinding("thumbnail_filename_visible"))
                    Toggle("Show extensions in overlays", isOn: boolBinding("show_extensions", default: true))
                    Toggle("Show image dimensions in overlays", isOn: boolBinding("show_image_size"))

                    HStack {
                        TextField("Filter pattern", text: $filterDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                        Button("Apply Filter") {
                            appState.applyFilenameFilterPattern(filterDraft)
                            if let dir = appState.fileData.currentDirectory {
                                appState.loadDirectory(dir, saveHistory: false)
                            }
                        }
                    }
                    Text("Glob pattern for filenames (e.g. *.jpg, IMG_*).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            filterDraft = FilterPatternFormatting.forEditing(appState.filterSettings.filterPattern)
        }
    }

    private func boolBinding(_ key: String, default defaultValue: Bool = false) -> Binding<Bool> {
        SettingsSupport.boolBinding(config: appState.config, key: key, default: defaultValue, onChange: settingsChanged)
    }

    private func settingsChanged() {
        appState.config.applySettingsChange(emit: appState.eventBus)
        appState.theme.reload()
    }
}
