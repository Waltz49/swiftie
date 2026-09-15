import AppKit
import SwiftUI

/// Non-modal preferences dialog — port of Python ``SettingsDialog`` (`setModal(False)`, `.show()`).
@MainActor
final class SettingsDialogController: NSObject, NSWindowDelegate {
    private var settingsWindow: NSWindow?
    private weak var appState: AppState?
    private var inputIsolationMonitors: [Any] = []

    var isVisible: Bool {
        guard let settingsWindow else { return false }
        return settingsWindow.isVisible
    }

    func show(appState: AppState) {
        self.appState = appState
        if let settingsWindow {
            startSettingsSessionIfNeeded(appState)
            installInputIsolation(on: settingsWindow)
            bringSettingsToFront(settingsWindow)
            return
        }

        let view = SettingsWindowView { [weak self] outcome in
            self?.closeFromView(outcome)
        }
        .environment(appState)
        .environment(\.themeColors, appState.theme.colors)

        let host = NSHostingController(rootView: view)
        let window = AuxiliaryDialogWindow(contentViewController: host)
        window.title = "Prowser Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 760, height: 520)
        window.setContentSize(NSSize(width: 920, height: 680))
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("prowser.settings")

        DialogGeometryPersistence.apply(
            to: window,
            config: appState.config,
            key: DialogGeometryKey.settings,
            defaultSize: NSSize(width: 920, height: 680),
            minSize: NSSize(width: 760, height: 520),
            sizeFallbackKey: DialogGeometryKey.settingsSizeFallback
        )

        settingsWindow = window
        startSettingsSessionIfNeeded(appState)
        installInputIsolation(on: window)
        bringSettingsToFront(window)
    }

    private func installInputIsolation(on window: NSWindow) {
        removeInputIsolation()
        if let mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event -> NSEvent? in
                guard let target = event.window,
                      KeyboardHandlerController.isPreferencesWindow(target) else {
                    return event
                }
                Self.ensurePreferencesKey(target)
                let point = target.mouseLocationOutsideOfEventStream
                if let hit = target.contentView?.hitTest(point) {
                    if let header = CollapsibleSettingsSectionKeyboard.headerButton(in: hit) {
                        target.makeFirstResponder(header)
                    } else if let control = Self.adjustableControl(from: hit) {
                        target.makeFirstResponder(control)
                    }
                }
                DispatchQueue.main.async {
                    SettingsScrollFocus.scrollFirstResponderIntoView(in: target)
                }
                return event
            }) {
            inputIsolationMonitors.append(mouseMonitor)
        }
        if let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event -> NSEvent? in
                guard KeyboardHandlerController.isPreferencesWindow(window), window.isVisible else { return event }
                if KeyboardHandlerController.isArrowKeyPublic(event.keyCode),
                   Self.handlePreferencesArrow(window: window, event: event) {
                    DispatchQueue.main.async {
                        SettingsScrollFocus.scrollFirstResponderIntoView(in: window)
                    }
                    return nil
                }
                if event.keyCode == 48 {
                    DispatchQueue.main.async {
                        SettingsScrollFocus.scrollFirstResponderIntoView(in: window)
                    }
                }
                if KeyboardHandlerController.isPreferencesWindow(event.window) {
                    Self.ensurePreferencesKey(window)
                }
                return event
            }) {
            inputIsolationMonitors.append(keyMonitor)
        }
    }

    private func removeInputIsolation() {
        for monitor in inputIsolationMonitors {
            NSEvent.removeMonitor(monitor)
        }
        inputIsolationMonitors = []
    }

    private static func ensurePreferencesKey(_ window: NSWindow) {
        guard !window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
    }

    /// Route ←/→/↑/↓ to section headers (when focused) and sliders/steppers (hit-test or focus).
    private static func handlePreferencesArrow(window: NSWindow, event: NSEvent) -> Bool {
        guard KeyboardHandlerController.isArrowKeyPublic(event.keyCode) else { return false }
        if let responder = window.firstResponder,
           KeyboardHandlerController.isTextEditingResponder(responder) {
            return false
        }

        if CollapsibleSettingsSectionKeyboard.handleArrow(window: window, event: event) {
            return true
        }

        if let control = window.firstResponder as? NSControl,
           isAdjustableControlName(String(describing: type(of: control))),
           applyArrow(to: control, event: event) {
            return true
        }

        let point = window.mouseLocationOutsideOfEventStream

        if let hit = window.contentView?.hitTest(point),
           let target = adjustableControl(from: hit),
           applyArrow(to: target, event: event, focus: true, window: window) {
            return true
        }

        return false
    }

    private static func isAdjustableControlName(_ name: String) -> Bool {
        name.contains("Slider") || name.contains("Stepper") || name.contains("NSSlider")
    }

    @discardableResult
    private static func applyArrow(
        to control: NSControl,
        event: NSEvent,
        focus: Bool = false,
        window: NSWindow? = nil
    ) -> Bool {
        if focus, let window {
            window.makeFirstResponder(control)
        }

        if let slider = control as? NSSlider {
            switch event.keyCode {
            case 123, 125, 124, 126:
                slider.keyDown(with: event)
                return true
            default:
                return false
            }
        }

        if let stepper = control as? NSStepper {
            stepper.keyDown(with: event)
            return true
        }

        control.keyDown(with: event)
        return true
    }

    private static func adjustableControl(from view: NSView) -> NSControl? {
        var current: NSView? = view
        while let candidate = current {
            if let slider = candidate as? NSSlider { return slider }
            if let stepper = candidate as? NSStepper { return stepper }
            let name = String(describing: type(of: candidate))
            if name.contains("Slider") || name.contains("Stepper") {
                if let control = candidate as? NSControl { return control }
            }
            current = candidate.superview
        }
        return nil
    }

    private func startSettingsSessionIfNeeded(_ appState: AppState) {
        guard !appState.config.isSettingsSessionActive else { return }
        appState.config.beginSettingsSession()
        appState.theme.beginSettingsSession()
    }

    private func persistGeometry() {
        guard let window = settingsWindow, let appState else { return }
        DialogGeometryPersistence.saveFrame(
            config: appState.config,
            key: DialogGeometryKey.settings,
            frame: window.frame
        )
    }

    /// OK / Cancel — view already committed or reverted; hide without spurious revert.
    private func closeFromView(_ outcome: SettingsWindowDismissOutcome) {
        persistGeometry()
        settingsWindow?.orderOut(nil)
        _ = outcome
    }

    private func bringSettingsToFront(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindow,
              let appState else { return }
        removeInputIsolation()
        DialogGeometryPersistence.saveFrame(
            config: appState.config,
            key: DialogGeometryKey.settings,
            frame: window.frame
        )
        settingsWindow = nil
        self.appState = nil
    }
}
