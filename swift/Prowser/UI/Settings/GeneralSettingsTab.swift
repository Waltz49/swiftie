import SwiftUI

@MainActor
struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var filterDraft = ""
    @State private var generalExpanded = true
    @State private var thumbnailsExpanded = true
    @State private var imageViewingExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("General").font(.title2)

                CollapsibleSettingsSection(title: "Behavior", stateKey: "general", isExpanded: $generalExpanded) {
                    Toggle("Confirm delete (⌘Delete)", isOn: boolBinding("confirm_delete", default: true))
                    Toggle("Wrap around when navigating", isOn: boolBinding("wrap_around", default: true))
                    Toggle("Restore state on launch", isOn: restoreStateBinding)
                    Toggle("Debug mode", isOn: boolBinding("debug_mode"))
                    Toggle(
                        "Peek status bar when cursor nears bottom",
                        isOn: boolBinding("raise_status_bar_on_cursor_near_bottom", default: true)
                    )
                    Toggle("Use EXIF rotation", isOn: exifRotationBinding)
                    Toggle("Prefer EXIF date for sorting", isOn: boolBinding("use_exif_date", default: true))
                }

                CollapsibleSettingsSection(title: "Thumbnails", stateKey: "thumbnails", isExpanded: $thumbnailsExpanded) {
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

                    Toggle("Drag/drop changes dates when sorted by date", isOn: boolBinding("drag_drop_auto_date_change"))
                    Toggle("Allow thumbnail locking (⇧⌘L)", isOn: boolBinding("allow_thumbnail_locking"))
                    Toggle("Allow Quick Mass Rename (⇧⌘M)", isOn: boolBinding("allow_quick_mass_rename"))
                }

                CollapsibleSettingsSection(title: "Image Viewing", stateKey: "image_viewing", isExpanded: $imageViewingExpanded) {
                    Picker("Space Key", selection: stringBinding("space_key_mode", default: "exit")) {
                        Text("Exit to thumbnails").tag("exit")
                        Text("Show next image").tag("advance")
                    }
                    .pickerStyle(.radioGroup)
                    .frame(maxWidth: 360)

                    HStack {
                        Text("Remember image after")
                        Slider(
                            value: Binding(
                                get: { Double(historySliderIndex) },
                                set: { newValue in
                                    let ms = Int(newValue) * 500
                                    appState.config.setValue(ms, forKey: "browse_image_history_save_after_ms")
                                    settingsChanged()
                                }
                            ),
                            in: 0...10,
                            step: 1
                        )
                        Text(historyDelayLabel)
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }
                    Text("For Image History (F3)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            filterDraft = FilterPatternFormatting.forEditing(appState.filterSettings.filterPattern)
            let groups = appState.config.settingsGroupsExpanded(storageKey: "general_settings_groups_expanded")
            generalExpanded = groups["general"] ?? true
            thumbnailsExpanded = groups["thumbnails"] ?? true
            imageViewingExpanded = groups["image_viewing"] ?? true
        }
        .onChange(of: generalExpanded) { _, value in
            appState.config.setSettingsGroupExpanded(storageKey: "general_settings_groups_expanded", groupKey: "general", expanded: value)
        }
        .onChange(of: thumbnailsExpanded) { _, value in
            appState.config.setSettingsGroupExpanded(storageKey: "general_settings_groups_expanded", groupKey: "thumbnails", expanded: value)
        }
        .onChange(of: imageViewingExpanded) { _, value in
            appState.config.setSettingsGroupExpanded(storageKey: "general_settings_groups_expanded", groupKey: "image_viewing", expanded: value)
        }
    }

    private var historySliderIndex: Int {
        appState.config.int(forKey: "browse_image_history_save_after_ms", default: 3000) / 500
    }

    private var historyDelayLabel: String {
        let ms = appState.config.int(forKey: "browse_image_history_save_after_ms", default: 3000)
        if ms == 0 { return "Immediate" }
        return "\(ms) ms"
    }

    private var restoreStateBinding: Binding<Bool> {
        Binding(
            get: { appState.config.restoreState },
            set: { appState.config.setRestoreStateEnabled($0); settingsChanged() }
        )
    }

    private var exifRotationBinding: Binding<Bool> {
        Binding(
            get: { !appState.config.ignoreExifRotation },
            set: { useRotation in
                appState.config.setValue(!useRotation, forKey: "ignore_exif_rotation")
                Task {
                    await appState.thumbnailCache.updateExifSetting(ignore: !useRotation)
                }
                settingsChanged()
            }
        )
    }

    private func boolBinding(_ key: String, default defaultValue: Bool = false) -> Binding<Bool> {
        SettingsSupport.boolBinding(config: appState.config, key: key, default: defaultValue, onChange: settingsChanged)
    }

    private func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        SettingsSupport.stringBinding(config: appState.config, key: key, default: defaultValue, onChange: settingsChanged)
    }

    private func settingsChanged() {
        appState.config.applySettingsChange(emit: appState.eventBus)
        appState.theme.reload()
    }
}
