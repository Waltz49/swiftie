import AppKit
import SwiftUI

struct BrowseView: NSViewRepresentable {
    @Environment(AppState.self) private var appState

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> BrowseImageNSView {
        let view = BrowseImageNSView(frame: .zero)
        view.appState = appState
        view.onActualSizeModeChanged = { [weak appState] enabled in
            guard let appState else { return }
            if appState.browseActualSizeEnabled != enabled {
                appState.config.updateSetting("browse_view_actual_size", value: enabled)
            }
        }
        view.onExitBrowse = { [weak appState] in
            appState?.closeBrowseView()
        }
        context.coordinator.view = view
        appState.browseImageHost = view
        context.coordinator.startObserving()
        return view
    }

    func updateNSView(_ nsView: BrowseImageNSView, context: Context) {
        nsView.applyTheme(appState.theme.colors)
        nsView.setImage(
            path: appState.fileData.currentImagePath,
            actualSize: appState.browseActualSizeEnabled,
            contentRevision: appState.browseImageContentRevision
        )
        nsView.numberOverlayVisible = appState.numberOverlayVisible
        nsView.overlayIndex = appState.fileData.currentIndex
        nsView.overlayCount = appState.fileData.displayedImages.count
        if appState.numberOverlayVisible {
            nsView.needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator {
        let appState: AppState
        weak var view: BrowseImageNSView?
        private var eventSubscriptions: EventBusSubscriptionBag?

        init(appState: AppState) {
            self.appState = appState
        }

        func startObserving() {
            guard eventSubscriptions == nil else { return }
            let bag = EventBusSubscriptionBag(bus: appState.eventBus)
            eventSubscriptions = bag
            bag.subscribe(.browseKeyboard) { [weak self] event in
                guard let self, case .browseAction(let action) = event.payload else { return }
                switch action {
                case .zoomIn: self.view?.zoomIn()
                case .zoomOut: self.view?.zoomOut()
                case .setActualSize(let enabled): self.view?.setActualSizeMode(enabled)
                case .rotateClockwise: self.view?.rotateClockwise()
                case .rotateCounterclockwise: self.view?.rotateCounterclockwise()
                case .flipHorizontal: self.view?.flipHorizontal()
                case .flipVertical: self.view?.flipVertical()
                case .resetTransforms: self.view?.resetTransforms()
                case .panLeft: self.view?.panBy(dx: -40, dy: 0)
                case .panRight: self.view?.panBy(dx: 40, dy: 0)
                case .panUp: self.view?.panBy(dx: 0, dy: -40)
                case .panDown: self.view?.panBy(dx: 0, dy: 40)
                case .fitCanvasWidth: self.view?.fitToCanvasWidth()
                }
            }
        }
    }
}
