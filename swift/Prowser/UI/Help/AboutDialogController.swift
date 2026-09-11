import AppKit
import SwiftUI

/// Non-modal About window — port of Python ``present_auxiliary_dialog(AboutDialog())``.
@MainActor
final class AboutDialogController: NSObject, NSWindowDelegate {
    private var aboutWindow: NSWindow?
    private var auxiliaryWindow: NSWindow?
    private weak var appState: AppState?

    var isVisible: Bool { aboutWindow != nil }

    func show(appState: AppState) {
        self.appState = appState
        if let aboutWindow {
            aboutWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let host = NSHostingController(
            rootView: AboutView(
                onShowLicense: { [weak self] in self?.showLicense() },
                onShowCredits: { [weak self] in self?.showCredits() }
            )
            .environment(appState)
            .environment(\.themeColors, appState.theme.colors)
        )
        let window = NSWindow(contentViewController: host)
        window.title = "About Prowser"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.minSize = NSSize(width: 400, height: 420)
        window.setContentSize(NSSize(width: 440, height: 480))
        window.isReleasedWhenClosed = false
        window.delegate = self
        aboutWindow = window
        DialogGeometryPersistence.apply(
            to: window,
            config: appState.config,
            key: DialogGeometryKey.about,
            defaultSize: NSSize(width: 440, height: 480),
            minSize: NSSize(width: 400, height: 420)
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        auxiliaryWindow?.close()
        aboutWindow?.close()
    }

    func showCredits() {
        guard let appState else { return }
        presentAuxiliary(
            title: "Credits",
            html: AboutHTMLContent.creditsHTML(settings: appState.config.rawSettings()),
            defaultSize: NSSize(width: 640, height: 420)
        )
    }

    func showLicense() {
        guard let appState else { return }
        presentAuxiliary(
            title: "License",
            html: AboutHTMLContent.licenseHTML(settings: appState.config.rawSettings()),
            defaultSize: NSSize(width: 640, height: 420)
        )
    }

    private func presentAuxiliary(title: String, html: String, defaultSize: NSSize) {
        auxiliaryWindow?.close()
        let view = AboutAuxiliaryHTMLView(html: html) { [weak self] in
            self?.auxiliaryWindow?.close()
        }
        .environment(\.themeColors, appState?.theme.colors ?? .dark)

        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(defaultSize)
        window.minSize = defaultSize
        if let aboutWindow {
            window.setFrameOrigin(
                NSPoint(
                    x: aboutWindow.frame.midX - defaultSize.width / 2,
                    y: aboutWindow.frame.midY - defaultSize.height / 2
                )
            )
        } else {
            window.center()
        }
        auxiliaryWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === aboutWindow {
            if let appState {
                DialogGeometryPersistence.saveFrame(
                    config: appState.config,
                    key: DialogGeometryKey.about,
                    frame: window.frame
                )
            }
            aboutWindow = nil
            auxiliaryWindow?.close()
            auxiliaryWindow = nil
            appState = nil
        } else if window === auxiliaryWindow {
            auxiliaryWindow = nil
        }
    }
}

private struct AboutAuxiliaryHTMLView: View {
    let html: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            AboutHTMLWebView(html: html)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            DialogButtonRow([
                DialogButton("Close", isDefault: true, isCancel: true, action: onClose),
            ], focusDefaultOnAppear: true)
        }
        .padding(12)
        .frame(minWidth: 640, minHeight: 420)
        .themeDialogStyle()
    }
}
