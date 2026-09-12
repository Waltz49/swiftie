import SwiftUI
import WebKit

struct DownloadingModelsHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloading AI Models")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            DownloadingModelsWebView(html: DownloadingModelsHelpContent.html)
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

private struct DownloadingModelsWebView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

enum DownloadingModelsHelpContent {
    static let html = """
    <html><head><meta charset="utf-8"><style>
    body { font-family: -apple-system, sans-serif; margin: 16px; line-height: 1.45; }
    h2 { margin-top: 1.2em; }
    code { background: #eee; padding: 2px 4px; border-radius: 3px; }
    </style></head><body>
    <h1>Downloading AI Models</h1>
    <p>For Create-menu image generation, Prowser downloads models from Hugging Face on first use.</p>
    <h2>If a download fails</h2>
    <ul>
    <li>Check network connectivity and disk space.</li>
    <li>Install the model manually from Hugging Face into your cache directory.</li>
    <li>Use <b>Tools → Debug → Check LoRAs</b> after adding LoRA weights.</li>
    </ul>
    <h2>LoRA compatibility</h2>
    <p>Run <b>Check LoRAs</b> from the Debug menu to probe on-disk LoRAs and enable those that pass for the active base model.</p>
    <p>See the Python help dialog in the legacy app for per-model download scripts and expanded instructions.</p>
    </body></html>
    """
}
