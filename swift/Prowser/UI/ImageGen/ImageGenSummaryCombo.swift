import SwiftUI

/// Read-only summary row using the same ``NSPopUpButton`` chrome as the Model menu picker.
@MainActor
struct ImageGenSummaryComboButton: View {
    @Environment(\.imageGenControlsInSplitPane) private var inSplitPane
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        ImageGenMenuFieldButton(title: title, isEnabled: isEnabled, onActivate: action)
            .frame(
                minWidth: inSplitPane ? 0 : ImageGenInlineFieldLayout.fieldControlMinWidth,
                maxWidth: inSplitPane ? .infinity : ImageGenInlineFieldLayout.fieldControlMaxWidth,
                minHeight: 28,
                alignment: .leading
            )
    }
}
