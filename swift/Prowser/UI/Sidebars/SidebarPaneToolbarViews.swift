import SwiftUI

@MainActor
struct FileTreeToolbarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 4) {
            SidebarToolbarIconButton(
                tooltip: "Collapse to home directory\nCollapse all and expand to home directory",
                imageProvider: { hover in
                    PenDrawnIcons.squeezeIcon(
                        color: navIconColor(hover: hover),
                        size: 20
                    )
                }
            ) {
                appState.collapseFileTreeToHome()
            }
            SidebarToolbarIconButton(
                tooltip: (
                    "Toggle Rename Status Check\n"
                    + "Check if files matching filter pattern also match rename pattern "
                    + "and are sequentially numbered"
                ),
                enabled: false,
                imageProvider: { hover in
                    PenDrawnIcons.renameStatusCheckmarkIcon(active: false, hover: hover)
                }
            ) { }
            SidebarToolbarIconButton(
                tooltip: "Open Settings\nConfigure application preferences",
                imageProvider: { hover in
                    PenDrawnIcons.gearIcon(hover: hover)
                        ?? PenDrawnIcons.squeezeIcon(color: navIconColor(hover: hover), size: 20)
                }
            ) {
                appState.openSettingsWindow(tab: .general)
            }
            Spacer(minLength: 0)
            filterButtons
        }
        .padding(.horizontal, 8)
        .padding(.top, 0)
        .padding(.bottom, 5)
        .background(appState.theme.colors.sidebarHeaderBackground.opacity(0.35))
    }

    private var filterButtons: some View {
        HStack(spacing: 4) {
            filterButton(mode: "all")
            filterButton(mode: "images")
            filterButton(mode: "use_filter")
        }
    }

    private func filterButton(mode: String) -> some View {
        let selected = appState.filterSettings.filteredTree == mode
        return SidebarToolbarIconButton(
            tooltip: filterTooltip(mode),
            selected: selected,
            imageProvider: { hover in
                PenDrawnIcons.treeFilterIcon(
                    mode: mode,
                    selected: selected,
                    hover: hover,
                    selectedColor: filterIconSelectedColor,
                    unselectedColor: filterIconUnselectedColor
                )
            }
        ) {
            appState.setFileTreeFilterMode(mode)
        }
    }

    private var filterIconSelectedColor: NSColor {
        NSColor(appState.theme.colors.sidebarHeaderText)
    }

    private var filterIconUnselectedColor: NSColor {
        NSColor(appState.theme.colors.sidebarHeaderText.opacity(0.55))
    }

    private func navIconColor(hover: Bool) -> NSColor {
        hover
            ? NSColor(appState.theme.colors.sidebarHeaderText)
            : NSColor(appState.theme.colors.sidebarHeaderText.opacity(0.72))
    }

    private func filterTooltip(_ mode: String) -> String {
        switch mode {
        case "all":
            return "Filtering: None\nShow all folders regardless of image content"
        case "use_filter":
            return "Filtering: Pattern Matching\nOnly display folders with images matching the filter pattern in Settings"
        default:
            return "Filtering: Has Images\nOnly display folders that contain at least one image"
        }
    }
}

@MainActor
struct InformationActionBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let hasComment = appState.informationHasUserComment
        HStack(spacing: 4) {
            assetActionButton("edit", normal: "comment_icon", hover: "comment_icon_hover", tooltip: "Edit user comment")
            assetActionButton(
                "copy",
                normal: "copy",
                hover: "copy_hover",
                tooltip: "Copy prompt to clipboard.\n⌥+click to copy full user comment.",
                enabled: hasComment
            )
            if BundleCapabilities.voiceInputUIEnabled {
                assetActionButton(
                    "speak",
                    normal: "bullhorn",
                    hover: "bullhorn_hover",
                    tooltip: "Read aloud (click again to stop)",
                    enabled: hasComment,
                    highlighted: appState.commentSpeaker.isSpeaking
                )
            }
            if BundleCapabilities.imageGenUIEnabled {
                assetActionButton(
                    "create",
                    normal: "fromText",
                    hover: "fromText_hover",
                    tooltip: "Create image from this prompt"
                )
                assetActionButton(
                    "editai",
                    normal: "editAI",
                    hover: "editAI_hover",
                    tooltip: "Edit this image with AI"
                )
            }
            Spacer(minLength: 0)
            assetActionButton(
                "delete",
                normal: "trash_icon",
                hover: "trash_icon_hover",
                tooltip: "Delete user comment",
                enabled: hasComment
            )
        }
        .padding(.horizontal, 8)
        .padding(.top, 0)
        .padding(.bottom, 5)
        .background(appState.theme.colors.sidebarHeaderBackground.opacity(0.35))
    }

    private func assetActionButton(
        _ action: String,
        normal: String,
        hover: String,
        tooltip: String,
        enabled: Bool = true,
        highlighted: Bool = false
    ) -> some View {
        SidebarAssetIconButton(
            normalName: normal,
            hoverName: hover,
            tooltip: tooltip,
            selected: highlighted,
            enabled: enabled
        ) {
            if action == "copy" {
                appState.copyInformationComment(full: NSEvent.modifierFlags.contains(.option))
                return
            }
            NotificationCenter.default.post(
                name: .prowserInformationAction,
                object: nil,
                userInfo: ["action": action]
            )
        }
    }
}

@MainActor
struct JobsToolbarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let controller = appState.imageGen
        ZStack {
            HStack(spacing: 4) {
                SidebarAssetIconButton(
                    normalName: "jobs_intermediate",
                    hoverName: "jobs_intermediate_hover",
                    tooltip: "Intermediate Images\nShow progressive images during generation",
                    selected: controller.showProgressiveImages,
                    enabled: controller.isEnabled
                ) {
                    controller.setShowProgressiveImages(!controller.showProgressiveImages)
                }
                SidebarAssetIconButton(
                    normalName: "jobs_hold",
                    hoverName: "jobs_hold_hover",
                    tooltip: "Hold Job Queue\nPause starting new jobs until released",
                    selected: controller.holdJobQueue,
                    enabled: controller.isEnabled
                ) {
                    controller.setHoldJobQueue(!controller.holdJobQueue)
                }
                SidebarAssetIconButton(
                    normalName: "jobs_skip_copy",
                    hoverName: "jobs_skip_copy_hover",
                    tooltip: "Skip This Copy\nEnd the current copy and start the next one in this series",
                    enabled: controller.canSkipActiveSeriesCopy
                ) {
                    controller.skipActiveSeriesCopy()
                }
                Spacer(minLength: 0)
            }
            .opacity(controller.skipSeriesCopyInFlight ? 0 : 1)

            if controller.skipSeriesCopyInFlight {
                Text("Skipping copy...")
                    .font(.system(size: 12))
                    .foregroundStyle(appState.theme.colors.sidebarText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 0)
        .padding(.bottom, 5)
        .background(appState.theme.colors.sidebarHeaderBackground.opacity(0.35))
    }
}

@MainActor
struct ChatToolbarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let chat = appState.chat
        HStack(spacing: 4) {
            SidebarAssetIconButton(
                normalName: "prompt",
                hoverName: "prompt_hover",
                tooltip: "System prompt for chat\nOpen the system prompt library",
                enabled: chat.isEnabled
            ) {
                chat.requestSystemPromptEdit()
            }
            SidebarAssetIconButton(
                normalName: "copy_asst",
                hoverName: "copy_asst_hover",
                tooltip: "Copy images to Assistant's reply\nWhen enabled, assistant replies show the preceding user message images",
                selected: chat.copyImagesToAssistant,
                enabled: chat.isEnabled
            ) {
                chat.setCopyImagesToAssistant(!chat.copyImagesToAssistant)
            }
            Spacer(minLength: 0)
            SidebarAssetIconButton(
                normalName: "trash_icon",
                hoverName: "trash_icon_hover",
                tooltip: "Clear Chat\nRemove all messages and attachments"
            ) {
                chat.clear()
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 0)
        .padding(.bottom, 5)
        .background(appState.theme.colors.sidebarHeaderBackground.opacity(0.35))
    }
}

@MainActor
private struct SidebarToolbarIconButton: View {
    @Environment(AppState.self) private var appState
    @State private var hovering = false

    var systemName: String?
    var imageProvider: ((Bool) -> NSImage)?
    let tooltip: String
    var selected = false
    var enabled = true
    let action: () -> Void

    init(
        systemName: String,
        tooltip: String,
        selected: Bool = false,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.systemName = systemName
        self.imageProvider = nil
        self.tooltip = tooltip
        self.selected = selected
        self.enabled = enabled
        self.action = action
    }

    init(
        tooltip: String,
        selected: Bool = false,
        enabled: Bool = true,
        imageProvider: @escaping (Bool) -> NSImage,
        action: @escaping () -> Void
    ) {
        self.systemName = nil
        self.imageProvider = imageProvider
        self.tooltip = tooltip
        self.selected = selected
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Group {
                if let imageProvider {
                    Image(nsImage: imageProvider(hovering || selected))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                } else if let systemName {
                    Image(systemName: systemName)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 26, height: 26)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(tooltip)
        .onHover { hovering = $0 }
    }

    private var foregroundColor: Color {
        let colors = appState.theme.colors
        if selected || hovering {
            return colors.sidebarHeaderText
        }
        return colors.sidebarHeaderText.opacity(0.72)
    }

    private var backgroundColor: Color {
        let colors = appState.theme.colors
        if selected {
            return colors.sidebarHeaderBackground.opacity(0.9)
        }
        if hovering {
            return colors.sidebarHeaderBackground.opacity(0.55)
        }
        return colors.sidebarHeaderBackground.opacity(0.25)
    }
}
