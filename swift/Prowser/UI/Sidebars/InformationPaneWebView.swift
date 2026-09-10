import AppKit
import SwiftUI
import WebKit

enum InformationPaneLinkAction: Equatable {
    case copySeed(String)
    case toggleSection(String, expandAll: Bool)
    case refLevel(optionHeld: Bool)
    case speak
    case edit
    case copy(fullComment: Bool)
    case create
    case editAI
    case delete
    case cancelGeneration
}

struct InformationPaneWebView: NSViewRepresentable {
    let html: String
    let onLink: (InformationPaneLinkAction, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.minimumFontSize = 0
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.pageZoom = 1.0
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLink = onLink
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLink: onLink)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var onLink: (InformationPaneLinkAction, NSEvent.ModifierFlags) -> Void
        var lastHTML = ""

        init(onLink: @escaping (InformationPaneLinkAction, NSEvent.ModifierFlags) -> Void) {
            self.onLink = onLink
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            if handle(url: url, modifiers: modifiers) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        private func handle(url: URL, modifiers: NSEvent.ModifierFlags) -> Bool {
            let optionHeld = modifiers.contains(.option)
            switch url.scheme?.lowercased() {
            case "infocollapse":
                let key = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard !key.isEmpty else { return true }
                onLink(.toggleSection(key, expandAll: optionHeld), modifiers)
                return true
            case "copyseed":
                let seed = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .removingPercentEncoding ?? ""
                if !seed.isEmpty {
                    onLink(.copySeed(seed), modifiers)
                }
                return true
            case "reflevel":
                onLink(.refLevel(optionHeld: optionHeld), modifiers)
                return true
            default:
                break
            }

            switch url.absoluteString {
            case "speak://":
                onLink(.speak, modifiers)
                return true
            case "copy://":
                onLink(.copy(fullComment: optionHeld), modifiers)
                return true
            case "edit://":
                onLink(.edit, modifiers)
                return true
            case "create://":
                onLink(.create, modifiers)
                return true
            case "editai://":
                onLink(.editAI, modifiers)
                return true
            case "delete://":
                onLink(.delete, modifiers)
                return true
            case "cancelgen://":
                onLink(.cancelGeneration, modifiers)
                return true
            default:
                return false
            }
        }
    }
}
