import Foundation

/// Multi-select state. Mirrors Python `SelectionModel`.
@Observable
@MainActor
final class SelectionModel {
    private let eventBridge: ModelEventBridge?

    var selectedFiles: Set<String> = []
    var rangeAnchorIndex: Int?
    var lastClickedIndex: Int?
    var mostRecentSelectedPath: String?
    var cmdMultiOriginIndex: Int?
    var cmdMultiAxis: String?
    var cmdMultiSign: Int = 0

    init(eventBridge: ModelEventBridge? = nil) {
        self.eventBridge = eventBridge
    }

    var multiSelectMode: Bool { selectedFiles.count > 1 }

    func resetCmdMulti() {
        cmdMultiOriginIndex = nil
        cmdMultiAxis = nil
        cmdMultiSign = 0
    }

    func emitSelectionChanged(highlightIndex: Int? = nil) {
        let change = SelectionChange(selected: selectedFiles, highlightIndex: highlightIndex)
        eventBridge?.selectionChanged(change)
    }

    func clear() {
        selectedFiles.removeAll()
        rangeAnchorIndex = nil
        lastClickedIndex = nil
        mostRecentSelectedPath = nil
        resetCmdMulti()
        emitSelectionChanged()
    }

    /// Clear multi-select after delete without changing the active image (Python `clear_selection(preserve_current_image=True)`).
    func clearPreservingCurrentImage() {
        selectedFiles.removeAll()
        rangeAnchorIndex = nil
        lastClickedIndex = nil
        mostRecentSelectedPath = nil
        resetCmdMulti()
        emitSelectionChanged(highlightIndex: nil)
    }
}

struct SelectionChange: Sendable {
    let selected: Set<String>
    let highlightIndex: Int?
}

extension Notification.Name {
    static let prowserOpenSettingsTab = Notification.Name("prowser.openSettingsTab")
}
