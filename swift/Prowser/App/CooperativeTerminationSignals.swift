import Darwin
import Dispatch
import Foundation

enum ProwserProcessEnvironment {
    /// Python ``PROWSER_FAST_EXIT`` — SIGTERM/SIGINT exit immediately without quit UI or cleanup.
    static var fastExit: Bool {
        let raw = ProcessInfo.processInfo.environment["PROWSER_FAST_EXIT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return raw == "1" || raw == "true" || raw == "yes"
    }
}

/// Routes SIGTERM/SIGINT into ``NSApp.terminate`` so ``applicationShouldTerminate`` can gate quit like ⌘Q.
/// Default ``pkill`` sends SIGTERM; ``pkill -9`` (SIGKILL) cannot be handled here.
final class CooperativeTerminationSignals {
    private var sources: [DispatchSourceSignal] = []
    private let onSignal: () -> Void

    init(onSignal: @escaping () -> Void) {
        self.onSignal = onSignal
    }

    func install() {
        guard sources.isEmpty else { return }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.onSignal()
            }
            source.resume()
            sources.append(source)
        }
    }
}
