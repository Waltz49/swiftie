import AppKit

/// Presents the system color panel for theme swatches — port of Python `QColorDialog` live preview.
@MainActor
final class ThemeColorPanelController: NSObject {
    static let shared = ThemeColorPanelController()

    private var onSwatchChange: ((String) -> Void)?
    private var onThemeChange: ((String) -> Void)?
    private var originalHex = ""
    private var debounceTask: Task<Void, Never>?
    private var colorObserver: NSObjectProtocol?
    private var escapeMonitor: Any?

    private override init() {
        super.init()
    }

    func pickColor(
        hex: String,
        onSwatchChange: @escaping (String) -> Void,
        onThemeChange: @escaping (String) -> Void
    ) {
        finishSession(revert: false)

        originalHex = hex
        self.onSwatchChange = onSwatchChange
        self.onThemeChange = onThemeChange

        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(hex: hex) ?? .gray

        colorObserver = NotificationCenter.default.addObserver(
            forName: NSColorPanel.colorDidChangeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleColorChanged()
            }
        }

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            MainActor.assumeIsolated {
                self?.finishSession(revert: true)
            }
            return nil
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFront(nil)
    }

    func closeIfOpen() {
        guard onThemeChange != nil else { return }
        finishSession(revert: false)
    }

    private func handleColorChanged() {
        let hex = currentPanelHex()
        onSwatchChange?(hex)
        scheduleThemeApply(hex)
    }

    private func scheduleThemeApply(_ hex: String) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            onThemeChange?(hex)
        }
    }

    private func finishSession(revert: Bool) {
        guard onThemeChange != nil else { return }

        debounceTask?.cancel()
        debounceTask = nil

        if let colorObserver {
            NotificationCenter.default.removeObserver(colorObserver)
            self.colorObserver = nil
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }

        let finalHex = revert ? originalHex : currentPanelHex()
        onSwatchChange?(finalHex)
        onThemeChange?(finalHex)

        NSColorPanel.shared.orderOut(nil)
        onSwatchChange = nil
        onThemeChange = nil
        originalHex = ""
    }

    private func currentPanelHex() -> String {
        let color = NSColorPanel.shared.color.usingColorSpace(.sRGB) ?? NSColorPanel.shared.color
        return color.hexString
    }
}
