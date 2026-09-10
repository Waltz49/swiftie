import AppKit
import Foundation

/// Logs keyboard events to stderr when `debug_mode` is enabled in settings.
@MainActor
enum KeyboardInputTracer {
    private static var monitor: Any?

    static func installIfNeeded(config: AppConfig) {
        guard config.bool(forKey: "debug_mode") else {
            uninstall()
            return
        }
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
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
    }

    static func log(_ message: String, config: AppConfig) {
        guard config.bool(forKey: "debug_mode") else { return }
        fputs("[keyboard] \(message)\n", stderr)
    }
}
