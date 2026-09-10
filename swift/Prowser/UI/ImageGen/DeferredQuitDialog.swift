import AppKit

/// Modal progress dialog during deferred quit (Python ``_show_deferred_quit_dialog``).
@MainActor
final class DeferredQuitDialog {
    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var toggleButton: NSButton?
    private weak var imageGen: ImageGenController?

    func show(imageGen: ImageGenController, appState: AppState) {
        dismiss()
        self.imageGen = imageGen

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Shutting down"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.level = .modalPanel
        panel.isReleasedWhenClosed = false

        let content = NSView(frame: panel.contentView?.bounds ?? .zero)
        content.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: imageGen.deferredQuitStatusMessage())
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 0
        status.translatesAutoresizingMaskIntoConstraints = false
        statusLabel = status

        let stripHost = NSHostingController(
            rootView: ActiveJobStripView().environment(appState)
        )
        let stripView = stripHost.view
        stripView.translatesAutoresizingMaskIntoConstraints = false

        let toggle = NSButton(title: imageGen.deferredQuitToggleButtonLabel(), target: self, action: #selector(toggleMode))
        toggle.bezelStyle = .rounded
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.isHidden = !imageGen.deferredQuitShowWaitForAllOption()
        toggleButton = toggle

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\r"
        cancel.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [toggle, NSView(), cancel])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(status)
        content.addSubview(stripView)
        content.addSubview(buttonRow)

        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            stripView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 12),
            stripView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stripView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            buttonRow.topAnchor.constraint(equalTo: stripView.bottomAnchor, constant: 16),
            buttonRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            toggle.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])

        panel.contentView = content
        window = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh(imageGen: ImageGenController) {
        statusLabel?.stringValue = imageGen.deferredQuitStatusMessage()
        let showToggle = imageGen.deferredQuitShowWaitForAllOption()
        toggleButton?.isHidden = !showToggle
        if showToggle {
            toggleButton?.title = imageGen.deferredQuitToggleButtonLabel()
        }
    }

    func dismiss() {
        window?.close()
        window = nil
        statusLabel = nil
        toggleButton = nil
        imageGen = nil
    }

    @objc private func toggleMode() {
        guard let imageGen else { return }
        imageGen.toggleDeferredQuitMode()
        refresh(imageGen: imageGen)
    }

    @objc private func cancel() {
        imageGen?.cancelDeferredQuit()
        dismiss()
    }
}

import SwiftUI
