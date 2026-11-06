import SwiftUI

/// True for model/LoRA/slider rows embedded in the preview splitter's options column.
private struct ImageGenControlsInSplitPaneKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var imageGenControlsInSplitPane: Bool {
        get { self[ImageGenControlsInSplitPaneKey.self] }
        set { self[ImageGenControlsInSplitPaneKey.self] = newValue }
    }
}
