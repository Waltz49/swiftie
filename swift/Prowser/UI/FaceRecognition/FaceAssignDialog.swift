import AppKit
import Foundation

struct FaceAssignResult: Sendable {
    var name: String
    var imagePath: String
    var embedding: [Double]
}

/// Port of `settings_dialog.FaceAssignDialog` — assign detected faces to known people.
@MainActor
enum FaceAssignDialog {
    static func present(
        imagePath: String,
        detections: [FaceEngine.FaceDetection],
        subjects: [KnownFacesStore.Subject]
    ) async -> [FaceAssignResult]? {
        guard let cgImage = ImageRecognitionImageLoader.loadCGImage(path: imagePath) else { return nil }

        return await withCheckedContinuation { continuation in
            var resumed = false
            var panel: NSPanel!
            @MainActor func finish(_ value: [FaceAssignResult]?) {
                guard !resumed else { return }
                resumed = true
                panel.close()
                continuation.resume(returning: value)
            }

            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Assign faces"
            panel.isFloatingPanel = true
            panel.level = .modalPanel

            let header = NSTextField(wrappingLabelWithString: "Click a face label to rename it.")
            header.translatesAutoresizingMaskIntoConstraints = false

            var faceStates: [FaceAssignFaceState] = detections.map { det in
                let primed = primeFaceDisplayName(embedding: det.encoding, subjects: subjects)
                return FaceAssignFaceState(
                    detection: det,
                    displayName: primed ?? FaceAssignPlaceholder.add
                )
            }

            let canvas = FaceAssignCanvasView(cgImage: cgImage, faceStates: faceStates)
            canvas.translatesAutoresizingMaskIntoConstraints = false
            canvas.onStatesChanged = { faceStates = $0 }

            let cancelButton = FocusableDialogButton(title: "Cancel", target: nil, action: nil)
            let okButton = FocusableDialogButton(title: "OK", target: nil, action: nil)
            okButton.keyEquivalent = "\r"
            cancelButton.keyEquivalent = "\u{1b}"

            let buttonRow = NSStackView(views: [cancelButton, okButton])
            buttonRow.orientation = .horizontal
            buttonRow.spacing = 12
            buttonRow.alignment = .centerY
            buttonRow.distribution = .gravityAreas
            buttonRow.translatesAutoresizingMaskIntoConstraints = false

            let content = NSView()
            content.addSubview(header)
            content.addSubview(canvas)
            content.addSubview(buttonRow)
            panel.contentView = content

            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
                header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                canvas.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
                canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                canvas.heightAnchor.constraint(equalToConstant: 420),
                buttonRow.topAnchor.constraint(equalTo: canvas.bottomAnchor, constant: 12),
                buttonRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                buttonRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            ])

            let session = FaceAssignDialogSession(
                onCancel: { Task { @MainActor in finish(nil) } },
                onOK: {
                    canvas.finishPendingEdit()
                    let results: [FaceAssignResult] = faceStates.compactMap { st in
                        let name = st.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if name.isEmpty || name == FaceAssignPlaceholder.add { return nil }
                        return FaceAssignResult(name: name, imagePath: imagePath, embedding: st.detection.encoding)
                    }
                    if results.isEmpty {
                        StyledMessageDialog.showWarning(
                            title: "Missing name",
                            message: "Please name at least one face (or leave the others as \"\(FaceAssignPlaceholder.add)\")."
                        )
                        return
                    }
                    Task { @MainActor in finish(results) }
                }
            )
            canvas.retainedActionTargets = [session]
            cancelButton.target = session.cancelTarget
            cancelButton.action = #selector(BlockTarget.invoke)
            okButton.target = session.okTarget
            okButton.action = #selector(BlockTarget.invoke)

            if detections.isEmpty {
                okButton.isEnabled = false
            }

            _ = AppKitDialogKeyboardNavigation.install(
                on: panel,
                buttonsLeftToRight: [cancelButton, okButton],
                escapeButton: cancelButton
            )

            panel.center()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(okButton.isEnabled ? okButton : cancelButton)
        }
    }

    private static func primeFaceDisplayName(
        embedding: [Double],
        subjects: [KnownFacesStore.Subject]
    ) -> String? {
        for subject in subjects {
            let name = subject.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let known = subject.samples.map(\.embedding).filter { $0.count == 128 }
            guard !known.isEmpty else { continue }
            if FaceEngine.compareFaces(knownEncodings: known, unknownEncoding: embedding) {
                return name
            }
        }
        return nil
    }
}

struct FaceAssignFaceState {
    var detection: FaceEngine.FaceDetection
    var displayName: String
}

private final class FaceAssignDialogSession: NSObject {
    let cancelTarget: BlockTarget
    let okTarget: BlockTarget

    init(onCancel: @escaping () -> Void, onOK: @escaping () -> Void) {
        cancelTarget = BlockTarget(onCancel)
        okTarget = BlockTarget(onOK)
    }
}

private final class FaceAssignCanvasView: NSView, NSTextFieldDelegate {
    let cgImage: CGImage
    var faceStates: [FaceAssignFaceState]
    var onStatesChanged: (([FaceAssignFaceState]) -> Void)?
    /// Keeps button targets alive (`NSButton` holds its target weakly).
    var retainedActionTargets: [NSObject] = []

    private var editingIndex: Int?
    private var editField: NSTextField?

    init(cgImage: CGImage, faceStates: [FaceAssignFaceState]) {
        self.cgImage = cgImage
        self.faceStates = faceStates
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func finishPendingEdit() {
        commitEdit(emitFocus: false)
    }

    override func draw(_ dirtyRect: NSRect) {
        let layout = FaceImageOverlayLayout.compute(
            viewBounds: bounds,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height
        )
        if let ctx = NSGraphicsContext.current?.cgContext {
            FaceImageOverlayLayout.drawCGImageTopLeft(cgImage, in: layout.imageDrawRect, context: ctx)
        }
        let border = NSColor.controlAccentColor
        let labelFont = NSFont.systemFont(ofSize: 13)
        for (index, st) in faceStates.enumerated() {
            let box = layout.faceBoxRect(
                top: st.detection.location.top,
                right: st.detection.location.right,
                bottom: st.detection.location.bottom,
                left: st.detection.location.left
            )
            border.setStroke()
            NSBezierPath(rect: box).lineWidth = 2
            NSBezierPath(rect: box).stroke()

            if editingIndex == index, editField != nil {
                continue
            }

            let labelH: CGFloat = 24
            let labelRect = CGRect(x: box.minX, y: box.maxY + 2, width: max(box.width, 80), height: labelH)
            NSColor.controlBackgroundColor.withAlphaComponent(0.88).setFill()
            NSBezierPath(rect: labelRect).fill()
            let text = Self.faceLabelDisplayText(st.displayName)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: labelFont,
                .foregroundColor: NSColor.labelColor,
            ]
            (text as NSString).draw(
                in: labelRect.insetBy(dx: 4, dy: 4),
                withAttributes: attrs
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let layout = FaceImageOverlayLayout.compute(
            viewBounds: bounds,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height
        )
        if editField != nil {
            if let idx = faceIndex(at: point, layout: layout) {
                commitEdit(emitFocus: false)
                beginEdit(index: idx, layout: layout)
            } else {
                commitEdit(emitFocus: true)
            }
            return
        }
        guard let idx = faceIndex(at: point, layout: layout) else { return }
        beginEdit(index: idx, layout: layout)
    }

    private func faceIndex(at point: CGPoint, layout: FaceImageOverlayLayout) -> Int? {
        for (index, st) in faceStates.enumerated().reversed() {
            let box = layout.faceBoxRect(
                top: st.detection.location.top,
                right: st.detection.location.right,
                bottom: st.detection.location.bottom,
                left: st.detection.location.left
            )
            let labelRect = CGRect(x: box.minX, y: box.maxY + 2, width: max(box.width, 80), height: 24)
            if labelRect.contains(point) || box.contains(point) {
                return index
            }
        }
        return nil
    }

    private static func faceLabelDisplayText(_ displayName: String) -> String {
        if displayName.isEmpty || displayName == FaceAssignPlaceholder.add {
            return FaceAssignPlaceholder.add
        }
        return displayName
    }

    private func beginEdit(index: Int, layout: FaceImageOverlayLayout) {
        guard index >= 0, index < faceStates.count else { return }
        editingIndex = index
        needsDisplay = true
        let st = faceStates[index]
        let box = layout.faceBoxRect(
            top: st.detection.location.top,
            right: st.detection.location.right,
            bottom: st.detection.location.bottom,
            left: st.detection.location.left
        )
        let labelRect = CGRect(x: box.minX, y: box.maxY + 2, width: max(box.width, 80), height: 24)
        let field = NSTextField(frame: labelRect)
        field.isBordered = true
        field.isBezeled = true
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        let isPlaceholder = st.displayName.isEmpty || st.displayName == FaceAssignPlaceholder.add
        field.stringValue = isPlaceholder ? "" : st.displayName
        field.placeholderString = isPlaceholder ? FaceAssignPlaceholder.add : ""
        addSubview(field)
        editField = field
        field.becomeFirstResponder()
        applyEditFieldAppearance(field)
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: field.stringValue.utf16.count)
    }

    private func applyEditFieldAppearance(_ field: NSTextField) {
        field.drawsBackground = true
        field.backgroundColor = .black
        field.textColor = .white
        if let placeholder = field.placeholderString, !placeholder.isEmpty {
            field.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [
                    .foregroundColor: NSColor.gray,
                    .font: field.font ?? .systemFont(ofSize: 13),
                ]
            )
        }
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.drawsBackground = true
        editor.backgroundColor = .black
        editor.textColor = .white
        editor.insertionPointColor = .white
        editor.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.white,
        ]
    }

    private func commitEdit(emitFocus: Bool) {
        guard let field = editField, let idx = editingIndex else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        faceStates[idx].displayName = text.isEmpty ? FaceAssignPlaceholder.add : text
        onStatesChanged?(faceStates)
        field.removeFromSuperview()
        editField = nil
        editingIndex = nil
        needsDisplay = true
        if emitFocus { window?.makeFirstResponder(self) }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        applyEditFieldAppearance(field)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitEdit(emitFocus: true)
    }
}

private final class BlockTarget: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func invoke() { block() }
}
