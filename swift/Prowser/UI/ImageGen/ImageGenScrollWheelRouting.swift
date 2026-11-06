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
        let scrollView = ImageGenPanelClientNSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.contentView.clipsToBounds = true
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let document = ImageGenPanelClientScrollDocumentView()
        document.clipsToBounds = true
        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = []
        hosting.clipsToBounds = true
        hosting.sizingOptions = .standardBounds
        document.addSubview(hosting)

        scrollView.documentView = document
        context.coordinator.scrollView = scrollView
        context.coordinator.document = document
        context.coordinator.hosting = hosting
        context.coordinator.installWidthObservation(on: scrollView)
        context.coordinator.scheduleLayout()
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
        private var frameObserver: NSObjectProtocol?

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
            scrollView.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView,
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
            let clip = scrollView.contentView
            let width = max(1, clip.bounds.width)
            if abs(clip.bounds.origin.x) > 0.5 {
                clip.scroll(to: NSPoint(x: 0, y: clip.bounds.origin.y))
                scrollView.reflectScrolledClipView(clip)
            }
            hosting.layoutSubtreeIfNeeded()
            let height = max(hosting.fittingSize.height, 1)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            document.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        }

        deinit {
            if let widthObserver {
                NotificationCenter.default.removeObserver(widthObserver)
            }
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
        }
    }
}

/// Fills the controls pane. Intrinsic width must not follow the custom-size block
/// (that pulled the scroll view left under the splitter on expand and infill).
@MainActor
final class ImageGenPanelClientNSScrollView: NSScrollView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

@MainActor
final class ImageGenPanelClientScrollDocumentView: NSView {
    override var isFlipped: Bool { true }
}
