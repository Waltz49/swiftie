import AppKit
import Foundation

/// Logs keyboard events to stderr when debug mode is on (`--debug` or ⌘⇧D).
@MainActor
enum KeyboardInputTracer {
    private static var monitor: Any?
    private static weak var config: AppConfig?

    static func installIfNeeded(config: AppConfig) {
        self.config = config
        guard config.bool(forKey: "debug_mode") else {
            uninstall()
            return
        }
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard let config = Self.config, config.bool(forKey: "debug_mode") else {
                return event
            }
            let responder = NSApp.keyWindow?.firstResponder
            let responderName = responder.map { String(describing: type(of: $0)) } ?? "nil"
            let key = event.charactersIgnoringModifiers ?? "?"
            fputs(
                "[keyboard] type=\(event.type.rawValue) keyCode=\(event.keyCode) "
                    + "chars=\(key) modifiers=\(event.modifierFlags.rawValue) "
                    + "firstResponder=\(responderName)\n",
                stderr
            )
            return event
        }
        fputs("[keyboard] debug tracer installed\n", stderr)
    }

    static func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        config = nil
    }

    static func log(_ message: String, config: AppConfig) {
        guard config.bool(forKey: "debug_mode") else { return }
        fputs("[keyboard] \(message)\n", stderr)
    }
}
