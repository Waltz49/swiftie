import AppKit
import SwiftUI
import WebKit

/// HTML help browser with `toggle://` and `copy://` links (Python ``DownloadingAIModelsHelpDialog`` parity).
struct HelpInteractiveHTMLWebView: NSViewRepresentable {
    let html: String
    var onToggle: (String) -> Void = { _ in }
    var onCopy: (String) -> Void = { _ in }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onToggle = onToggle
        context.coordinator.onCopy = onCopy
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onToggle: onToggle, onCopy: onCopy)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""
        var onToggle: (String) -> Void
        var onCopy: (String) -> Void

        init(onToggle: @escaping (String) -> Void, onCopy: @escaping (String) -> Void) {
            self.onToggle = onToggle
            self.onCopy = onCopy
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            let target = resolveCustomLinkTarget(url: url, scheme: scheme)
            if scheme == "toggle", let target, !target.isEmpty {
                onToggle(target)
                decisionHandler(.cancel)
                return
            }
            if scheme == "copy", let target, !target.isEmpty {
                onCopy(target)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        private func resolveCustomLinkTarget(url: URL, scheme: String) -> String? {
            if let host = url.host, !host.isEmpty {
                return host.removingPercentEncoding ?? host
            }
            let raw = url.absoluteString
            let prefix = "\(scheme)://"
            if raw.hasPrefix(prefix) {
                let rest = String(raw.dropFirst(prefix.count))
                return rest.removingPercentEncoding ?? rest
            }
            return nil
        }
    }
}