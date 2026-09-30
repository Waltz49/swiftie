import AppKit
import ImageIO

/// Port of `FileMoveHandler.show_overwrite_dialog` in `files/file_move_handler.py`.
@MainActor
enum FileAlreadyExistsDialogController {
    struct PresentResult {
        let choice: FileMoveConflictResolver.ConflictChoice
        let applyToAll: Bool
    }

    private static let previewSize = 96

    static func present(
        sourcePath: String,
        targetPath: String,
        parentWindow: NSWindow? = nil
    ) -> PresentResult {
        let controller = PanelController(sourcePath: sourcePath, targetPath: targetPath)
        controller.runModal(parentWindow: parentWindow)
        return PresentResult(choice: controller.resolvedChoice, applyToAll: controller.resolvedApplyToAll)
    }

    private static func loadPreviewImage(path: String) -> NSImage? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: previewSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
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

    private static func previewColumn(path: String, caption: String) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 6

        let cap = NSTextField(labelWithString: caption)
        cap.alignment = .center
        column.addArrangedSubview(cap)

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        if let image = loadPreviewImage(path: path) {
            imageView.image = image
        } else {
            imageView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        }
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: CGFloat(previewSize)),
            imageView.heightAnchor.constraint(equalToConstant: CGFloat(previewSize)),
        ])
        column.addArrangedSubview(imageView)
        return column
    }

    @MainActor
    private final class PanelController: NSObject, NSWindowDelegate {
        private(set) var resolvedChoice: FileMoveConflictResolver.ConflictChoice = .skip
        private(set) var resolvedApplyToAll = false

        private let panel: NSPanel
        private let applyToAllCheckbox: NSButton
        private let buttonsLeftToRight: [NSButton]
        private let escapeButton: NSButton
        private weak var sheetParent: NSWindow?

        init(sourcePath: String, targetPath: String) {
            let filename = (sourcePath as NSString).lastPathComponent
            let targetDirectory = (targetPath as NSString).deletingLastPathComponent
            let normalizedDir = (targetDirectory as NSString).standardizingPath
            var dirName = (normalizedDir as NSString).lastPathComponent
            if dirName.isEmpty {
                dirName = normalizedDir.isEmpty ? targetDirectory : normalizedDir
            }
            let message =
                "A file named '\(filename)' already exists in '\(dirName)'.\n\nDo you want to replace it?"

            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "File Already Exists"
            panel.isFloatingPanel = false
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .modalPanel
            panel.minSize = NSSize(width: 420, height: 280)

            let content = NSView()
            content.translatesAutoresizingMaskIntoConstraints = false

            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 15
            column.translatesAutoresizingMaskIntoConstraints = false

            let previewRow = NSStackView()
            previewRow.orientation = .horizontal
            previewRow.spacing = 14
            previewRow.addArrangedSubview(FileAlreadyExistsDialogController.previewColumn(path: sourcePath, caption: "Source"))
            previewRow.addArrangedSubview(FileAlreadyExistsDialogController.previewColumn(path: targetPath, caption: "Existing"))
            column.addArrangedSubview(previewRow)

            let messageLabel = NSTextField(wrappingLabelWithString: message)
            messageLabel.isSelectable = true
            messageLabel.lineBreakMode = .byWordWrapping
            messageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            column.addArrangedSubview(messageLabel)

            applyToAllCheckbox = NSButton(checkboxWithTitle: "Apply to all", target: nil, action: nil)
            applyToAllCheckbox.state = .off
            applyToAllCheckbox.toolTip = "Apply this action to all files in the operation"
            column.addArrangedSubview(applyToAllCheckbox)

            let cancelButton = FocusableDialogButton(title: "Cancel", target: nil, action: nil)
            let skipButton = FocusableDialogButton(title: "Skip", target: nil, action: nil)
            let replaceButton = FocusableDialogButton(title: "Replace", target: nil, action: nil)
            let renameButton = FocusableDialogButton(title: "Rename", target: nil, action: nil)
            for button in [cancelButton, skipButton, replaceButton, renameButton] {
                button.bezelStyle = .rounded
                button.focusRingType = .default
            }
            buttonsLeftToRight = [cancelButton, skipButton, replaceButton, renameButton]
            escapeButton = cancelButton

            for index in 0 ..< buttonsLeftToRight.count - 1 {
                buttonsLeftToRight[index].nextKeyView = buttonsLeftToRight[index + 1]
            }
            buttonsLeftToRight[buttonsLeftToRight.count - 1].nextKeyView = buttonsLeftToRight[0]

            let buttonRow = NSStackView()
            buttonRow.orientation = .horizontal
            buttonRow.alignment = .centerY
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

            renameButton.keyEquivalent = "\r"
            panel.initialFirstResponder = renameButton

            super.init()

            panel.delegate = self
            cancelButton.tag = 0
            skipButton.tag = 1
            replaceButton.tag = 2
            renameButton.tag = 3
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
            if let first = panel.initialFirstResponder ?? buttonsLeftToRight.last {
                panel.makeFirstResponder(first)
            }
            NSApp.runModal(for: panel)
        }

        @objc private func buttonPressed(_ sender: NSButton) {
            switch sender.tag {
            case 0: resolvedChoice = .cancelAll
            case 1: resolvedChoice = .skip
            case 2: resolvedChoice = .replace
            case 3: resolvedChoice = .rename
            default: resolvedChoice = .skip
            }
            resolvedApplyToAll = applyToAllCheckbox.state == .on
            close()
        }

        private func close() {
            if let sheetParent {
                sheetParent.endSheet(panel)
                self.sheetParent = nil
            } else {
                panel.orderOut(nil)
            }
            NSApp.stopModal()
            BrowserWindowIdentity.restoreBrowserKeyAfterAuxiliaryDialog()
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            resolvedChoice = .cancelAll
            resolvedApplyToAll = applyToAllCheckbox.state == .on
            close()
            return false
        }
    }
}
