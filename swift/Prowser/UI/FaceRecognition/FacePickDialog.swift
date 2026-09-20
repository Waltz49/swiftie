import AppKit
import Foundation

/// Multi-face picker (port of `quick_person_search._FacePickCanvas`).
@MainActor
enum FacePickDialog {
    static func present(imagePath: String, detections: [FaceEngine.FaceDetection]) async -> FaceEngine.FaceDetection? {
        guard let cgImage = ImageRecognitionImageLoader.loadCGImage(path: imagePath) else { return nil }

        return await withCheckedContinuation { continuation in
            var retainedTargets: [NSObject] = []
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Choose face — Quick Person Search"
            let label = NSTextField(labelWithString: "Click the face to use for Quick Person Search.")
            label.translatesAutoresizingMaskIntoConstraints = false

            let imageView = FaceDetectionOverlayView(cgImage: cgImage, detections: detections)
            imageView.translatesAutoresizingMaskIntoConstraints = false

            let cancel = FocusableDialogButton(title: "Cancel", target: nil, action: nil)
            let stack = NSStackView(views: [label, imageView, cancel])
            stack.orientation = .vertical
            stack.spacing = 12
            stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
            stack.translatesAutoresizingMaskIntoConstraints = false
            panel.contentView = NSView()
            panel.contentView?.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
                stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
                stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
                imageView.heightAnchor.constraint(equalToConstant: 380),
            ])

            var resumed = false
            func finish(_ value: FaceEngine.FaceDetection?) {
                guard !resumed else { return }
                resumed = true
                panel.close()
                continuation.resume(returning: value)
            }

            imageView.onPick = { finish($0) }
            let cancelTarget = BlockTarget { finish(nil) }
            retainedTargets.append(cancelTarget)
            imageView.retainedActionTargets = retainedTargets
            cancel.target = cancelTarget
            cancel.action = #selector(BlockTarget.invoke)
            cancel.keyEquivalent = "\u{1b}"

            _ = AppKitDialogKeyboardNavigation.install(
                on: panel,
                buttonsLeftToRight: [cancel],
                escapeButton: cancel
            )

            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

private final class BlockTarget: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func invoke() { block() }
}
