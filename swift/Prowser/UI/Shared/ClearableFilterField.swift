import SwiftUI

/// Filter text field with trailing clear control (Map LoRAs / Preferences sidebar).
struct ClearableFilterField: View {
    let placeholder: String
    @Binding var text: String
    var minFieldWidth: CGFloat = 120
    var clearHelp: String = "Clear filter"

    var body: some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: minFieldWidth)
            Button {
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .disabled(text.isEmpty)
            .help(clearHelp)
        }
    }
}
