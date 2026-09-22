import AppKit
import SwiftUI

/// Keyboard expand/collapse for `CollapsibleSettingsSection` headers (← collapse, → expand).
@MainActor
enum CollapsibleSettingsSectionKeyboard {
    private static var setExpandedHandlers: [String: (Bool) -> Void] = [:]
    private static var expandedByStateKey: [String: Bool] = [:]

    static func register(stateKey: String, isExpanded: Bool, setExpanded: @escaping (Bool) -> Void) {
        setExpandedHandlers[stateKey] = setExpanded
        expandedByStateKey[stateKey] = isExpanded
    }

    static func syncExpanded(stateKey: String, isExpanded: Bool) {
        expandedByStateKey[stateKey] = isExpanded
    }

    static func unregister(stateKey: String) {
        setExpandedHandlers.removeValue(forKey: stateKey)
        expandedByStateKey.removeValue(forKey: stateKey)
    }

    /// First responder is (or is inside) a collapsible section header button.
    static func focusedStateKey(in window: NSWindow) -> String? {
        stateKey(for: window.firstResponder)
    }

    /// Returns `true` when ←/→ changed section expansion (header must be first responder).
    static func handleArrow(window: NSWindow, event: NSEvent) -> Bool {
        guard event.keyCode == 123 || event.keyCode == 124,
              let stateKey = focusedStateKey(in: window),
              let setExpanded = setExpandedHandlers[stateKey] else { return false }
        let expanded = expandedByStateKey[stateKey] ?? true
        switch event.keyCode {
        case 123 where expanded:
            setExpanded(false)
            return true
        case 124 where !expanded:
            setExpanded(true)
            return true
        default:
            return false
        }
    }

    private static func stateKey(for responder: NSResponder?) -> String? {
        guard let responder else { return nil }
        if let header = responder as? CollapsibleSectionHeaderButton {
            return header.stateKey
        }
        if let view = responder as? NSView {
            var current: NSView? = view
            while let candidate = current {
                if let header = candidate as? CollapsibleSectionHeaderButton {
                    return header.stateKey
                }
                current = candidate.superview
            }
        }
        return nil
    }

    static func headerButton(in view: NSView?) -> CollapsibleSectionHeaderButton? {
        var current = view
        while let candidate = current {
            if let header = candidate as? CollapsibleSectionHeaderButton { return header }
            current = candidate.superview
        }
        return nil
    }
}

/// AppKit section header — key-view loop participant for ←/→ expand/collapse routing.
final class CollapsibleSectionHeaderButton: NSButton {
    let stateKey: String
    var sectionExpanded = true {
        didSet { refreshTitle() }
    }
    var sectionTitle = "" {
        didSet { refreshTitle() }
    }

    init(stateKey: String) {
        self.stateKey = stateKey
        super.init(frame: .zero)
        setButtonType(.momentaryChange)
        isBordered = false
        alignment = .left
        imagePosition = .noImage
        font = NSFont.boldSystemFont(ofSize: 13)
        contentTintColor = NSColor(SettingsDialogChrome.groupBoxTitle)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { isEnabled && !isHidden }
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }

    private func refreshTitle() {
        let prefix = sectionExpanded
            ? SettingsCollapsibleTitlePrefix.expanded
            : SettingsCollapsibleTitlePrefix.collapsed
        title = "\(prefix)\(sectionTitle)"
    }
}

private struct CollapsibleSettingsSectionHeader: NSViewRepresentable {
    let title: String
    let stateKey: String
    let isExpanded: Bool
    let toggle: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(toggle: toggle)
    }

    func makeNSView(context: Context) -> CollapsibleSectionHeaderButton {
        let button = CollapsibleSectionHeaderButton(stateKey: stateKey)
        button.sectionTitle = title
        button.sectionExpanded = isExpanded
        button.target = context.coordinator
        button.action = #selector(Coordinator.click(_:))
        return button
    }

    func updateNSView(_ nsView: CollapsibleSectionHeaderButton, context: Context) {
        context.coordinator.toggle = toggle
        nsView.sectionTitle = title
        nsView.sectionExpanded = isExpanded
    }

    final class Coordinator: NSObject {
        var toggle: () -> Void

        init(toggle: @escaping () -> Void) {
            self.toggle = toggle
        }

        @objc func click(_ sender: Any?) {
            toggle()
        }
    }
}

/// Expand / collapse all controls for settings tabs (`settings_dialog.py` `_make_collapsible_sections_toolbar`).
struct CollapsibleSettingsSectionsToolbar: View {
    let onExpandAll: () -> Void
    let onCollapseAll: () -> Void

    private let buttonSize: CGFloat = 16
    private let iconSize: CGFloat = 12

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            AppAssetIconButton(
                normalName: "series_plus_icon",
                hoverName: "series_plus_icon_hover",
                size: buttonSize,
                iconSize: iconSize,
                tooltip: "Expand all sections",
                action: onExpandAll
            )
            AppAssetIconButton(
                normalName: "series_minus_icon",
                hoverName: "series_minus_icon_hover",
                size: buttonSize,
                iconSize: iconSize,
                tooltip: "Collapse all sections",
                action: onCollapseAll
            )
        }
        .padding(.top, 5)
        .padding(.trailing, 35)
    }
}

/// Settings tab with collapsible groups: toolbar above scroll (`setup_app_settings_tab` layout).
struct SettingsCollapsibleTabLayout<Content: View>: View {
    let onExpandAll: () -> Void
    let onCollapseAll: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            CollapsibleSettingsSectionsToolbar(
                onExpandAll: onExpandAll,
                onCollapseAll: onCollapseAll
            )
            ScrollView {
                content()
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Expandable settings section — port of `CollapsibleThemeGroup`.
struct CollapsibleSettingsSection<Content: View>: View {
    let title: String
    let stateKey: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if isExpanded {
                SettingsOutlinedGroupBox {
                    CollapsibleSettingsSectionHeader(
                        title: title,
                        stateKey: stateKey,
                        isExpanded: true,
                        toggle: { toggleExpanded() }
                    )
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(height: 20)
                    .padding(.horizontal, 4)
                    .background(SettingsDialogChrome.background)
                    .help("Press ← to collapse section")
                } content: {
                    content()
                }
            } else {
                CollapsibleSettingsSectionHeader(
                    title: title,
                    stateKey: stateKey,
                    isExpanded: false,
                    toggle: { toggleExpanded() }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 24)
                .help("Press → to expand section")
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            CollapsibleSettingsSectionKeyboard.register(stateKey: stateKey, isExpanded: isExpanded) { newValue in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded = newValue
                }
            }
        }
        .onChange(of: isExpanded) { _, newValue in
            CollapsibleSettingsSectionKeyboard.syncExpanded(stateKey: stateKey, isExpanded: newValue)
        }
        .onDisappear {
            CollapsibleSettingsSectionKeyboard.unregister(stateKey: stateKey)
        }
    }

    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isExpanded.toggle()
        }
    }
}
