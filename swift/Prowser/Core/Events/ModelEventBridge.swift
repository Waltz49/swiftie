import Foundation

/// Emits `AppEventBus` events when core models change (single outbound path for UI subscribers).
@MainActor
final class ModelEventBridge {
    private let eventBus: AppEventBus

    init(eventBus: AppEventBus) {
        self.eventBus = eventBus
    }

    func displayedImagesChanged(_ images: [String]) {
        eventBus.emit(.displayedImagesChanged, payload: .strings(images))
    }

    func currentIndexChanged(_ index: Int) {
        eventBus.emit(.currentIndexChanged, payload: .int(index))
    }

    func currentImageChanged(_ path: String?) {
        if let path {
            eventBus.emit(.currentImageChanged, payload: .string(path))
        } else {
            eventBus.emit(.currentImageChanged, payload: .none)
        }
    }

    func directoryChanged(_ path: String) {
        eventBus.emit(.directoryChanged, payload: .string(path))
    }

    func viewModeChanged(_ mode: String) {
        eventBus.emit(.viewModeChanged, payload: .string(mode))
    }

    func filterPatternChanged(_ pattern: String) {
        eventBus.emit(.filterPatternChanged, payload: .string(pattern))
    }

    func filterTreeModeChanged(_ mode: String) {
        eventBus.emit(.filterTreeModeChanged, payload: .string(mode))
    }

    func selectionChanged(_ change: SelectionChange) {
        eventBus.emit(.selectionChanged, payload: .selectionChange(change))
    }
}
