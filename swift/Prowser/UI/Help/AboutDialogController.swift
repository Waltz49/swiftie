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
        let window = AuxiliaryDialogWindow(contentViewController: host)
        window.title = "About Prowser"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.identifier = NSUserInterfaceItemIdentifier(BrowserWindowIdentity.about)
        window.delegate = self
        aboutWindow = window
        fitWindowToContent(window, host: host, config: appState.config, reposition: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, window === self.aboutWindow, let appState = self.appState else { return }
            self.fitWindowToContent(window, host: host, config: appState.config, reposition: false)
        }
    }

    /// Size the About window to the SwiftUI ideal size so a long profile path widens it and wrapping grows it.
    private func fitWindowToContent<Content: View>(
        _ window: NSWindow,
        host: NSHostingController<Content>,
        config: AppConfig,
        reposition: Bool
    ) {
        window.maxSize = NSSize(width: 10_000, height: 10_000)
        window.minSize = NSSize(width: 200, height: 100)
        host.sizingOptions = .intrinsicContentSize
        host.view.layoutSubtreeIfNeeded()

        var size = host.view.intrinsicContentSize
        if size.width <= 1 || size.height <= 1 || !size.width.isFinite || !size.height.isFinite {
            let fitted = host.sizeThatFits(in: CGSize(width: 2_000, height: 2_000))
            size = NSSize(width: fitted.width, height: fitted.height)
        }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        let contentSize = NSSize(
            width: min(max(400, ceil(size.width)), visible.width - 40),
            height: min(max(1, ceil(size.height)), visible.height - 80)
        )
        let previousFrame = window.frame
        window.setContentSize(contentSize)

        if reposition {
            if let stored = DialogGeometryPersistence.loadFrame(config: config, key: DialogGeometryKey.about),
               stored.positionIsKnown {
                var frame = window.frame
                frame.origin.x = stored.x
                frame.origin.y = stored.y + stored.height - frame.size.height
                window.setFrame(
                    DialogGeometryPersistence.clampFrame(frame, minSize: NSSize(width: 400, height: 200)),
                    display: false
                )
            } else {
                window.center()
            }
        } else if previousFrame.width > 1 {
            var frame = window.frame
            frame.origin.x = previousFrame.origin.x
            frame.origin.y = previousFrame.maxY - frame.size.height
            window.setFrame(
                DialogGeometryPersistence.clampFrame(frame, minSize: NSSize(width: 400, height: 200)),
                display: true
            )
        }

        let locked = window.frame.size
        window.minSize = locked
        window.maxSize = locked
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
            defaultSize: NSSize(width: 720, height: 560)
        )
    }

    private func presentAuxiliary(title: String, html: String, defaultSize: NSSize) {
        auxiliaryWindow?.close()
        let view = AboutAuxiliaryHTMLView(html: html) { [weak self] in
            self?.auxiliaryWindow?.close()
        }
        .environment(\.themeColors, appState?.theme.colors ?? .dark)

        let host = NSHostingController(rootView: view)
        let window = AuxiliaryDialogWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.identifier = NSUserInterfaceItemIdentifier(BrowserWindowIdentity.dialogPrefix + "about.\(title.lowercased())")
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
