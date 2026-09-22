import AppKit
import SwiftUI

@MainActor
struct ThemeSettingsTab: View {
    @Environment(AppState.self) private var appState

    @State private var groupExpanded: [String: Bool] = [:]
    @State private var cachedEditPresetID = ""
    @State private var cachedMerged: [String: Any] = [:]
    @State private var cachedBrowse: [String: Any] = [:]
    @State private var newThemeName = ""
    @State private var showAddTheme = false
    @State private var addThemeBase = "dark"

    private let editableBuiltinPresets: [(String, String)] = [
        ("Dark", "dark"),
        ("Light", "light"),
        ("User", "user"),
    ]

    var body: some View {
        SettingsCollapsibleTabLayout(
            onExpandAll: { setAllGroupsExpanded(true) },
            onCollapseAll: { setAllGroupsExpanded(false) }
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Theme")
                    .font(.title2)
                    .foregroundStyle(SettingsDialogChrome.text)

                presetSection
                colorSections(editID: editThemeID)
            }
        }
        .background(SettingsDialogChrome.background)
        .onAppear {
            loadGroupExpanded()
            refreshThemeColorCache()
        }
        .onChange(of: appState.theme.settingsEditPresetID) { _, _ in
            refreshThemeColorCache()
        }
        .alert("New Custom Theme", isPresented: $showAddTheme) {
            TextField("Theme name", text: $newThemeName)
            Button("Cancel", role: .cancel) { newThemeName = "" }
            Button("Create") {
                let name = newThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    if appState.theme.createCustomTheme(displayName: name, base: addThemeBase) != nil {
                        notifyThemeChanged()
                    }
                }
                newThemeName = ""
            }
        } message: {
            Text("Enter a name for the new custom theme.")
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preset")
                .font(.headline)
                .foregroundStyle(SettingsDialogChrome.text)

            HStack(spacing: 8) {
                Picker("Use palette from:", selection: editPresetBinding) {
                    ForEach(editableBuiltinPresets, id: \.1) { label, id in
                        Text(label).tag(id)
                    }
                    ForEach(appState.theme.customThemeIDs, id: \.self) { id in
                        Text(appState.theme.customThemeDisplayName(id)).tag(id)
                    }
                }
                .frame(maxWidth: 280)

                Button("Add") { showAddTheme = true }
                Button("Delete") { deleteCurrentCustomTheme() }
                    .disabled(!isCustomTheme)
            }

            Picker("Base for new theme", selection: $addThemeBase) {
                Text("Dark").tag("dark")
                Text("Light").tag("light")
                Text("User").tag("user")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
        }
        .padding(12)
        .background(SettingsDialogChrome.sectionBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func colorSections(editID: String) -> some View {
        let merged = cachedEditPresetID == editID ? cachedMerged : appState.theme.mergedColorOverrides(for: editID)
        let browse = cachedEditPresetID == editID ? cachedBrowse : appState.theme.browseTransparency(for: editID)

        CollapsibleSettingsSection(
            title: "Text & background",
            stateKey: "text_background",
            isExpanded: groupBinding("text_background")
        ) {
            ThemeColorSwatchRow(
                label: "Application background:",
                hex: stringValue(merged, "default_background_color_hex"),
                onColorChange: { setOverride(editID, "default_background_color_hex", $0) }
            )
            ThemeColorSwatchRow(
                label: "Main text:",
                hex: stringValue(merged, "text_color_hex"),
                onColorChange: { setOverride(editID, "text_color_hex", $0) }
            )
        }

        CollapsibleSettingsSection(
            title: "Dialogs",
            stateKey: "dialogs",
            isExpanded: groupBinding("dialogs")
        ) {
            ThemeColorSwatchRow(
                label: "Dialog background:",
                hex: stringValue(merged, "dialog_background_hex"),
                onColorChange: { setOverride(editID, "dialog_background_hex", $0) }
            )
            ThemeColorSwatchRow(
                label: "Dialog text:",
                hex: stringValue(merged, "dialog_text_color_hex"),
                onColorChange: { setOverride(editID, "dialog_text_color_hex", $0) }
            )
            ThemeMutedBlendRow(
                label: "Dialog muted text:",
                percent: intValue(merged, "dialog_muted_blend_percent", default: 50),
                previewHex: mutedPreview(
                    textKey: "dialog_text_color_hex",
                    bgKey: "dialog_background_hex",
                    blendKey: "dialog_muted_blend_percent",
                    merged: merged
                ),
                onChange: { setOverride(editID, "dialog_muted_blend_percent", $0) }
            )
            ThemeColorSwatchRow(
                label: "Input backgrounds:",
                hex: stringValue(merged, "dialog_input_background_hex"),
                onColorChange: { setOverride(editID, "dialog_input_background_hex", $0) }
            )
        }

        CollapsibleSettingsSection(
            title: "Sidebar, panes and status bar",
            stateKey: "sidebar_chrome",
            isExpanded: groupBinding("sidebar_chrome")
        ) {
            ThemeColorSwatchRow(
                label: "View titlebars bar:",
                hex: stringValue(merged, "sidebar_header_bg_hex"),
                onColorChange: { setOverride(editID, "sidebar_header_bg_hex", $0) }
            )
            ThemeColorSwatchRow(
                label: "Sidebar background:",
                hex: stringValue(merged, "sidebar_background_color_hex"),
                onColorChange: { setOverride(editID, "sidebar_background_color_hex", $0) }
            )
            ThemeColorSwatchRow(
                label: "Sidebar text:",
                hex: stringValue(merged, "sidebar_text_color_hex"),
                onColorChange: { setOverride(editID, "sidebar_text_color_hex", $0) }
            )
            ThemeMutedBlendRow(
                label: "Sidebar muted text:",
                percent: intValue(merged, "sidebar_muted_blend_percent", default: 50),
                previewHex: mutedPreview(
                    textKey: "sidebar_text_color_hex",
                    bgKey: "sidebar_background_color_hex",
                    blendKey: "sidebar_muted_blend_percent",
                    merged: merged
                ),
                onChange: { setOverride(editID, "sidebar_muted_blend_percent", $0) }
            )
            ThemeColorSwatchRow(
                label: "Status bar background:",
                hex: stringValue(merged, "status_bar_background_color_hex"),
                onColorChange: { setOverride(editID, "status_bar_background_color_hex", $0) }
            )
            ThemeColorSwatchRow(
                label: "Status bar text:",
                hex: stringValue(merged, "status_bar_text_color_hex"),
                onColorChange: { setOverride(editID, "status_bar_text_color_hex", $0) }
            )
            ThemeMutedBlendRow(
                label: "Status bar muted text:",
                percent: intValue(merged, "status_bar_muted_blend_percent", default: 50),
                previewHex: mutedPreview(
                    textKey: "status_bar_text_color_hex",
                    bgKey: "status_bar_background_color_hex",
                    blendKey: "status_bar_muted_blend_percent",
                    merged: merged
                ),
                onChange: { setOverride(editID, "status_bar_muted_blend_percent", $0) }
            )
            ThemeColorSwatchRow(
                label: "View borders:",
                hex: stringValue(merged, "default_border_color_hex"),
                onColorChange: { setOverride(editID, "default_border_color_hex", $0) }
            )
            ThemeBorderWidthRow(
                label: "View border width:",
                width: intValue(merged, "view_border_width_px", default: 2),
                range: 0...8,
                onChange: { setOverride(editID, "view_border_width_px", $0) }
            )
        }

        CollapsibleSettingsSection(
            title: "Button settings",
            stateKey: "button_settings",
            isExpanded: groupBinding("button_settings")
        ) {
            ThemeColorSwatchRow(label: "Button background:", hex: stringValue(merged, "button_bg_default_hex"), onColorChange: { setOverride(editID, "button_bg_default_hex", $0) })
            ThemeColorSwatchRow(label: "Button text:", hex: stringValue(merged, "button_text_default_hex"), onColorChange: { setOverride(editID, "button_text_default_hex", $0) })
            ThemeColorSwatchRow(label: "Button border:", hex: stringValue(merged, "button_border_default_hex"), onColorChange: { setOverride(editID, "button_border_default_hex", $0) })
            ThemeColorSwatchRow(label: "Button hover background:", hex: stringValue(merged, "button_bg_hover_hex"), onColorChange: { setOverride(editID, "button_bg_hover_hex", $0) })
            ThemeColorSwatchRow(label: "Button hover text:", hex: stringValue(merged, "button_text_hover_hex"), onColorChange: { setOverride(editID, "button_text_hover_hex", $0) })
            ThemeColorSwatchRow(label: "Button hover border:", hex: stringValue(merged, "button_border_hover_hex"), onColorChange: { setOverride(editID, "button_border_hover_hex", $0) })
        }

        CollapsibleSettingsSection(
            title: "Thumbnails and image selection",
            stateKey: "thumbnails_selection",
            isExpanded: groupBinding("thumbnails_selection")
        ) {
            ThemeColorSwatchRow(label: "Thumbnail grid background:", hex: stringValue(merged, "thumbnail_grid_background_color_hex"), onColorChange: { setOverride(editID, "thumbnail_grid_background_color_hex", $0) })
            ThemeColorSwatchRow(label: "Thumbnail text:", hex: stringValue(merged, "thumbnail_text_color_hex"), onColorChange: { setOverride(editID, "thumbnail_text_color_hex", $0) })
            ThemeColorSwatchRow(
                label: "Image border:",
                hex: stringValue(merged, "default_image_color_hex"),
                width: intValue(merged, "default_image_border_width_index", default: 1),
                widthTooltip: "Border around non-selected thumbnails (0 = hidden)",
                onColorChange: { setOverride(editID, "default_image_color_hex", $0) },
                onWidthChange: { setOverride(editID, "default_image_border_width_index", $0) }
            )
            ThemeColorSwatchRow(label: "Image background:", hex: stringValue(merged, "default_image_background_color_hex"), onColorChange: { setOverride(editID, "default_image_background_color_hex", $0) })
            ThemeColorSwatchRow(
                label: "Active image border:",
                hex: stringValue(merged, "current_image_border_color_hex"),
                width: intValue(merged, "current_image_border_width_index", default: 2),
                widthTooltip: "Border for the active image thumbnail",
                onColorChange: { setOverride(editID, "current_image_border_color_hex", $0) },
                onWidthChange: { setOverride(editID, "current_image_border_width_index", $0) }
            )
            ThemeColorSwatchRow(label: "Active image background:", hex: stringValue(merged, "current_image_background_color_hex"), onColorChange: { setOverride(editID, "current_image_background_color_hex", $0) })
            ThemeColorSwatchRow(
                label: "Multiselect image border:",
                hex: stringValue(merged, "multiselect_border_color_hex"),
                width: intValue(merged, "multiselect_border_width_index", default: 2),
                widthTooltip: "Border when multiple thumbnails are selected",
                onColorChange: { setOverride(editID, "multiselect_border_color_hex", $0) },
                onWidthChange: { setOverride(editID, "multiselect_border_width_index", $0) }
            )
            ThemeColorSwatchRow(label: "Multiselect image background:", hex: stringValue(merged, "multiselect_background_color_hex"), onColorChange: { setOverride(editID, "multiselect_background_color_hex", $0) })
        }

        CollapsibleSettingsSection(
            title: "Browse Colors",
            stateKey: "browse_colors",
            isExpanded: groupBinding("browse_colors")
        ) {
            browseTransparencySection(editID: editID, browse: browse)
        }

        HStack {
            Button("Reset Colors to Defaults") {
                appState.theme.resetColorOverrides(for: editID, persist: false)
                notifyThemeChanged()
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func browseTransparencySection(editID: String, browse: [String: Any]) -> some View {
        let rgb = browse["transparency_color"] as? [Int] ?? [98, 98, 98]
        let borderRGB = browse["browse_border_color"] as? [Int] ?? [0, 0, 0]
        let useDiamonds = browse["use_diamonds"] as? Bool ?? true
        let transparencyHex = rgbHex(rgb)
        let borderHex = rgbHex(borderRGB)

        HStack(spacing: 12) {
            Text("Transparency color:")
                .frame(minWidth: 200, alignment: .leading)
            ThemeColorSwatchRow(
                label: "",
                hex: transparencyHex,
                onColorChange: { hex in
                    if let rgb = hexToRGB(hex) {
                        appState.theme.setBrowseTransparency(themeID: editID, key: "transparency_color", value: rgb, persist: false)
                        refreshThemeColorCache()
                        notifyThemeChanged()
                    }
                }
            )
            Text("or")
                .foregroundStyle(SettingsDialogChrome.secondaryText)
            SettingsPreferenceSwitch(isOn: Binding(
                get: { useDiamonds },
                set: { newValue in
                    appState.theme.setBrowseTransparency(themeID: editID, key: "use_diamonds", value: newValue, persist: false)
                    refreshThemeColorCache()
                    notifyThemeChanged()
                }
            ))
            Text("Use Checkerboard")
                .foregroundStyle(SettingsDialogChrome.text)
        }

        HStack(spacing: 12) {
            Text("Browse border color:")
                .frame(minWidth: 200, alignment: .leading)
            ThemeColorSwatchRow(
                label: "",
                hex: borderHex,
                onColorChange: { hex in
                    if let rgb = hexToRGB(hex) {
                        appState.theme.setBrowseTransparency(themeID: editID, key: "browse_border_color", value: rgb, persist: false)
                        refreshThemeColorCache()
                        notifyThemeChanged()
                    }
                }
            )
        }
    }

    private var editPresetBinding: Binding<String> {
        Binding(
            get: { appState.theme.settingsEditPresetID },
            set: { newValue in
                appState.theme.selectEditPreset(newValue)
                notifyThemeChanged()
            }
        )
    }

    private var editThemeID: String { appState.theme.settingsEditPresetID }
    private var isCustomTheme: Bool {
        appState.theme.customThemes[appState.theme.settingsEditPresetID] != nil
    }

    private func groupBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { groupExpanded[key] ?? true },
            set: { newValue in
                groupExpanded[key] = newValue
                appState.theme.setCollapseGroupExpanded(key, expanded: newValue)
            }
        )
    }

    private func loadGroupExpanded() {
        let groups = appState.config.settingsGroupsExpanded(storageKey: "theme_settings_groups_expanded")
        for key in ThemeKeys.collapseGroupKeys {
            groupExpanded[key] = groups[key] ?? true
        }
    }

    private func setAllGroupsExpanded(_ expanded: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            for key in ThemeKeys.collapseGroupKeys {
                groupExpanded[key] = expanded
                appState.theme.setCollapseGroupExpanded(key, expanded: expanded)
            }
        }
    }

    private func refreshThemeColorCache() {
        let editID = editThemeID
        cachedEditPresetID = editID
        cachedMerged = appState.theme.mergedColorOverrides(for: editID)
        cachedBrowse = appState.theme.browseTransparency(for: editID)
    }

    private func setOverride(_ themeID: String, _ key: String, _ value: Any) {
        appState.theme.setColorOverride(themeID: themeID, key: key, value: value, persist: false)
        if themeID == cachedEditPresetID {
            var merged = cachedMerged
            merged[key] = value
            cachedMerged = merged
        } else {
            refreshThemeColorCache()
        }
        notifyThemeChanged()
    }

    private func notifyThemeChanged() {
        guard !appState.config.isSettingsSessionActive else { return }
        appState.eventBus.emit(.settingsChanged)
    }

    private func deleteCurrentCustomTheme() {
        let id = appState.theme.settingsEditPresetID
        guard appState.theme.customThemes[id] != nil else { return }
        appState.theme.deleteCustomTheme(id)
        notifyThemeChanged()
    }

    private func stringValue(_ dict: [String: Any], _ key: String) -> String {
        dict[key] as? String ?? ""
    }

    private func intValue(_ dict: [String: Any], _ key: String, default: Int) -> Int {
        if let v = dict[key] as? Int { return v }
        if let s = dict[key] as? String, let v = Int(s) { return v }
        return `default`
    }

    private func mutedPreview(textKey: String, bgKey: String, blendKey: String, merged: [String: Any]) -> String {
        ThemeBlendUtils.blendTextTowardBackground(
            textHex: stringValue(merged, textKey),
            bgHex: stringValue(merged, bgKey),
            blendPercent: intValue(merged, blendKey, default: 50)
        )
    }

    private func rgbHex(_ rgb: [Int]) -> String {
        guard rgb.count >= 3 else { return "#626262" }
        return String(format: "#%02x%02x%02x", rgb[0], rgb[1], rgb[2])
    }

    private func hexToRGB(_ hex: String) -> [Int]? {
        guard let color = NSColor(hex: hex) else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Int(r * 255), Int(g * 255), Int(b * 255)]
    }
}
