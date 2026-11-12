import AppKit
import ImageIO

/// Confirmation and downsize dialogs for Create Screen Size Copy (Python `create_screen_size_copy`).
@MainActor
enum ScreenSizeCopyDialogController {
    struct ConfirmResult {
        var fitMethod: ScreenSizeCopyService.FitMethod
        var preserveDates: Bool
        var deleteOriginals: Bool
        var bordersOnCopy: Bool
    }

    struct DownsizeResult {
        var shouldContinue: Bool
        var applyToAll: Bool
    }

    static func presentConfirm(
        filesToProcess: [String],
        initialFitMethod: ScreenSizeCopyService.FitMethod,
        defaultPreserveDates: Bool,
        defaultDeleteOriginals: Bool,
        defaultBordersOnCopy: Bool,
        ignoreExifRotation: Bool,
        parentWindow: NSWindow? = nil
    ) -> ConfirmResult? {
        let controller = ConfirmPanel(
            filesToProcess: filesToProcess,
            initialFitMethod: initialFitMethod,
            defaultPreserveDates: defaultPreserveDates,
            defaultDeleteOriginals: defaultDeleteOriginals,
            defaultBordersOnCopy: defaultBordersOnCopy,
            ignoreExifRotation: ignoreExifRotation
        )
        controller.runModal(parentWindow: parentWindow)
        return controller.result
    }

    static func presentDownsizeWarning(
        imagePath: String,
        ignoreExifRotation: Bool,
        parentWindow: NSWindow? = nil
    ) -> DownsizeResult {
        let controller = DownsizePanel(imagePath: imagePath, ignoreExifRotation: ignoreExifRotation)
        controller.runModal(parentWindow: parentWindow)
        return controller.result
    }

    private static func loadPreviewImage(path: String, ignoreExifRotation: Bool) -> NSImage? {
        let maxPixel = 96
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        var options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
        ]
        if !ignoreExifRotation {
            options[kCGImageSourceCreateThumbnailWithTransform] = true
        }
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let display = ThumbnailTransparencyCompositor.compositeOntoCheckerboardIfNeeded(cgImage)
        let size = NSSize(width: display.width, height: display.height)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.cgContext.draw(display, in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
    }

    @MainActor
    private final class ConfirmPanel: NSObject, NSWindowDelegate {
        private struct FitItem {
            let method: ScreenSizeCopyService.FitMethod
            let title: String
        }

        private let filesToProcess: [String]
        private let ignoreExifRotation: Bool
        private let panel: NSPanel
        private let summaryLabel: NSTextField
        private let fitPopup: NSPopUpButton
        private let preserveDatesCheckbox: NSButton
        private let deleteOriginalsCheckbox: NSButton
        private let bordersCheckbox: NSButton
        private let buttonsLeftToRight: [NSButton]
        private let escapeButton: NSButton
        private weak var sheetParent: NSWindow?
        private(set) var result: ConfirmResult?

        private let fitItems: [FitItem] = [
            FitItem(method: .contain, title: "Fit (Contain)"),
            FitItem(method: .cover, title: "Fill (Cover)"),
            FitItem(method: .width, title: "Fit to Width"),
            FitItem(method: .height, title: "Fit to Height"),
        ]

        init(
            filesToProcess: [String],
            initialFitMethod: ScreenSizeCopyService.FitMethod,
            defaultPreserveDates: Bool,
            defaultDeleteOriginals: Bool,
            defaultBordersOnCopy: Bool,
            ignoreExifRotation: Bool
        ) {
            self.filesToProcess = filesToProcess
            self.ignoreExifRotation = ignoreExifRotation

            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Create screen size copy"
            panel.isFloatingPanel = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .modalPanel
            panel.minSize = NSSize(width: 360, height: 280)

            summaryLabel = NSTextField(wrappingLabelWithString: "")
            summaryLabel.isSelectable = true
            summaryLabel.lineBreakMode = .byWordWrapping

            fitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            for item in fitItems {
                fitPopup.addItem(withTitle: item.title)
            }
            if let idx = fitItems.firstIndex(where: { $0.method == initialFitMethod }) {
                fitPopup.selectItem(at: idx)
            }

            preserveDatesCheckbox = NSButton(
                checkboxWithTitle: "Preserve dates (copy original modification date to new files)",
                target: nil,
                action: nil
            )
            preserveDatesCheckbox.state = defaultPreserveDates ? .on : .off

            deleteOriginalsCheckbox = NSButton(
                checkboxWithTitle: "Delete originals after creating copies",
                target: nil,
                action: nil
            )
            deleteOriginalsCheckbox.state = defaultDeleteOriginals ? .on : .off

            bordersCheckbox = NSButton(
                checkboxWithTitle: "Add borders to pad the image to the screen size",
                target: nil,
                action: nil
            )
            bordersCheckbox.state = defaultBordersOnCopy ? .on : .off
            bordersCheckbox.toolTip =
                "Create Screen Size Copy will add borders to pad the image to the screen size "
                + "for images with a different aspect ratio than the screen"

            let cancelButton = FocusableDialogButton(title: "Cancel", target: nil, action: nil)
            let resizeButton = FocusableDialogButton(title: "Resize", target: nil, action: nil)
            for button in [cancelButton, resizeButton] {
                button.bezelStyle = .rounded
                button.focusRingType = .default
            }
            buttonsLeftToRight = [cancelButton, resizeButton]
            escapeButton = cancelButton
            cancelButton.nextKeyView = resizeButton
            resizeButton.nextKeyView = cancelButton

            let content = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 12
            column.translatesAutoresizingMaskIntoConstraints = false

            column.addArrangedSubview(summaryLabel)

            let fitRow = NSStackView()
            fitRow.orientation = .horizontal
            fitRow.spacing = 8
            fitRow.addArrangedSubview(NSTextField(labelWithString: "Fit mode:"))
            fitRow.addArrangedSubview(fitPopup)
            column.addArrangedSubview(fitRow)

            column.addArrangedSubview(preserveDatesCheckbox)
            column.addArrangedSubview(deleteOriginalsCheckbox)
            column.addArrangedSubview(bordersCheckbox)

            let buttonRow = NSStackView()
            buttonRow.orientation = .horizontal
            buttonRow.spacing = 8
            buttonRow.addArrangedSubview(NSView())
            for button in buttonsLeftToRight {
                buttonRow.addArrangedSubview(button)
            }
            column.addArrangedSubview(buttonRow)
            buttonRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

            content.addSubview(column)
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            ])
            panel.contentView = content
            cancelButton.keyEquivalent = "\r"
            panel.initialFirstResponder = cancelButton

            super.init()
            panel.delegate = self
            cancelButton.tag = 0
            resizeButton.tag = 1
            for button in buttonsLeftToRight {
                button.target = self
                button.action = #selector(buttonPressed(_:))
            }
            fitPopup.target = self
            fitPopup.action = #selector(refreshSummary)
            bordersCheckbox.target = self
            bordersCheckbox.action = #selector(refreshSummary)
            refreshSummary()
        }

        func runModal(parentWindow: NSWindow?) {
            let monitor = AppKitDialogKeyboardNavigation.install(
                on: panel,
                buttonsLeftToRight: buttonsLeftToRight,
                escapeButton: escapeButton,
                hasTextAccessory: false
            )
            defer {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
            }

            panel.center()
            NSApp.activate(ignoringOtherApps: true)
            if let parentWindow {
                sheetParent = parentWindow
                parentWindow.makeKeyAndOrderFront(nil)
                parentWindow.beginSheet(panel) { [weak self] _ in
                    self?.sheetParent = nil
                }
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
            panel.makeFirstResponder(panel.initialFirstResponder ?? escapeButton)
            NSApp.runModal(for: panel)
        }

        @objc private func refreshSummary() {
            let (_, borders) = currentChoices()
            let needing = ScreenSizeCopyService.filesNeedingResize(
                paths: filesToProcess,
                bordersOnCopy: borders,
                ignoreExifRotation: ignoreExifRotation
            )
            let count = needing.count
            let total = filesToProcess.count
            let word = RenamePrefixPlanner.fileString(count)
            var text = "Create screen-sized copies for \(count) \(word)?"
            if count < total {
                text += " (\(total - count) already at target size)"
            }
            summaryLabel.stringValue = text
        }

        private func currentChoices() -> (ScreenSizeCopyService.FitMethod, Bool) {
            let idx = fitPopup.indexOfSelectedItem
            let method: ScreenSizeCopyService.FitMethod
            if idx >= 0, idx < fitItems.count {
                method = fitItems[idx].method
            } else {
                method = .cover
            }
            let borders = bordersCheckbox.state == .on
            return (method, borders)
        }

        @objc private func buttonPressed(_ sender: NSButton) {
            if sender.tag == 1 {
                let (fitMethod, borders) = currentChoices()
                result = ConfirmResult(
                    fitMethod: fitMethod,
                    preserveDates: preserveDatesCheckbox.state == .on,
                    deleteOriginals: deleteOriginalsCheckbox.state == .on,
                    bordersOnCopy: borders
                )
            } else {
                result = nil
            }
            close()
        }

        private func close() {
            if let parent = sheetParent {
                parent.endSheet(panel)
                sheetParent = nil
            } else {
                panel.orderOut(nil)
            }
            NSApp.stopModal()
            BrowserWindowIdentity.restoreBrowserKeyAfterAuxiliaryDialog()
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            result = nil
            close()
            return false
        }
    }

    @MainActor
    private final class DownsizePanel: NSObject, NSWindowDelegate {
        private let panel: NSPanel
        private let applyToAllCheckbox: NSButton
        private let buttonsLeftToRight: [NSButton]
        private let escapeButton: NSButton
        private weak var sheetParent: NSWindow?
        private(set) var result = DownsizeResult(shouldContinue: false, applyToAll: false)

        init(imagePath: String, ignoreExifRotation: Bool) {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Downsize warning"
            panel.isFloatingPanel = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .modalPanel

            let filename = (imagePath as NSString).lastPathComponent
            let message =
                "\(filename)\n\n"
                + "This image is larger than the screen. Creating a copy will reduce its resolution."

            let content = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 12
            column.translatesAutoresizingMaskIntoConstraints = false

            let topRow = NSStackView()
            topRow.orientation = .horizontal
            topRow.spacing = 14
            let textLabel = NSTextField(wrappingLabelWithString: message)
            textLabel.isSelectable = true
            textLabel.lineBreakMode = .byWordWrapping
            topRow.addArrangedSubview(textLabel)

            let thumbView = NSImageView()
            thumbView.imageScaling = .scaleProportionallyUpOrDown
            thumbView.translatesAutoresizingMaskIntoConstraints = false
            if let image = ScreenSizeCopyDialogController.loadPreviewImage(path: imagePath, ignoreExifRotation: ignoreExifRotation) {
                thumbView.image = image
            } else {
                thumbView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            }
            NSLayoutConstraint.activate([
                thumbView.widthAnchor.constraint(equalToConstant: 96),
                thumbView.heightAnchor.constraint(equalToConstant: 96),
            ])
            topRow.addArrangedSubview(thumbView)
            column.addArrangedSubview(topRow)

            applyToAllCheckbox = NSButton(checkboxWithTitle: "Apply to all files", target: nil, action: nil)
            column.addArrangedSubview(applyToAllCheckbox)

            let skipButton = FocusableDialogButton(title: "Skip", target: nil, action: nil)
            let continueButton = FocusableDialogButton(title: "Continue", target: nil, action: nil)
            for button in [skipButton, continueButton] {
                button.bezelStyle = .rounded
                button.focusRingType = .default
            }
            buttonsLeftToRight = [skipButton, continueButton]
            escapeButton = skipButton
            skipButton.nextKeyView = continueButton
            continueButton.nextKeyView = skipButton

            let buttonRow = NSStackView()
            buttonRow.orientation = .horizontal
            buttonRow.spacing = 8
            buttonRow.addArrangedSubview(NSView())
            for button in buttonsLeftToRight {
                buttonRow.addArrangedSubview(button)
            }
            column.addArrangedSubview(buttonRow)
            buttonRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

            content.addSubview(column)
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            ])
            panel.contentView = content
            skipButton.keyEquivalent = "\r"
            panel.initialFirstResponder = skipButton

            super.init()
            panel.delegate = self
            skipButton.tag = 0
            continueButton.tag = 1
            for button in buttonsLeftToRight {
                button.target = self
                button.action = #selector(buttonPressed(_:))
            }
        }

        func runModal(parentWindow: NSWindow?) {
            let monitor = AppKitDialogKeyboardNavigation.install(
                on: panel,
                buttonsLeftToRight: buttonsLeftToRight,
                escapeButton: escapeButton,
                hasTextAccessory: false
            )
            defer {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
            }

            panel.center()
            NSApp.activate(ignoringOtherApps: true)
            if let parentWindow {
                sheetParent = parentWindow
                parentWindow.makeKeyAndOrderFront(nil)
                parentWindow.beginSheet(panel) { [weak self] _ in
                    self?.sheetParent = nil
                }
            } else {
                panel.makeKeyAndOrderFront(nil)
            }
            panel.makeFirstResponder(panel.initialFirstResponder ?? escapeButton)
            NSApp.runModal(for: panel)
        }

        @objc private func buttonPressed(_ sender: NSButton) {
            let accepted = sender.tag == 1
            result = DownsizeResult(
                shouldContinue: accepted,
                applyToAll: applyToAllCheckbox.state == .on
            )
            close()
        }

        private func close() {
            if let parent = sheetParent {
                parent.endSheet(panel)
                sheetParent = nil
            } else {
                panel.orderOut(nil)
            }
            NSApp.stopModal()
            BrowserWindowIdentity.restoreBrowserKeyAfterAuxiliaryDialog()
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            result = DownsizeResult(shouldContinue: false, applyToAll: applyToAllCheckbox.state == .on)
            close()
            return false
        }
    }
}
