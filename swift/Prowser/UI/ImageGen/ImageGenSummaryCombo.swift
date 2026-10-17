import SwiftUI

/// Read-only summary row using the same ``NSPopUpButton`` chrome as the Model menu picker.
@MainActor
struct ImageGenSummaryComboButton: View {
    let title: String
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        ImageGenMenuFieldButton(title: title, isEnabled: isEnabled, onActivate: action)
            .frame(
                minWidth: ImageGenInlineFieldLayout.fieldControlMinWidth,
                maxWidth: ImageGenInlineFieldLayout.fieldControlMaxWidth,
                minHeight: 28,
                alignment: .leading
            )
    }
}
