import AppKit
import SwiftUI

/// Borderless child panel positioned exactly below its SwiftUI anchor.
@MainActor
struct AppAnchoredPopup<PopupContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let width: CGFloat
    @ViewBuilder let content: () -> PopupContent

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.anchorView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.anchorView = view
        if isPresented {
            DispatchQueue.main.async {
                context.coordinator.showOrUpdate()
            }
        } else {
            context.coordinator.close()
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: AppAnchoredPopup
        weak var anchorView: NSView?
        private var panel: AppAnchoredPopupPanel?
        private var hostingController: NSHostingController<PopupContent>?
        private var outsideClickMonitor: Any?

        init(_ parent: AppAnchoredPopup) {
            self.parent = parent
        }

        func showOrUpdate() {
            guard parent.isPresented,
                  let anchorView,
                  let parentWindow = anchorView.window else { return }

            let hostingController: NSHostingController<PopupContent>
            let panel: AppAnchoredPopupPanel
            if let existingHost = self.hostingController, let existingPanel = self.panel {
                hostingController = existingHost
                panel = existingPanel
                hostingController.rootView = parent.content()
            } else {
                hostingController = NSHostingController(rootView: parent.content())
                panel = AppAnchoredPopupPanel(
                    contentRect: .zero,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                panel.isReleasedWhenClosed = false
                panel.hasShadow = true
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.contentViewController = hostingController
                parentWindow.addChildWindow(panel, ordered: .above)
                self.hostingController = hostingController
                self.panel = panel
                installOutsideClickMonitor()
            }

            hostingController.view.layoutSubtreeIfNeeded()
            let fittingHeight = max(1, hostingController.view.fittingSize.height)
            panel.setContentSize(NSSize(width: parent.width, height: fittingHeight))

            let anchorInWindow = anchorView.convert(anchorView.bounds, to: nil)
            let anchorOnScreen = parentWindow.convertToScreen(anchorInWindow)
            panel.setFrameOrigin(NSPoint(
                x: anchorOnScreen.minX,
                y: anchorOnScreen.minY - panel.frame.height
            ))
            panel.makeKeyAndOrderFront(nil)
        }

        func close() {
            removeOutsideClickMonitor()
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            panel = nil
            hostingController = nil
        }

        private func installOutsideClickMonitor() {
            removeOutsideClickMonitor()
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self, let panel = self.panel, panel.isVisible else { return event }
                guard event.window !== panel else { return event }
                self.parent.isPresented = false
                return event
            }
        }

        private func removeOutsideClickMonitor() {
            if let outsideClickMonitor {
                NSEvent.removeMonitor(outsideClickMonitor)
                self.outsideClickMonitor = nil
            }
        }
    }
}

private final class AppAnchoredPopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
