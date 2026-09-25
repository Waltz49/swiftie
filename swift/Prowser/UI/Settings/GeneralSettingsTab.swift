import SwiftUI

@MainActor
struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var filterDraft = ""
    @State private var generalExpanded = true
    @State private var thumbnailsExpanded = true
    @State private var imageViewingExpanded = true

    var body: some View {
        SettingsCollapsibleTabLayout(
            onExpandAll: { setAllGroupsExpanded(true) },
            onCollapseAll: { setAllGroupsExpanded(false) }
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Text("General").font(.title2)

                CollapsibleSettingsSection(title: "Behavior", stateKey: "general", isExpanded: $generalExpanded) {
                    SettingsPreferencePanel {
                        SettingsPreferenceToggleRow(
                            title: "Delete confirmation on ⌘-Delete",
                            subtitle: "Show confirmation dialog when deleting files with ⌘-Delete.",
                            tooltip: "Show confirmation dialog when deleting files.",
                            isOn: boolBinding("confirm_delete", default: true)
                        )
                        SettingsPreferenceToggleRow(
                            title: "Wrap around",
                            subtitle: "Allow cursor navigation to wrap from end to beginning.",
                            tooltip: "Allow navigation to wrap from end to beginning and vice versa.",
                            isOn: boolBinding("wrap_around", default: true)
                        )
                        SettingsPreferenceToggleRow(
                            title: "Raise status bar when cursor nears bottom",
                            subtitle: "When off, a hidden status bar stays hidden near the bottom edge.",
                            tooltip: "When the status bar is hidden, move the cursor near the bottom edge of the window to temporarily show it.",
                            isOn: boolBinding("raise_status_bar_on_cursor_near_bottom", default: true)
                        )
                        SettingsPreferenceToggleRow(
                            title: "Debug mode (⇧-⌘-D)",
                            subtitle: "Enter debug mode. Meaning varies. Use ⌃-L to view log.",
                            tooltip: "Show key popup overlay for debugging keyboard events.",
                            isOn: boolBinding("debug_mode")
                        )
                    }
                }

                CollapsibleSettingsSection(title: "Thumbnails", stateKey: "thumbnails", isExpanded: $thumbnailsExpanded) {
                    SettingsPreferencePanel {
                        SettingsPreferenceFormRow(
                            label: "Filter Pattern",
                            subtitle: "Glob pattern for filenames (e.g. *.jpg, IMG_*).",
                            tooltip: "Filter images by filename using glob patterns."
                        ) {
                            VStack(alignment: .trailing, spacing: 4) {
                                HStack {
                                    TextField("Filter pattern", text: $filterDraft)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 180)
                                    Button("Apply") {
                                        appState.applyFilenameFilterPattern(filterDraft)
                                        if let dir = appState.fileData.currentDirectory {
                                            appState.loadDirectory(dir, saveHistory: false)
                                        }
                                    }
                                }
                            }
                        }
                        SettingsPreferenceToggleRow(
                            title: "Show filenames on thumbnails",
                            isOn: boolBinding("thumbnail_filename_visible")
                        )
                        SettingsPreferenceToggleRow(
                            title: "Always show file extensions (cycle with ⌘-I)",
                            subtitle: "Use ⌘-I to cycle display of names, etc.",
                            tooltip: "Always show file extensions on file names.",
                            isOn: boolBinding("show_extensions", default: true)
                        )
                        SettingsPreferenceToggleRow(
                            title: "Show image dimensions in overlays",
                            isOn: boolBinding("show_image_size")
                        )
                        SettingsPreferenceToggleRow(
                            title: "Drag/drop changes dates when sorted by date",
                            subtitle: "Changes file date when dragging to maintain sort order by date.",
                            tooltip: "When sorted by date, moving icons in thumbnail view automatically adjusts file dates.",
                            isOn: boolBinding("drag_drop_auto_date_change")
                        )
                        SettingsPreferenceToggleRow(
                            title: "Prefer EXIF date for sorting",
                            isOn: boolBinding("use_exif_date", default: true)
                        )
                        SettingsPreferenceToggleRow(
                            title: "Allow thumbnail locking (⇧-⌘-L) - Experimental",
                            subtitle: "Experimental. Locks thumbnail positions in order.",
                            tooltip: "Allow marking thumbnails as locked to keep them in place while organizing images.",
                            isOn: boolBinding("allow_thumbnail_locking")
                        )
                        SettingsPreferenceToggleRow(
                            title: "Allow Quick Mass Rename (⇧-⌘-M)",
                            subtitle: "Warning: This can rename large numbers of files without confirmation.",
                            tooltip: "Allow Quick rename. This can rename large numbers of files without confirmation.",
                            isOn: boolBinding("allow_quick_mass_rename")
                        )
                    }
                }

                CollapsibleSettingsSection(title: "Image Viewing", stateKey: "image_viewing", isExpanded: $imageViewingExpanded) {
                    SettingsPreferencePanel {
                        SettingsPreferenceFormRow(
                            label: "Space Key",
                            subtitle: "Use ⇧-Space in browse to toggle show next image/exit browse.",
                            tooltip: "Default behavior for the space key in browse mode."
                        ) {
                            Picker("", selection: stringBinding("space_key_mode", default: "exit")) {
                                Text("Exit to thumbnails").tag("exit")
                                Text("Show next image").tag("advance")
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        }
                        SettingsPreferenceFormRow(
                            label: "Remember image after",
                            subtitle: "For Image History (F3)",
                            tooltip: "After this time, the current image is added to Image History that you can see by pressing F3."
                        ) {
                            HStack {
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
                                .frame(minWidth: 160)
                                Text(historyDelayLabel)
                                    .monospacedDigit()
                                    .frame(width: 72, alignment: .trailing)
                            }
                        }
                        SettingsPreferenceToggleRow(
                            title: "Preserve zoom when changing images",
                            subtitle: "When zoomed (wheel, pinch, or +/-), keep zoom and pan anchor on arrow keys, H, and E.",
                            tooltip: "Applies only after manual zoom in browse mode, not in fit-to-window or actual size.",
                            isOn: boolBinding("browse_preserve_zoom_on_image_change")
                        )
                        SettingsPreferenceToggleRow(
                            title: "Use EXIF rotation",
                            subtitle: "Rotate images based on EXIF data if available.",
                            tooltip: "Apply automatic EXIF rotation correction. Manual rotation (Shift+arrow keys) still works in fullscreen.",
                            isOn: exifRotationBinding
                        )
                    }
                }
            }
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

    private func setAllGroupsExpanded(_ expanded: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            generalExpanded = expanded
            thumbnailsExpanded = expanded
            imageViewingExpanded = expanded
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
