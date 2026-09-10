import Foundation

/// Event names aligned with Python `event_bus.py`.
enum AppEventType: String, Sendable {
    case directoryRequested
    case directoryLoaded
    case directoryChanged
    case displayedImagesChanged
    case currentImageChanged
    case currentIndexChanged
    case selectionChanged
    case filesChangedOnDisk
    case refreshRequested
    case viewModeChanged
    case thumbnailClicked
    case settingsChanged
    case filterPatternChanged
    case filterTreeModeChanged
    case fileOperationComplete
    case deletedPlaceholdersChanged
    case fileMetadataChanged
    case thumbnailNavigate
    case browseKeyboard
    case mainContentLayoutChanged
    case thumbnailsInvalidated
}

/// Browse-view keyboard actions (zoom, etc.).
enum BrowseKeyboardAction: Sendable {
    case zoomIn
    case zoomOut
    case setActualSize(Bool)
    case rotateClockwise
    case rotateCounterclockwise
    case flipHorizontal
    case flipVertical
    case resetTransforms
    case panLeft
    case panRight
    case panUp
    case panDown
    case fitCanvasWidth
}

/// Arrow-key navigation in the thumbnail grid (menu shortcuts and grid keyDown).
enum ThumbnailNavigateDirection: Int, Sendable {
    case left
    case right
    case up
    case down
}

enum AppEventPayload {
    case none
    case string(String)
    case strings([String])
    case int(Int)
    case bool(Bool)
    case thumbnailDirection(ThumbnailNavigateDirection)
    case browseAction(BrowseKeyboardAction)
}

struct AppEvent: Sendable {
    let type: AppEventType
    let payload: AppEventPayload
}

/// Lightweight pub/sub for cross-component coordination.
@MainActor
final class AppEventBus {
    typealias Handler = (AppEvent) -> Void

    private var subscribers: [AppEventType: [UUID: Handler]] = [:]

    func subscribe(_ type: AppEventType, handler: @escaping Handler) -> UUID {
        let id = UUID()
        var bucket = subscribers[type] ?? [:]
        bucket[id] = handler
        subscribers[type] = bucket
        return id
    }

    func unsubscribe(_ type: AppEventType, token: UUID) {
        subscribers[type]?.removeValue(forKey: token)
    }

    func emit(_ type: AppEventType, payload: AppEventPayload = .none) {
        let event = AppEvent(type: type, payload: payload)
        guard let handlers = subscribers[type] else { return }
        for handler in handlers.values {
            handler(event)
        }
    }
}
