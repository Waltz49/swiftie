import Foundation

/// Multi-select state. Mirrors Python `SelectionModel`.
@Observable
@MainActor
final class SelectionModel {
    var selectedFiles: Set<String> = []
    var rangeAnchorIndex: Int?
    var lastClickedIndex: Int?
    var mostRecentSelectedPath: String?
    var cmdMultiOriginIndex: Int?
    var cmdMultiAxis: String?
    var cmdMultiSign: Int = 0

    var multiSelectMode: Bool { selectedFiles.count > 1 }

    func resetCmdMulti() {
        cmdMultiOriginIndex = nil
        cmdMultiAxis = nil
        cmdMultiSign = 0
    }

    func emitSelectionChanged(highlightIndex: Int? = nil) {
        NotificationCenter.default.post(
            name: .prowserSelectionChanged,
            object: SelectionChange(selected: selectedFiles, highlightIndex: highlightIndex)
        )
    }

    func clear() {
        selectedFiles.removeAll()
        rangeAnchorIndex = nil
        lastClickedIndex = nil
        mostRecentSelectedPath = nil
        resetCmdMulti()
        emitSelectionChanged()
    }
}

struct SelectionChange: Sendable {
    let selected: Set<String>
    let highlightIndex: Int?
}

extension Notification.Name {
    static let prowserSelectionChanged = Notification.Name("prowser.selectionChanged")
    static let prowserOpenSettingsTab = Notification.Name("prowser.openSettingsTab")
}
