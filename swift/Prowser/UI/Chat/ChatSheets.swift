import SwiftUI

struct ChatTipsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Chat Tips")
                .font(.headline)
                .padding()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    tipBlock("Images", "Drag and drop image files onto the prompt field or onto a message bubble.")
                    tipBlock("/source", "Type /source in a user message to copy source image references onto the assistant reply without starting generation.")
                    tipBlock("{}", "Include the two-character token {} in your message to attach the current browse/thumbnail selection (up to four images).")
                    tipBlock(
                        "Editing",
                        "Double-click message text to edit. Drop images while editing to attach them. "
                            + "Escape cancels; ⌘Return saves."
                    )
                    tipBlock("Thumbnails", "Click message thumbnails to open those images in the browser.")
                    tipBlock("Keyboard", "F9 or comma toggles the chat pane. Command+R redoes the last user message when chat is visible.")
                }
                .padding(.horizontal)
            }
            DialogButtonRow([DialogButton("OK", isDefault: true) { dismiss() }])
                .padding()
        }
        .frame(minWidth: 680, minHeight: 360)
    }

    private func tipBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            Text(body)
        }
    }
}
