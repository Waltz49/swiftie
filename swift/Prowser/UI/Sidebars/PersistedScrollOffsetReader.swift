import AppKit
import SwiftUI

/// Tracks vertical scroll offset for a SwiftUI `ScrollView` and restores it from config.
struct PersistedScrollOffsetReader: NSViewRepresentable {
    let storageKey: String
    let config: AppConfig

    func makeNSView(context: Context) -> OffsetReaderView {
        let view = OffsetReaderView()
        view.storageKey = storageKey
        view.config = config
        return view
    }

    func updateNSView(_ nsView: OffsetReaderView, context: Context) {
        nsView.storageKey = storageKey
        nsView.config = config
        nsView.attachIfNeeded()
    }

    final class OffsetReaderView: NSView {
        var storageKey: String = ""
        weak var config: AppConfig?
        private weak var observedScrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            guard boundsObserver == nil else { return }
            DispatchQueue.main.async { [weak self] in
                self?.findAndObserveScrollView()
            }
        }

        private func findAndObserveScrollView() {
            guard let scrollView = enclosingScrollView else { return }
            guard scrollView !== observedScrollView else { return }
            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true

            let saved = config?.int(forKey: storageKey, default: 0) ?? 0
            if saved > 0 {
                var origin = scrollView.contentView.bounds.origin
                origin.y = CGFloat(saved)
                scrollView.contentView.scroll(to: origin)
            }

            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                guard let self, let config = self.config else { return }
                let offset = Int(scrollView.contentView.bounds.origin.y.rounded())
                config.updateSetting(self.storageKey, value: offset)
            }
        }

        deinit {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
        }
    }
}
