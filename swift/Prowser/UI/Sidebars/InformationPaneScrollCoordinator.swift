import AppKit
import SwiftUI

@Observable
final class InformationPaneScrollCoordinator {
    weak var scrollView: NSScrollView?
    var storedOffset: CGFloat = 0
    var verticalScrollbarReserve: CGFloat = 0

    func captureOffset() {
        guard let scrollView else { return }
        storedOffset = scrollView.contentView.bounds.origin.y
    }

    func restoreOffset() {
        guard let scrollView else { return }
        let docHeight = scrollView.documentView?.bounds.height ?? 0
        let viewHeight = scrollView.contentView.bounds.height
        let maxY = max(0, docHeight - viewHeight)
        var origin = scrollView.contentView.bounds.origin
        origin.y = min(storedOffset, maxY)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    @MainActor
    func syncVerticalScrollbarReserve() {
        guard let scrollView else { return }
        let reserve = Self.verticalScrollbarReservedWidth(for: scrollView)
        guard abs(verticalScrollbarReserve - reserve) > 0.5 else { return }
        verticalScrollbarReserve = reserve
    }

    /// Port of thumbnail / jobs pane ``verticalScrollbarReservedWidth`` when content scrolls vertically.
    static func verticalScrollbarReservedWidth(for scrollView: NSScrollView) -> CGFloat {
        guard scrollView.hasVerticalScroller else { return 0 }
        let clipHeight = scrollView.contentView.bounds.height
        guard clipHeight > 1 else { return 0 }
        let documentHeight = scrollView.documentView?.bounds.height ?? 0
        guard documentHeight > clipHeight + 1 else { return 0 }
        let controlSize = scrollView.verticalScroller?.controlSize ?? .regular
        let style = scrollView.verticalScroller?.scrollerStyle ?? .legacy
        return NSScroller.scrollerWidth(for: controlSize, scrollerStyle: style)
    }
}

private struct InformationPaneScrollCoordinatorKey: EnvironmentKey {
    static let defaultValue = InformationPaneScrollCoordinator()
}

extension EnvironmentValues {
    var informationPaneScrollCoordinator: InformationPaneScrollCoordinator {
        get { self[InformationPaneScrollCoordinatorKey.self] }
        set { self[InformationPaneScrollCoordinatorKey.self] = newValue }
    }
}

struct InformationPaneScrollViewAttachment: NSViewRepresentable {
    @Environment(\.informationPaneScrollCoordinator) private var coordinator

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.coordinator = coordinator
        return view
    }

    func updateNSView(_ nsView: AttachmentView, context: Context) {
        nsView.coordinator = coordinator
        nsView.attachIfNeeded()
    }

    final class AttachmentView: NSView {
        weak var coordinator: InformationPaneScrollCoordinator?
        private weak var observedScrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            DispatchQueue.main.async { [weak self] in
                self?.findAndObserveScrollView()
            }
        }

        private func findAndObserveScrollView() {
            guard let scrollView = enclosingScrollView else { return }
            if scrollView === observedScrollView {
                coordinator?.syncVerticalScrollbarReserve()
                return
            }
            clearObservers()
            observedScrollView = scrollView
            coordinator?.scrollView = scrollView

            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.postsFrameChangedNotifications = true

            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.coordinator?.syncVerticalScrollbarReserve()
                    }
                }
            )
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.coordinator?.syncVerticalScrollbarReserve()
                    }
                }
            )
            if let documentView = scrollView.documentView {
                documentView.postsFrameChangedNotifications = true
                observers.append(
                    NotificationCenter.default.addObserver(
                        forName: NSView.frameDidChangeNotification,
                        object: documentView,
                        queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor in
                            self?.coordinator?.syncVerticalScrollbarReserve()
                        }
                    }
                )
            }
            coordinator?.syncVerticalScrollbarReserve()
        }

        private func clearObservers() {
            for token in observers {
                NotificationCenter.default.removeObserver(token)
            }
            observers.removeAll()
        }

        deinit {
            for token in observers {
                NotificationCenter.default.removeObserver(token)
            }
        }
    }
}
