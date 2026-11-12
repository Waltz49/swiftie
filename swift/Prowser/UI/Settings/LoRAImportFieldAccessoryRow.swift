import SwiftUI

@MainActor
struct LoRAImportCopyButton: View {
    let text: String

    var body: some View {
        ClipboardCopyIconButton(text: text, size: ImageGenChrome.fieldButtonSize)
    }
}

@MainActor
struct LoRAImportOpenWebButton: View {
    let urlString: String
    let openURL: (URL) -> Void

    var body: some View {
        Button {
            guard let url = LoRAURLValidation.normalizedHTTPURL(urlString).flatMap({ URL(string: $0) }) else {
                return
            }
            openURL(url)
        } label: {
            Image(systemName: "safari")
                .frame(width: ImageGenChrome.fieldButtonSize, height: ImageGenChrome.fieldButtonSize)
        }
        .buttonStyle(.plain)
        .help("Open in default browser")
        .disabled(LoRAURLValidation.normalizedHTTPURL(urlString) == nil)
    }
}
