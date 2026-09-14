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
        imagePosition = .imageLeading
        font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        refreshTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { isEnabled && !isHidden }
    override var canBecomeKeyView: Bool { isEnabled && !isHidden }

    private func refreshTitle() {
        let symbol = sectionExpanded ? "chevron.down" : "chevron.right"
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        title = " \(sectionTitle)"
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

/// Expandable settings section — port of `CollapsibleThemeGroup`.
struct CollapsibleSettingsSection<Content: View>: View {
    let title: String
    let stateKey: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollapsibleSettingsSectionHeader(
                title: title,
                stateKey: stateKey,
                isExpanded: isExpanded,
                toggle: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(isExpanded ? "Press ← to collapse section" : "Press → to expand section")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    content()
                }
                .padding(.top, 8)
                .padding(.leading, 18)
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
}
