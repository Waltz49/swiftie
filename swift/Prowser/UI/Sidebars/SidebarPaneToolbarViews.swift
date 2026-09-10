import SwiftUI

@MainActor
struct FileTreeToolbarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 4) {
            SidebarToolbarIconButton(
                systemName: "house",
                tooltip: "Collapse to home directory\nCollapse all and expand to home directory"
            ) {
                appState.collapseFileTreeToHome()
            }
            SidebarToolbarIconButton(
                systemName: "gearshape",
                tooltip: "Open Settings\nConfigure application preferences"
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
            filterButton(mode: "all", systemName: "xmark")
            filterButton(mode: "images", systemName: "square")
            filterButton(mode: "use_filter", systemName: "line.3.horizontal.decrease")
        }
    }

    private func filterButton(mode: String, systemName: String) -> some View {
        let selected = appState.filterSettings.filteredTree == mode
        return SidebarToolbarIconButton(
            systemName: systemName,
            tooltip: filterTooltip(mode),
            selected: selected
        ) {
            appState.setFileTreeFilterMode(mode)
        }
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
            actionButton("edit", systemName: "text.bubble", tooltip: "Edit user comment")
            actionButton("copy", systemName: "doc.on.doc", tooltip: "Copy prompt to clipboard", enabled: hasComment)
            if BundleCapabilities.imageGenUIEnabled {
                actionButton("create", systemName: "photo", tooltip: "Create image from this prompt")
            }
            Spacer(minLength: 0)
            actionButton("delete", systemName: "trash", tooltip: "Delete user comment", enabled: hasComment)
        }
        .padding(.horizontal, 8)
        .padding(.top, 0)
        .padding(.bottom, 5)
        .background(appState.theme.colors.sidebarHeaderBackground.opacity(0.35))
    }

    private func actionButton(
        _ action: String,
        systemName: String,
        tooltip: String,
        enabled: Bool = true
    ) -> some View {
        SidebarToolbarIconButton(systemName: systemName, tooltip: tooltip, enabled: enabled) {
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
        HStack(spacing: 4) {
            SidebarToolbarIconButton(
                systemName: "photo.on.rectangle.angled",
                tooltip: "Intermediate Images\nShow progressive images during generation",
                selected: controller.showProgressiveImages,
                enabled: controller.isEnabled
            ) {
                controller.setShowProgressiveImages(!controller.showProgressiveImages)
            }
            SidebarToolbarIconButton(
                systemName: "pause.circle",
                tooltip: "Hold Job Queue\nPause starting new jobs until released",
                selected: controller.holdJobQueue,
                enabled: controller.isEnabled
            ) {
                controller.setHoldJobQueue(!controller.holdJobQueue)
            }
            SidebarToolbarIconButton(
                systemName: "forward.end",
                tooltip: "Skip This Copy\nEnd the current copy and start the next one in this series",
                enabled: controller.canSkipActiveSeriesCopy
            ) {
                controller.skipActiveSeriesCopy()
            }
            Spacer(minLength: 0)
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
            SidebarToolbarIconButton(
                systemName: "text.quote",
                tooltip: "System prompt for chat\nOpen the system prompt library",
                enabled: chat.isEnabled
            ) {
                chat.requestSystemPromptEdit()
            }
            SidebarToolbarIconButton(
                systemName: "photo.on.rectangle",
                tooltip: "Copy images to Assistant's reply\nWhen enabled, assistant replies show the preceding user message images",
                selected: chat.copyImagesToAssistant,
                enabled: chat.isEnabled
            ) {
                chat.setCopyImagesToAssistant(!chat.copyImagesToAssistant)
            }
            Spacer(minLength: 0)
            SidebarToolbarIconButton(
                systemName: "trash",
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

    let systemName: String
    let tooltip: String
    var selected = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .foregroundStyle(foregroundColor)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
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
