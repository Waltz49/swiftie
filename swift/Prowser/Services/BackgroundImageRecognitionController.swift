import AppKit
import Foundation

/// Idle CLIP/CNN cache warming for favorites and recent directories (in-process).
@MainActor
final class BackgroundImageRecognitionController {
    private weak var appState: AppState?
    private var task: Task<Void, Never>?
    private var lastUserActivity = Date()
    private var monitor: Any?

    func bind(_ appState: AppState) {
        self.appState = appState
        installActivityMonitor()
        applyEnabledFromSettings()
    }

    func applyEnabledFromSettings() {
        guard let appState else { return }
        if appState.config.bool(forKey: "background_clip_enabled", default: false) {
            startIfNeeded()
        } else {
            stop()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard let appState else { return }
        appState.config.updateSetting("background_clip_enabled", value: enabled)
        applyEnabledFromSettings()
    }

    var isBackgroundActive: Bool { task != nil }

    private func installActivityMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            self?.lastUserActivity = Date()
            return event
        }
    }

    private func startIfNeeded() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self?.tick()
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() async {
        guard let appState else { return }
        guard appState.config.bool(forKey: "background_clip_enabled", default: false) else {
            stop()
            return
        }
        if Date().timeIntervalSince(lastUserActivity) < 8 { return }
        let directories = backgroundDirectories(config: appState.config)
        guard !directories.isEmpty else { return }

        for directory in directories {
            if Date().timeIntervalSince(lastUserActivity) < 8 { return }
            let paths = DirectoryScanner.scanDirectory(
                at: directory,
                extensions: appState.config.imageExtensions,
                filterPattern: "*"
            )
            guard !paths.isEmpty else { continue }
            let sample = Array(paths.prefix(40))
            _ = try? await appState.imageRecognition.clipImageFeatures(
                for: sample,
                config: appState.config,
                progress: { _, _, _ in },
                shouldCancel: { false }
            )
            if appState.config.bool(forKey: "background_clip_gather_thumbnails", default: true) {
                for path in sample.prefix(10) {
                    _ = await appState.thumbnailCache.generateThumbnail(for: path, size: 256)
                }
            }
        }
    }

    private func backgroundDirectories(config: AppConfig) -> [String] {
        var dirs: [String] = []
        dirs.append(contentsOf: config.recentDirectories())
        for optional in config.favoriteDirectories() {
            guard let path = optional, !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else { continue }
            dirs.append(path)
        }
        return Array(Set(dirs))
    }
}
