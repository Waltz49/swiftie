import AppKit

@MainActor
final class ChatKeyboardMonitor {
    static let shared = ChatKeyboardMonitor()

    private init() {}

    /// Reserved hook from ``ChatPaneView``; ⌘R is handled in ``KeyboardHandlerController``.
    func install(appState: AppState) {}
}
