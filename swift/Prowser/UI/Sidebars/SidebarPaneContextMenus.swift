import AppKit
import SwiftUI

enum SidebarPaneContextMenuKind: Equatable {
    case fileTree
    case information
    case jobs(floating: Bool)
    case chat
}

/// Control-click / right-click menus for sidebar panes and the floating job panel.
@MainActor
enum SidebarPaneContextMenus {
    static func show(
        kind: SidebarPaneContextMenuKind,
        for event: NSEvent,
        in view: NSView,
        appState: AppState
    ) {
        let menu = buildMenu(kind: kind, appState: appState)
        PaneMenuActions.shared.appState = appState
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    static func showBelowAnchor(
        kind: SidebarPaneContextMenuKind,
        anchor: NSView,
        appState: AppState
    ) {
        let menu = buildMenu(kind: kind, appState: appState)
        PaneMenuActions.shared.appState = appState
        let point = NSPoint(x: 0, y: anchor.bounds.height)
        menu.popUp(positioning: nil, at: anchor.convert(point, to: nil), in: nil)
    }

    static func buildMenu(kind: SidebarPaneContextMenuKind, appState: AppState) -> NSMenu {
        switch kind {
        case .fileTree:
            return fileTreeMenu(appState: appState)
        case .information:
            return informationMenu(appState: appState)
        case .jobs(let floating):
            return jobsMenu(appState: appState, floating: floating)
        case .chat:
            return chatMenu(appState: appState)
        }
    }

    private static func fileTreeMenu(appState: AppState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let mode = appState.filterSettings.filteredTree

        addAction(menu, title: "Collapse to Home Directory", action: #selector(PaneMenuActions.treeCollapse(_:)))
        addCheckable(
            menu,
            title: "Toggle Rename Status Check",
            checked: false,
            enabled: false,
            action: #selector(PaneMenuActions.treeRenameStatus(_:))
        )
        addAction(menu, title: "Open Settings", action: #selector(PaneMenuActions.treeOpenSettings(_:)))
        menu.addItem(.separator())
        addCheckable(menu, title: "Filtering: None", checked: mode == "all", tag: 0, action: #selector(PaneMenuActions.treeFilter(_:)))
        addCheckable(menu, title: "Filtering: Has Images", checked: mode == "images", tag: 1, action: #selector(PaneMenuActions.treeFilter(_:)))
        addCheckable(menu, title: "Filtering: Pattern Matching", checked: mode == "use_filter", tag: 2, action: #selector(PaneMenuActions.treeFilter(_:)))
        menu.addItem(.separator())
        addCheckable(
            menu,
            title: "Show Toolbar",
            checked: appState.fileTreeToolbarVisible,
            action: #selector(PaneMenuActions.treeShowToolbar(_:))
        )
        stripMenuIcons(menu)
        return menu
    }

    private static func informationMenu(appState: AppState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let hasComment = appState.informationHasUserComment

        addAction(menu, title: "Edit User Comment", action: #selector(PaneMenuActions.infoEdit(_:)))
        addAction(menu, title: "Copy to Clipboard", enabled: hasComment, action: #selector(PaneMenuActions.infoCopy(_:)))
        if BundleCapabilities.voiceInputUIEnabled {
            addAction(menu, title: "Read User Comment Aloud", enabled: hasComment, action: #selector(PaneMenuActions.infoSpeak(_:)))
        }
        if BundleCapabilities.imageGenUIEnabled {
            addAction(menu, title: "Create Image from this prompt", action: #selector(PaneMenuActions.infoCreate(_:)))
            addAction(menu, title: "Edit this image with AI", action: #selector(PaneMenuActions.infoEditAI(_:)))
        }
        addAction(menu, title: "Delete User Comment", enabled: hasComment, action: #selector(PaneMenuActions.infoDelete(_:)))
        menu.addItem(.separator())
        addCheckable(
            menu,
            title: "Show Menu Bar",
            checked: appState.informationMenuBarVisible,
            action: #selector(PaneMenuActions.infoShowMenuBar(_:))
        )
        stripMenuIcons(menu)
        return menu
    }

    private static func jobsMenu(appState: AppState, floating: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let controller = appState.imageGen

        addCheckable(
            menu,
            title: "Intermediate Images",
            checked: controller.showProgressiveImages,
            enabled: controller.isEnabled,
            action: #selector(PaneMenuActions.jobsIntermediate(_:))
        )
        addCheckable(
            menu,
            title: "Hold Job Queue",
            checked: controller.holdJobQueue,
            enabled: controller.isEnabled,
            action: #selector(PaneMenuActions.jobsHoldQueue(_:))
        )
        addAction(
            menu,
            title: "Skip This Copy",
            enabled: controller.canSkipActiveSeriesCopy,
            action: #selector(PaneMenuActions.jobsSkipCopy(_:))
        )
        if floating {
            menu.addItem(.separator())
            addCheckable(
                menu,
                title: "Always on Top",
                checked: appState.jobsPanelAlwaysOnTop,
                action: #selector(PaneMenuActions.jobsAlwaysOnTop(_:))
            )
        }
        menu.addItem(.separator())
        addCheckable(
            menu,
            title: "Show Toolbar",
            checked: appState.jobsToolbarVisible,
            action: #selector(PaneMenuActions.jobsShowToolbar(_:))
        )
        stripMenuIcons(menu)
        return menu
    }

    private static func chatMenu(appState: AppState) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let chat = appState.chat

        addAction(menu, title: "System prompt for chat", enabled: chat.isEnabled, action: #selector(PaneMenuActions.chatSystemPrompt(_:)))
        addCheckable(
            menu,
            title: "Copy images to Assistant's reply",
            checked: chat.copyImagesToAssistant,
            enabled: chat.isEnabled,
            action: #selector(PaneMenuActions.chatCopyImages(_:))
        )
        addAction(menu, title: "Clear Chat", action: #selector(PaneMenuActions.chatClear(_:)))
        menu.addItem(.separator())
        addCheckable(
            menu,
            title: "Preserve Chat Across Sessions",
            checked: chat.preserveAcrossSessions,
            action: #selector(PaneMenuActions.chatPreserve(_:))
        )
        addAction(menu, title: "Tips…", action: #selector(PaneMenuActions.chatTips(_:)))
        menu.addItem(.separator())
        addCheckable(
            menu,
            title: "Show Toolbar",
            checked: appState.chatToolbarVisible,
            action: #selector(PaneMenuActions.chatShowToolbar(_:))
        )
        stripMenuIcons(menu)
        return menu
    }

    private static func addAction(
        _ menu: NSMenu,
        title: String,
        enabled: Bool = true,
        tag: Int = 0,
        action: Selector
    ) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = PaneMenuActions.shared
        item.isEnabled = enabled
        item.tag = tag
    }

    private static func addCheckable(
        _ menu: NSMenu,
        title: String,
        checked: Bool,
        enabled: Bool = true,
        tag: Int = 0,
        action: Selector
    ) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = PaneMenuActions.shared
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        item.tag = tag
    }

    private static func stripMenuIcons(_ menu: NSMenu) {
        for item in menu.items {
            item.image = nil
            item.onStateImage = nil
            if let submenu = item.submenu {
                stripMenuIcons(submenu)
            }
        }
    }
}

@MainActor
final class PaneMenuActions: NSObject {
    static let shared = PaneMenuActions()
    weak var appState: AppState?

    @objc func treeCollapse(_ sender: NSMenuItem) {
        appState?.collapseFileTreeToHome()
    }

    @objc func treeRenameStatus(_ sender: NSMenuItem) {
        appState?.status.show("Rename status checking is not available in the Swift build yet.")
    }

    @objc func treeOpenSettings(_ sender: NSMenuItem) {
        appState?.openSettingsWindow(tab: .general)
    }

    @objc func treeFilter(_ sender: NSMenuItem) {
        guard let appState else { return }
        let modes = ["all", "images", "use_filter"]
        guard sender.tag >= 0, sender.tag < modes.count else { return }
        appState.setFileTreeFilterMode(modes[sender.tag])
    }

    @objc func treeShowToolbar(_ sender: NSMenuItem) {
        appState?.setFileTreeToolbarVisible(sender.state == .on)
    }

    @objc func infoEdit(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .prowserInformationAction, object: nil, userInfo: ["action": "edit"])
    }

    @objc func infoCopy(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .prowserInformationAction, object: nil, userInfo: ["action": "copy"])
    }

    @objc func infoSpeak(_ sender: NSMenuItem) {
        appState?.status.show("Read aloud is not available in the Swift build yet.")
    }

    @objc func infoCreate(_ sender: NSMenuItem) {
        appState?.openImageGenDialog()
    }

    @objc func infoEditAI(_ sender: NSMenuItem) {
        appState?.status.show("Edit with AI is not available in the Swift build yet.")
    }

    @objc func infoDelete(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .prowserInformationAction, object: nil, userInfo: ["action": "delete"])
    }

    @objc func infoShowMenuBar(_ sender: NSMenuItem) {
        appState?.setInformationMenuBarVisible(sender.state == .on)
    }

    @objc func jobsIntermediate(_ sender: NSMenuItem) {
        guard let appState else { return }
        appState.imageGen.setShowProgressiveImages(sender.state == .on)
    }

    @objc func jobsHoldQueue(_ sender: NSMenuItem) {
        guard let appState else { return }
        appState.imageGen.setHoldJobQueue(sender.state == .on)
    }

    @objc func jobsSkipCopy(_ sender: NSMenuItem) {
        appState?.imageGen.skipActiveSeriesCopy()
    }

    @objc func jobsAlwaysOnTop(_ sender: NSMenuItem) {
        appState?.setJobsPanelAlwaysOnTop(sender.state == .on)
    }

    @objc func jobsShowToolbar(_ sender: NSMenuItem) {
        appState?.setJobsToolbarVisible(sender.state == .on)
    }

    @objc func chatSystemPrompt(_ sender: NSMenuItem) {
        appState?.chat.requestSystemPromptEdit()
    }

    @objc func chatCopyImages(_ sender: NSMenuItem) {
        guard let appState else { return }
        appState.chat.setCopyImagesToAssistant(sender.state == .on)
    }

    @objc func chatClear(_ sender: NSMenuItem) {
        appState?.chat.clear()
    }

    @objc func chatPreserve(_ sender: NSMenuItem) {
        guard let appState else { return }
        appState.chat.setPreserveAcrossSessions(sender.state == .on)
    }

    @objc func chatTips(_ sender: NSMenuItem) {
        appState?.status.show(
            "Chat tips:\n• Use a clear system prompt for consistent replies.\n• Toggle “Copy images” to attach the current image to assistant context.\n• Preserve chat to keep history between launches."
        )
    }

    @objc func chatShowToolbar(_ sender: NSMenuItem) {
        appState?.setChatToolbarVisible(sender.state == .on)
    }
}

extension Notification.Name {
    static let prowserInformationAction = Notification.Name("prowser.informationAction")
}

/// Invisible overlay that shows a pane context menu on right-click.
struct PaneContextMenuReceiver: NSViewRepresentable {
    let kind: SidebarPaneContextMenuKind
    @Environment(AppState.self) private var appState

    func makeNSView(context: Context) -> PaneContextMenuView {
        let view = PaneContextMenuView()
        view.kind = kind
        view.appState = appState
        return view
    }

    func updateNSView(_ nsView: PaneContextMenuView, context: Context) {
        nsView.kind = kind
        nsView.appState = appState
    }
}

@MainActor
final class PaneContextMenuView: NSView {
    var kind: SidebarPaneContextMenuKind = .fileTree
    weak var appState: AppState?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return self
        case .leftMouseDown, .leftMouseUp:
            if event.modifierFlags.contains(.control) {
                return self
            }
            return nil
        default:
            return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        presentMenu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            presentMenu(for: event)
            return
        }
        super.mouseDown(with: event)
    }

    private func presentMenu(for event: NSEvent) {
        guard let appState else { return }
        SidebarPaneContextMenus.show(kind: kind, for: event, in: self, appState: appState)
    }
}

/// Titlebar gear button that opens the same tools menu as the pane context menu.
struct SidebarPaneToolsMenuButton: NSViewRepresentable {
    let kind: SidebarPaneContextMenuKind
    @Environment(AppState.self) private var appState

    func makeNSView(context: Context) -> PaneToolsButtonView {
        let view = PaneToolsButtonView()
        view.kind = kind
        view.appState = appState
        return view
    }

    func updateNSView(_ nsView: PaneToolsButtonView, context: Context) {
        nsView.kind = kind
        nsView.appState = appState
    }
}

@MainActor
final class PaneToolsButtonView: NSView {
    var kind: SidebarPaneContextMenuKind = .fileTree
    weak var appState: AppState?

    private let button = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = PenDrawnIcons.gearIcon(hover: false)
            ?? NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Pane tools")
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(showToolsMenu)
        button.toolTip = "Pane tools"
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 20),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func showToolsMenu() {
        guard let appState else { return }
        SidebarPaneContextMenus.showBelowAnchor(kind: kind, anchor: self, appState: appState)
    }
}
