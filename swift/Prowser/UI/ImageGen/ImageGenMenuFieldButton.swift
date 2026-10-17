import AppKit
import SwiftUI

/// ``NSPopUpButton`` chrome for read-only summary fields (matches unified dialog Model ``Picker`` .menu).
@MainActor
final class ImageGenSummaryPopUpButton: NSPopUpButton {
    var onActivate: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onActivate?()
    }
}

@MainActor
struct ImageGenMenuFieldButton: NSViewRepresentable {
    let title: String
    var isEnabled: Bool = true
    let onActivate: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onActivate: onActivate)
    }

    func makeNSView(context: Context) -> ImageGenSummaryPopUpButton {
        let popup = ImageGenSummaryPopUpButton(frame: .zero, pullsDown: false)
        popup.addItem(withTitle: title)
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bind(popup, context: context)
        return popup
    }

    func updateNSView(_ popup: ImageGenSummaryPopUpButton, context: Context) {
        context.coordinator.onActivate = onActivate
        popup.isEnabled = isEnabled
        if popup.itemTitles.first != title {
            popup.removeAllItems()
            popup.addItem(withTitle: title)
        }
        popup.setAccessibilityLabel(title)
        bind(popup, context: context)
    }

    private func bind(_ popup: ImageGenSummaryPopUpButton, context: Context) {
        popup.onActivate = { context.coordinator.fire() }
    }

    @MainActor
    final class Coordinator {
        var onActivate: () -> Void

        init(onActivate: @escaping () -> Void) {
            self.onActivate = onActivate
        }

        func fire() {
            onActivate()
        }
    }
}
