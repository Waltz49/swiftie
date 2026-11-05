import SwiftUI

@MainActor
struct LoRAImportCopyButton: View {
    let text: String
    let copy: (String) -> Void

    var body: some View {
        AppAssetIconButton(
            normalName: "copy",
            hoverName: "copy_hover",
            size: ImageGenChrome.fieldButtonSize,
            tooltip: "Copy to clipboard",
            action: { copy(text) }
        )
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
