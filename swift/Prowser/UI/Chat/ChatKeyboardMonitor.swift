import AppKit

@MainActor
final class ChatKeyboardMonitor {
    static let shared = ChatKeyboardMonitor()

    private weak var appState: AppState?
    private var monitor: Any?

    private init() {}

    func install(appState: AppState) {
        self.appState = appState
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let appState = self.appState else { return event }
            guard appState.isChatVisible else { return event }
            let display = SidebarPaneSplitModel.leftDisplayPaneVisibility(appState: appState)
            guard display[2] else { return event }
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "r" else {
                return event
            }
            if appState.chat.showUnavailableOnly {
                appState.chat.refreshConnection()
                return nil
            }
            appState.chat.redoLastUserMessage()
            return nil
        }
    }
}
