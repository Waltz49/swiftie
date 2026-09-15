import AppKit
import SwiftUI

/// Favorites and move-destination reference pane. Port of `shortcuts_sidebar.py`.
@MainActor
struct ShortcutsSidebarView: View {
    @Environment(AppState.self) private var appState
    var body: some View {
        let palette = organizePalette()
        let favorites = validFavoriteSlots()
        let destinations = validDestinationSlots()
        let clickMode = moveKeysMode()
        let copyMode = appState.config.string(forKey: "destination_menu_action", default: "move") == "copy"
        let lastDrop = validLastDropLabel()
        let destinationClicksEnabled = clickMode != "not_links"

        let effectiveCopy = copyMode || clickMode == "copy"

        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                PersistedScrollOffsetReader(
                    storageKey: "shortcuts_sidebar_scroll_position",
                    config: appState.config
                )
                .frame(width: 0, height: 0)
                favoritesSection(favorites: favorites, palette: palette)

                Divider()
                    .overlay(palette.muted.opacity(0.35))
                    .padding(.top, 17)

                sectionHeaderRow(
                    title: effectiveCopy ? "↘ Keys for copying files:" : "↘ Keys for moving files:",
                    palette: palette,
                    settingsTab: .destinations
                )

                clickModeSection(palette: palette)

                destinationRows(
                    destinations: destinations,
                    lastDrop: lastDrop,
                    copyMode: effectiveCopy,
                    palette: palette,
                    destinationClicksEnabled: destinationClicksEnabled
                )
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sections

    private func favoritesSection(
        favorites: [ShortcutSlot],
        palette: OrganizePalette
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeaderRow(
                title: "❤️ Keys for opening Favorites:",
                palette: palette,
                settingsTab: .favorites
            )
            if favorites.isEmpty {
                Text("No valid favorites defined.")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.muted)
                    .padding(.leading, 10)
            } else {
                ForEach(favorites) { slot in
                    shortcutRow(
                        key: "^ \(slot.number)",
                        label: slot.label,
                        tooltip: slot.fullPath,
                        linkColor: palette.favoriteLink,
                        hoverColor: palette.favoriteHover,
                        action: { appState.fileOperations.openFavoriteDirectory(slot: slot.number) }
                    )
                }
            }
        }
    }

    private func destinationRows(
        destinations: [ShortcutSlot],
        lastDrop: ShortcutSlot?,
        copyMode: Bool,
        palette: OrganizePalette,
        destinationClicksEnabled: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if destinations.isEmpty {
                Text(copyMode ? "No valid copy destinations are defined." : "No valid move destinations are defined.")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.muted)
                    .padding(.leading, 10)
            } else {
                ForEach(destinations) { slot in
                    moveShortcutRow(
                        number: slot.number,
                        label: slot.label,
                        tooltip: slot.fullPath,
                        palette: palette,
                        copyMode: copyMode,
                        actionEnabled: destinationClicksEnabled,
                        action: {
                            appState.fileOperations.moveToDestination(
                                slot: slot.number,
                                copyOnly: copyMode
                            )
                        }
                    )
                }
            }
            if let lastDrop {
                moveShortcutRow(
                    number: 0,
                    label: lastDrop.label,
                    tooltip: lastDrop.fullPath,
                    palette: palette,
                    copyMode: copyMode,
                    actionEnabled: destinationClicksEnabled,
                    action: { appState.fileOperations.moveToLastDropLocation(copyOnly: copyMode) }
                )
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    moveKeyLabel(number: 0, palette: palette)
                    Text("Not yet set")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.muted)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
            }
        }
    }

    private func clickModeSection(palette: OrganizePalette) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Click Mode")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(palette.primary)
                    .help(clickModeTooltip)
                ClickModeCombo(
                    selection: clickModeBinding(),
                    palette: palette,
                    tooltip: clickModeTooltip
                )
            }
            Text("This does not affect keyboard shortcuts.")
                .font(.system(size: 10))
                .foregroundStyle(palette.muted)
        }
    }

    // MARK: - Rows

    private func sectionHeaderRow(
        title: String,
        palette: OrganizePalette,
        settingsTab: SettingsTab
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(palette.heading)
            Button {
                appState.openSettingsWindow(tab: settingsTab)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.gearLink)
            .help(settingsTab == .favorites ? "Edit Favorites..." : "Edit Destinations...")
            Spacer(minLength: 0)
        }
    }

    private func shortcutRow(
        key: String,
        label: String,
        tooltip: String,
        linkColor: Color,
        hoverColor: Color,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(key):")
                .font(.system(size: 14))
                .foregroundStyle(appState.theme.colors.sidebarText)
                .frame(minWidth: 44, alignment: .trailing)
            OrganizeLinkButton(
                title: label,
                normalColor: linkColor,
                hoverColor: hoverColor,
                action: action
            )
            .help(tooltip)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
    }

    private func moveShortcutRow(
        number: Int,
        label: String,
        tooltip: String,
        palette: OrganizePalette,
        copyMode: Bool,
        actionEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            moveKeyLabel(number: number, palette: palette)
            OrganizeLinkButton(
                title: label,
                normalColor: palette.destinationLink,
                hoverColor: copyMode ? palette.copyHover : palette.moveHover,
                actionEnabled: actionEnabled,
                action: action
            )
            .help(tooltip)
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
    }

    private func moveKeyLabel(number: Int, palette: OrganizePalette) -> some View {
        HStack(spacing: 0) {
            Text("⌘ \(number)")
            Text(" / ")
                .foregroundStyle(palette.disabled)
            Text("⌥⌘ \(number):")
        }
        .font(.system(size: 14))
        .foregroundStyle(palette.primary)
    }

    // MARK: - Data

    private struct ShortcutSlot: Identifiable {
        let number: Int
        let label: String
        let fullPath: String
        var id: Int { number }
    }

    private var clickModeTooltip: String {
        "Move : Move selected files to the destination\n"
            + "Copy : Copy selected files to the destination\n"
            + "No Action: Mouse clicks are ignored"
    }

    private func moveKeysMode() -> String {
        appState.config.string(forKey: "move_keys_mode", default: "not_links")
    }

    private func clickModeBinding() -> Binding<String> {
        Binding(
            get: { moveKeysMode() },
            set: { newValue in
                appState.config.updateSetting("move_keys_mode", value: newValue)
                appState.config.applySettingsChange(emit: appState.eventBus)
            }
        )
    }

    private struct OrganizePalette {
        let favoriteLink: Color
        let destinationLink: Color
        let heading: Color
        let primary: Color
        let muted: Color
        let disabled: Color
        let favoriteHover: Color
        let moveHover: Color
        let copyHover: Color
        let gearLink: Color
        let comboBackground: Color
        let comboBorder: Color
        let comboHoverBorder: Color
    }

    private func validFavoriteSlots() -> [ShortcutSlot] {
        appState.config.favoriteDirectories().enumerated().compactMap { index, path in
            guard let expanded = validExpandedPath(path),
                  let label = displayName(for: expanded) else { return nil }
            return ShortcutSlot(number: index + 1, label: label, fullPath: expanded)
        }
    }

    private func validDestinationSlots() -> [ShortcutSlot] {
        appState.config.moveDestinations().enumerated().compactMap { index, path in
            guard let expanded = validExpandedPath(path) else { return nil }
            return ShortcutSlot(
                number: index + 1,
                label: destinationDisplayName(for: expanded),
                fullPath: expanded
            )
        }
    }

    private func validLastDropLabel() -> ShortcutSlot? {
        let path = appState.lastDropLocation
        guard let expanded = validExpandedPath(path) else { return nil }
        return ShortcutSlot(number: 0, label: destinationDisplayName(for: expanded), fullPath: expanded)
    }

    private func validExpandedPath(_ path: String?) -> String? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let expanded = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        return expanded
    }

    private func displayName(for path: String) -> String? {
        if path.hasPrefix(NSHomeDirectory()) {
            return "~" + String(path.dropFirst(NSHomeDirectory().count))
        }
        return (path as NSString).lastPathComponent
    }

    /// Last path segment only, matching `path_to_display_segment` in `shortcuts_sidebar.py`.
    private func destinationDisplayName(for path: String) -> String {
        var p = path
        if p.hasPrefix(NSHomeDirectory()) {
            p = "~" + String(p.dropFirst(NSHomeDirectory().count))
        }
        while p.hasSuffix("/") && p.count > 1 {
            p.removeLast()
        }
        let base = (p as NSString).lastPathComponent
        return base.isEmpty ? p : base
    }

    private func organizePalette() -> OrganizePalette {
        let theme = appState.theme
        let overrides = theme.colorOverrides(for: theme.resolvedThemeID)
        let base = theme.colors

        func themeColor(_ key: String, fallback: Color) -> Color {
            guard let raw = overrides[key] as? String else { return fallback }
            return Color(hex: raw) ?? fallback
        }

        let favoriteHoverDefault = theme.resolvedThemeID == "light"
            ? "#0b57d0"
            : "#2dc4ff"
        let favoriteHover = themeColor(
            "sidebar_favorite_link_hover_hex",
            fallback: Color(hex: favoriteHoverDefault) ?? .cyan
        )
        let primary = themeColor("shortcuts_sidebar_primary_text_hex", fallback: base.sidebarText)
        let destinationLink = primary

        return OrganizePalette(
            favoriteLink: favoriteHover,
            destinationLink: destinationLink,
            heading: themeColor("shortcuts_sidebar_heading_text_hex", fallback: base.sidebarHeaderText),
            primary: primary,
            muted: themeColor("sidebar_text_muted_hex", fallback: base.sidebarMutedText),
            disabled: themeColor("text_disabled_hex", fallback: Color(hex: "#888888") ?? .gray),
            favoriteHover: favoriteHover,
            moveHover: Color(hex: "#FF8080") ?? Color(red: 1, green: 0.5, blue: 0.5),
            copyHover: Color(hex: "#80FF80") ?? Color(red: 0.5, green: 1, blue: 0.5),
            gearLink: destinationLink,
            comboBackground: themeColor("shortcuts_combo_bg_hex", fallback: base.sidebarBackground),
            comboBorder: themeColor("shortcuts_combo_border_hex", fallback: base.defaultBorder),
            comboHoverBorder: themeColor("shortcuts_combo_hover_border_hex", fallback: base.splitterHandleHover)
        )
    }

    private struct ClickModeCombo: View {
        @Binding var selection: String
        let palette: OrganizePalette
        let tooltip: String

        @State private var isHovering = false

        private var title: String {
            switch selection {
            case "move": return "Move"
            case "copy": return "Copy"
            default: return "No Action"
            }
        }

        var body: some View {
            Menu {
                Button("No Action") { selection = "not_links" }
                Button("Move") { selection = "move" }
                Button("Copy") { selection = "copy" }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(palette.primary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .frame(width: 102, alignment: .leading)
                .background(palette.comboBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(isHovering ? palette.comboHoverBorder : palette.comboBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(tooltip)
            .onHover { isHovering = $0 }
        }
    }
}

private struct OrganizeLinkButton: View {
    let title: String
    let normalColor: Color
    let hoverColor: Color
    var actionEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            if actionEnabled {
                action()
            }
        } label: {
            Text(title)
                .font(.system(size: 14))
                .lineLimit(1)
                .underline(isHovering)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isHovering && actionEnabled ? hoverColor : normalColor)
        .opacity(actionEnabled ? 1 : 0.85)
        .onHover { isHovering = $0 }
        .contextMenu { }
    }
}
