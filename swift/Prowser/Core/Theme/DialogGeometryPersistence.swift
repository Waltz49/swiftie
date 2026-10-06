import AppKit
import SwiftUI

/// Config keys for persisted dialog frames (mirrors Python `*_dialog_geometry` settings).
enum DialogGeometryKey {
    static let editExifUserComment = "edit_exif_usercomment_dialog_geometry"
    static let filter = "filter_dialog_geometry"
    static let similaritySearch = "similarity_search_dialog_geometry"
    static let personSearch = "person_search_dialog_geometry"
    static let clipSearch = "clip_search_dialog_geometry"
    static let convertFormat = "convert_format_dialog_geometry"
    static let resizeImages = "resize_images_dialog_geometry"
    static let renamePrefix = "rename_prefix_dialog_geometry"
    static let findReferences = "find_references_dialog_geometry"
    static let referenceGraph = "reference_graph_dialog_geometry"
    static let exifBatchConfirmation = "exif_batch_confirmation_dialog_geometry"
    static let keyboardHelp = "keyboard_help_dialog_geometry"
    static let hiddenGemsHelp = "hidden_gems_help_dialog_geometry"
    static let about = "about_dialog_geometry"
    static let settings = "settings_dialog_geometry"
    static let settingsSizeFallback = "settings_dialog_size"
    static let generationTiming = "generation_timing_dialog_geometry"

    static let imageGenDialog = "dialog_geometry"
    static let jobQueue = "job_queue_geometry"
}

/// Save and restore NSWindow frames in profile settings (Swift counterpart to Python `save_dialog_geometry_hex`).
@MainActor
enum DialogGeometryPersistence {
    struct StoredFrame: Equatable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var positionIsKnown: Bool

        var size: NSSize { NSSize(width: width, height: height) }
        var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
    }

    static func loadFrame(
        config: AppConfig,
        key: String,
        nestedInImageGen: Bool = false,
        sizeFallbackKey: String? = nil
    ) -> StoredFrame? {
        if let raw = readRawValue(config: config, key: key, nestedInImageGen: nestedInImageGen) {
            if let frame = parseFrame(raw) {
                return frame
            }
        }
        if let sizeFallbackKey,
           let raw = config.rawSettings()[sizeFallbackKey] as? [Any],
           raw.count >= 2 {
            let width = number(raw[0])
            let height = number(raw[1])
            guard width > 0, height > 0 else { return nil }
            return StoredFrame(x: 0, y: 0, width: width, height: height, positionIsKnown: false)
        }
        return nil
    }

    static func saveFrame(
        config: AppConfig,
        key: String,
        frame: NSRect,
        nestedInImageGen: Bool = false
    ) {
        let stored = StoredFrame(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.size.width,
            height: frame.size.height,
            positionIsKnown: true
        )
        writeRawValue(
            config: config,
            key: key,
            value: [stored.x, stored.y, stored.width, stored.height],
            nestedInImageGen: nestedInImageGen
        )
    }

    static func apply(
        to window: NSWindow,
        config: AppConfig,
        key: String,
        defaultSize: NSSize,
        minSize: NSSize,
        nestedInImageGen: Bool = false,
        sizeFallbackKey: String? = nil
    ) {
        var mask = window.styleMask
        mask.insert(.resizable)
        mask.insert(.miniaturizable)
        window.styleMask = mask
        window.minSize = minSize

        if let stored = loadFrame(
            config: config,
            key: key,
            nestedInImageGen: nestedInImageGen,
            sizeFallbackKey: sizeFallbackKey
        ) {
            let rect: NSRect
            if stored.positionIsKnown {
                rect = clampFrame(stored.rect, minSize: minSize)
            } else {
                rect = clampFrame(
                    centeredFrame(size: stored.size, on: window.screen),
                    minSize: minSize
                )
            }
            window.setFrame(rect, display: false)
        } else {
            window.setContentSize(defaultSize)
            window.center()
        }
    }

    static func clampFrame(_ frame: NSRect, minSize: NSSize) -> NSRect {
        let margin: CGFloat = 8
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? frame

        var rect = frame
        rect.size.width = max(minSize.width, min(rect.size.width, screen.width - 2 * margin))
        rect.size.height = max(minSize.height, min(rect.size.height, screen.height - 2 * margin))

        if rect.maxX > screen.maxX - margin {
            rect.origin.x = screen.maxX - margin - rect.size.width
        }
        if rect.minX < screen.minX + margin {
            rect.origin.x = screen.minX + margin
        }
        if rect.maxY > screen.maxY - margin {
            rect.origin.y = screen.maxY - margin - rect.size.height
        }
        if rect.minY < screen.minY + margin {
            rect.origin.y = screen.minY + margin
        }
        if !screen.intersects(rect) {
            rect = centeredFrame(size: rect.size, on: NSScreen.main)
        }
        return rect
    }

    private static func centeredFrame(size: NSSize, on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        )
        return NSRect(origin: origin, size: size)
    }

    private static func readRawValue(
        config: AppConfig,
        key: String,
        nestedInImageGen: Bool
    ) -> Any? {
        if let direct = config.rawSettings()[key] {
            return direct
        }
        if nestedInImageGen {
            let imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
            return imagegen[key]
        }
        let imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
        return imagegen[key]
    }

    private static func writeRawValue(
        config: AppConfig,
        key: String,
        value: Any,
        nestedInImageGen: Bool
    ) {
        if nestedInImageGen {
            var imagegen = config.rawSettings()["imagegen"] as? [String: Any] ?? [:]
            imagegen[key] = value
            config.updateSetting("imagegen", value: imagegen)
            return
        }
        config.updateSetting(key, value: value)
        if var imagegen = config.rawSettings()["imagegen"] as? [String: Any],
           imagegen[key] != nil {
            imagegen.removeValue(forKey: key)
            config.updateSetting("imagegen", value: imagegen)
        }
    }

    private static func parseFrame(_ raw: Any) -> StoredFrame? {
        if let values = raw as? [Any], values.count >= 2 {
            if values.count >= 4 {
                let x = number(values[0])
                let y = number(values[1])
                let width = number(values[2])
                let height = number(values[3])
                guard width > 0, height > 0 else { return nil }
                return StoredFrame(x: x, y: y, width: width, height: height, positionIsKnown: true)
            }
            let width = number(values[0])
            let height = number(values[1])
            guard width > 0, height > 0 else { return nil }
            return StoredFrame(x: 0, y: 0, width: width, height: height, positionIsKnown: false)
        }
        return nil
    }

    private static func number(_ value: Any) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? CGFloat { return Double(value) }
        return 0
    }
}

/// Attaches to the hosting NSWindow, restores saved size/position, and persists on resize/move/close.
struct DialogWindowGeometryConfigurator: NSViewRepresentable {
    @Environment(AppState.self) private var appState

    let configKey: String
    let defaultWidth: CGFloat
    let defaultHeight: CGFloat
    let minWidth: CGFloat
    let minHeight: CGFloat
    var nestedInImageGen = false
    var sizeFallbackKey: String?
    var windowIdentifier: String?
    var windowTitle: String?
    var alwaysOnTop: Bool?

    func makeCoordinator() -> Coordinator {
        Coordinator(appState: appState)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view, settings: self)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView, settings: self)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach(from: nsView.window)
    }

    @MainActor
    final class Coordinator {
        private weak var appState: AppState?
        private var configuredWindows: [ObjectIdentifier: Configuration] = [:]
        private var saveTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

        private struct Configuration {
            let configKey: String
            let nestedInImageGen: Bool
            var observers: [NSObjectProtocol] = []
        }

        init(appState: AppState) {
            self.appState = appState
        }

        func attach(to view: NSView, settings: DialogWindowGeometryConfigurator) {
            guard let window = view.window, let appState else { return }
            let id = ObjectIdentifier(window)

            if let title = settings.windowTitle {
                window.title = title
            }
            if let identifier = settings.windowIdentifier {
                window.identifier = NSUserInterfaceItemIdentifier(identifier)
                window.isReleasedWhenClosed = false
            }
            if let alwaysOnTop = settings.alwaysOnTop {
                window.level = alwaysOnTop ? .floating : .normal
            }

            if configuredWindows[id] == nil {
                DialogGeometryPersistence.apply(
                    to: window,
                    config: appState.config,
                    key: settings.configKey,
                    defaultSize: NSSize(width: settings.defaultWidth, height: settings.defaultHeight),
                    minSize: NSSize(width: settings.minWidth, height: settings.minHeight),
                    nestedInImageGen: settings.nestedInImageGen,
                    sizeFallbackKey: settings.sizeFallbackKey
                )
                installObservers(for: window, settings: settings)
            }

            configuredWindows[id] = configuredWindows[id] ?? Configuration(
                configKey: settings.configKey,
                nestedInImageGen: settings.nestedInImageGen
            )
        }

        func detach(from window: NSWindow?) {
            guard let window else { return }
            let id = ObjectIdentifier(window)
            persist(window: window, immediate: true)
            if let config = configuredWindows.removeValue(forKey: id) {
                for observer in config.observers {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
            saveTasks[id]?.cancel()
            saveTasks.removeValue(forKey: id)
        }

        private func installObservers(for window: NSWindow, settings: DialogWindowGeometryConfigurator) {
            let id = ObjectIdentifier(window)
            var config = configuredWindows[id] ?? Configuration(
                configKey: settings.configKey,
                nestedInImageGen: settings.nestedInImageGen
            )

            let scheduleSave = { [weak self, weak window] in
                guard let self, let window else { return }
                self.scheduleSave(for: window)
            }

            config.observers = [
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { _ in scheduleSave() },
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: window,
                    queue: .main
                ) { _ in scheduleSave() },
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: window,
                    queue: .main
                ) { _ in
                    Task { @MainActor in
                        self.persist(window: window, immediate: true)
                    }
                },
            ]
            configuredWindows[id] = config
        }

        private func scheduleSave(for window: NSWindow) {
            let id = ObjectIdentifier(window)
            saveTasks[id]?.cancel()
            saveTasks[id] = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                persist(window: window, immediate: false)
            }
        }

        private func persist(window: NSWindow, immediate: Bool) {
            guard let appState else { return }
            let id = ObjectIdentifier(window)
            if !immediate {
                guard configuredWindows[id] != nil else { return }
            }
            guard let config = configuredWindows[id] else { return }
            DialogGeometryPersistence.saveFrame(
                config: appState.config,
                key: config.configKey,
                frame: window.frame,
                nestedInImageGen: config.nestedInImageGen
            )
        }
    }
}

extension View {
    func persistedDialogGeometry(
        _ configKey: String,
        defaultWidth: CGFloat,
        defaultHeight: CGFloat,
        minWidth: CGFloat = 280,
        minHeight: CGFloat = 200,
        nestedInImageGen: Bool = false,
        sizeFallbackKey: String? = nil,
        windowIdentifier: String? = nil,
        windowTitle: String? = nil,
        alwaysOnTop: Bool? = nil
    ) -> some View {
        background(
            DialogWindowGeometryConfigurator(
                configKey: configKey,
                defaultWidth: defaultWidth,
                defaultHeight: defaultHeight,
                minWidth: minWidth,
                minHeight: minHeight,
                nestedInImageGen: nestedInImageGen,
                sizeFallbackKey: sizeFallbackKey,
                windowIdentifier: windowIdentifier,
                windowTitle: windowTitle,
                alwaysOnTop: alwaysOnTop
            )
        )
    }
}
