import AppKit
import SwiftUI

// MARK: - Nested scroll views (prompt fields)

/// Prompt nested scroll areas must not chain wheel events to the panel client scroll view.
@MainActor
final class ImageGenNonForwardingScrollView: NSScrollView {
    override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
        false
    }
}

// MARK: - SwiftUI wrapper

/// Scrollable image-gen panel client region (fields below model/LoRA). AppKit scrolling lets nested
/// prompt editors (non-forwarding scroll views) and sliders consume wheel events without chaining here.
@MainActor
struct ImageGenPanelClientScrollView<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let document = ImageGenPanelClientScrollDocumentView()
        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: document.topAnchor),
        ])
        document.hostingView = hosting

        scrollView.documentView = document
        context.coordinator.scrollView = scrollView
        context.coordinator.document = document
        context.coordinator.hosting = hosting
        context.coordinator.installWidthObservation(on: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.hosting?.rootView = content()
        context.coordinator.scheduleLayout()
    }

    @MainActor
    final class Coordinator {
        weak var scrollView: NSScrollView?
        weak var document: ImageGenPanelClientScrollDocumentView?
        weak var hosting: NSHostingView<Content>?
        private var widthObserver: NSObjectProtocol?

        func installWidthObservation(on scrollView: NSScrollView) {
            scrollView.contentView.postsBoundsChangedNotifications = true
            widthObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleLayout()
                }
            }
        }

        func scheduleLayout() {
            DispatchQueue.main.async { [weak self] in
                self?.layoutDocument()
            }
        }

        private func layoutDocument() {
            guard let scrollView, let document, let hosting else { return }
            let width = max(1, scrollView.contentView.bounds.width)
            if hosting.frame.width != width {
                hosting.frame.size.width = width
            }
            hosting.layoutSubtreeIfNeeded()
            let height = max(hosting.fittingSize.height, 1)
            let size = NSSize(width: width, height: height)
            if document.frame.size != size {
                document.frame.size = size
            }
            if hosting.frame.size.height != height {
                hosting.frame.size.height = height
            }
        }

        deinit {
            if let widthObserver {
                NotificationCenter.default.removeObserver(widthObserver)
            }
        }
    }
}

@MainActor
final class ImageGenPanelClientScrollDocumentView: NSView {
    weak var hostingView: NSView?

    override var isFlipped: Bool { true }
}
