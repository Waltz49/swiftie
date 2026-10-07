import AppKit
import SwiftUI

enum SidebarPaneContextMenuKind: Equatable {
    case fileTree
    case information
    case jobs(floating: Bool)
}

/// Control-click / right-click menus for sidebar panes.
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
        }
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
        menu.addItem(.separator())
        addCheckable(
            menu,
            title: "Always on Top",
            checked: appState.jobsPanelAlwaysOnTop,
            enabled: floating,
            action: #selector(PaneMenuActions.jobsAlwaysOnTop(_:))
        )
        menu.addItem(.separator())
        addCheckable(
            menu,
            title: toolbarToggleTitle(visible: appState.jobsToolbarVisible),
            checked: appState.jobsToolbarVisible,
            action: #selector(PaneMenuActions.jobsShowToolbar(_:))
        )
        stripMenuIcons(menu)
        return menu
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
            title: toolbarToggleTitle(visible: appState.fileTreeToolbarVisible),
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
        addAction(menu, title: "Delete User Comment", enabled: hasComment, action: #selector(PaneMenuActions.infoDelete(_:)))
        menu.addItem(.separator())
        addCheckable(
            menu,
            title: toolbarToggleTitle(visible: appState.informationMenuBarVisible, noun: "Menu Bar"),
            checked: appState.informationMenuBarVisible,
            action: #selector(PaneMenuActions.infoShowMenuBar(_:))
        )
        stripMenuIcons(menu)
        return menu
    }

    /// "Show Toolbar" while hidden, "Hide Toolbar" while visible (the item stays checkable).
    private static func toolbarToggleTitle(visible: Bool, noun: String = "Toolbar") -> String {
        (visible ? "Hide " : "Show ") + noun
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

    /// AppKit does not flip `NSMenuItem.state` on click; the item still carries the
    /// pre-click state, so the new value is its inverse (mirrors Qt's `toggled(bool)`).
    private func toggledValue(_ sender: NSMenuItem) -> Bool {
        sender.state != .on
    }

    @objc func treeCollapse(_ sender: NSMenuItem) {
        appState?.collapseFileTreeToHome()
    }

    @objc func treeRenameStatus(_ sender: NSMenuItem) {
        appState?.toggleRenameStatusChecking()
    }

    @objc func treeOpenSettings(_ sender: NSMenuItem) {
        appState?.openSettingsWindow()
    }

    @objc func treeFilter(_ sender: NSMenuItem) {
        guard let appState else { return }
        let modes = ["all", "images", "use_filter"]
        guard sender.tag >= 0, sender.tag < modes.count else { return }
        appState.setFileTreeFilterMode(modes[sender.tag])
    }

    @objc func treeShowToolbar(_ sender: NSMenuItem) {
        appState?.setFileTreeToolbarVisible(toggledValue(sender))
    }

    @objc func infoEdit(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .prowserInformationAction, object: nil, userInfo: ["action": "edit"])
    }

    @objc func infoCopy(_ sender: NSMenuItem) {
        appState?.copyInformationComment(full: NSEvent.modifierFlags.contains(.option))
    }

    @objc func infoDelete(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .prowserInformationAction, object: nil, userInfo: ["action": "delete"])
    }

    @objc func infoShowMenuBar(_ sender: NSMenuItem) {
        appState?.setInformationMenuBarVisible(toggledValue(sender))
    }

    @objc func jobsIntermediate(_ sender: NSMenuItem) {
        guard let appState else { return }
        appState.imageGen.setShowProgressiveImages(toggledValue(sender))
    }

    @objc func jobsHoldQueue(_ sender: NSMenuItem) {
        guard let appState else { return }
        appState.imageGen.setHoldJobQueue(toggledValue(sender))
    }

    @objc func jobsSkipCopy(_ sender: NSMenuItem) {
        appState?.imageGen.skipActiveSeriesCopy()
    }

    @objc func jobsAlwaysOnTop(_ sender: NSMenuItem) {
        appState?.setJobsPanelAlwaysOnTop(toggledValue(sender))
    }

    @objc func jobsShowToolbar(_ sender: NSMenuItem) {
        appState?.setJobsToolbarVisible(toggledValue(sender))
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var isOpaque: Bool { false }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if Self.isResolvingUnderlyingView { return nil }
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
        if forwardToUnderlyingTextInput(event) { return }
        presentMenu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            if forwardToUnderlyingTextInput(event) { return }
            presentMenu(for: event)
            return
        }
        super.mouseDown(with: event)
    }

    private func presentMenu(for event: NSEvent) {
        guard let appState else { return }
        SidebarPaneContextMenus.show(kind: kind, for: event, in: self, appState: appState)
    }

    /// Re-dispatch the click with this overlay hidden so text views receive the standard edit menu.
    private func forwardToUnderlyingTextInput(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard underlyingTextInput(at: point) != nil else { return false }
        isHidden = true
        NSApp.sendEvent(event)
        isHidden = false
        return true
    }

    private static var isResolvingUnderlyingView = false

    /// When a text field sits under this overlay, pass the click through for the standard edit menu.
    private func underlyingTextInput(at point: NSPoint) -> NSView? {
        guard let window, !Self.isResolvingUnderlyingView else { return nil }
        let windowPoint = convert(point, to: nil)
        Self.isResolvingUnderlyingView = true
        isHidden = true
        let hit = window.contentView?.hitTest(windowPoint)
        isHidden = false
        Self.isResolvingUnderlyingView = false
        guard let hit, Self.containsTextInput(hit) else { return nil }
        return hit
    }

    private static func containsTextInput(_ view: NSView) -> Bool {
        if view is NSTextView || view is NSTextField || view is NSSecureTextField {
            return true
        }
        var current: NSView? = view
        while let candidate = current {
            if candidate is NSTextView || candidate is NSTextField || candidate is NSSecureTextField {
                return true
            }
            current = candidate.superview
        }
        return false
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
        nsView.refreshAppearance()
    }
}

@MainActor
final class PaneToolsButtonView: NSView {
    var kind: SidebarPaneContextMenuKind = .fileTree
    weak var appState: AppState?

    private let button = NSButton()
    private let backgroundView = NSView()
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 3
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .shadowlessSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(showToolsMenu)
        button.toolTip = toolsTooltip(for: .fileTree)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)
        addSubview(button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: TitlebarIcons.buttonSize),
            heightAnchor.constraint(equalToConstant: TitlebarIcons.buttonSize),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: TitlebarIcons.buttonSize),
            button.heightAnchor.constraint(equalToConstant: TitlebarIcons.buttonSize),
        ])
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshAppearance()
    }

    func refreshAppearance() {
        guard let appState else { return }
        let colors = appState.theme.colors
        let chip = TitlebarIcons.chipColors(for: colors)
        backgroundView.layer?.backgroundColor = NSColor(isHovered ? chip.hoverBackground : chip.background).cgColor
        backgroundView.layer?.borderWidth = 1
        backgroundView.layer?.borderColor = NSColor(isHovered ? chip.hoverBorder : chip.border).cgColor
        button.image = TitlebarIcons.toolsIcon(colors: colors, hover: isHovered)
        button.toolTip = toolsTooltip(for: kind)
    }

    private func toolsTooltip(for kind: SidebarPaneContextMenuKind) -> String {
        switch kind {
        case .fileTree: return "File tree tools"
        case .information: return "File information tools"
        case .jobs: return "Job control tools"
        }
    }

    @objc private func showToolsMenu() {
        guard let appState else { return }
        SidebarPaneContextMenus.showBelowAnchor(kind: kind, anchor: self, appState: appState)
    }
}
