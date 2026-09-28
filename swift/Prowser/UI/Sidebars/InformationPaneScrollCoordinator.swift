import AppKit
import SwiftUI

final class InformationPaneScrollCoordinator {
    weak var scrollView: NSScrollView?
    var storedOffset: CGFloat = 0

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

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let scrollView = view.enclosingScrollView {
                coordinator.scrollView = scrollView
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let scrollView = nsView.enclosingScrollView {
                coordinator.scrollView = scrollView
            }
        }
    }
}
