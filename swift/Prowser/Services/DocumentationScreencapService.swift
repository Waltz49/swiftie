import AppKit
import CoreGraphics
import Foundation

/// Tools → Debug → Documentation screencaps (port of Python ``documentation_screencaps.py``).
@MainActor
enum DocumentationScreencapService {
    private static let outputDirectoryPath = "/tmp/screencaps"

    private static var activeRunner: Runner?

    /// Basenames match prowser.php ``$settings_sim_tabs``; tabs align with ``SettingsTab``.
    private static let captureSpecs: [(SettingsTab, String)] = [
        (.general, "settings_general.webp"),
        (.favorites, "settings_favorites.webp"),
        (.directories, "settings_directories.webp"),
        (.extensions, "settings_filetypes.webp"),
        (.destinations, "settings_destinations.webp"),
        (.excludes, "settings_excludes.webp"),
        (.theme, "settings_theme.webp"),
        (.maps, "settings_maps_and_editor.webp"),
        (.slideshow, "settings_slideshow.webp"),
        (.modelsSearch, "settings_search_models.webp"),
        (.faceRecognition, "settings_face_recognition.webp"),
        (.imageGeneration, "settings_captioning.webp"),
        (.lora, "settings_LoRA.webp"),
        (.caches, "settings_caches.webp"),
    ]

    static func outputDirectoryHasImages(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return false
        }
        return names.contains { name in
            guard !name.hasPrefix(".") else { return false }
            let lower = name.lowercased()
            return lower.hasSuffix(".webp") || lower.hasSuffix(".png") || lower.hasSuffix(".jpg")
                || lower.hasSuffix(".jpeg")
        }
    }

    static func openScreenRecordingPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    static func presentCaptureFailureGuidance(outputDirectory: String, failedCaptures: [(String, String)]) {
        var message =
            """
            No screenshots were saved to \(outputDirectory).

            Captures use in-app window rendering (not the screen-recording permission or the \
            screencapture command). Leave the preferences window visible on screen and avoid \
            covering it while this tool runs.
            """
        if !failedCaptures.isEmpty {
            let lines = failedCaptures.map { "  \($0.0): \($0.1)" }.joined(separator: "\n")
            message +=
                """


                Failed captures:
                \(lines)
                """
        }
        let buttonIndex = StyledMessageDialog.present(
            title: "Documentation screencaps",
            message: message,
            style: .warning,
            icon: .warning,
            buttons: [
                StyledMessageDialog.Button("Close", role: .dismissive),
                StyledMessageDialog.Button("Open Screen Recording Settings…"),
            ],
            defaultButtonIndex: 0,
            escapeButtonIndex: 0
        )
        if buttonIndex == 1 {
            openScreenRecordingPrivacySettings()
        }
    }

    static func run(appState: AppState, settingsDialog: SettingsDialogController) {
        if activeRunner != nil {
            StyledMessageDialog.showWarning(
                title: "Documentation screencaps",
                message: "A documentation screencap run is already in progress."
            )
            return
        }
        let visible = Set(SettingsTab.visibleTabs(minBundle: appState.launchOptions.minBundle))
        let specs = captureSpecs.filter { visible.contains($0.0) }
        guard !specs.isEmpty else {
            StyledMessageDialog.showWarning(
                title: "Documentation screencaps",
                message: "No settings tabs are available to capture in this build."
            )
            return
        }
        let runner = Runner(appState: appState, settingsDialog: settingsDialog, specs: specs)
        activeRunner = runner
        runner.start()
    }

    @MainActor
    private final class Runner {
        private weak var appState: AppState?
        private let settingsDialog: SettingsDialogController
        private let specs: [(SettingsTab, String)]
        private var index = 0
        private var saved: [String] = []
        private var failed: [(String, String)] = []
        private var pendingWrites: [Task<Void, Never>] = []

        init(
            appState: AppState,
            settingsDialog: SettingsDialogController,
            specs: [(SettingsTab, String)]
        ) {
            self.appState = appState
            self.settingsDialog = settingsDialog
            self.specs = specs
        }

        func start() {
            do {
                try FileManager.default.createDirectory(
                    atPath: DocumentationScreencapService.outputDirectoryPath,
                    withIntermediateDirectories: true
                )
            } catch {
                Task { @MainActor in await finish() }
                return
            }
            index = 0
            saved = []
            failed = []
            Task { @MainActor in
                await switchToCurrentTab()
            }
        }

        private func switchToCurrentTab() async {
            guard index < specs.count, let appState else {
                await finish()
                return
            }
            let (tab, _) = specs[index]
            if index == 0 {
                appState.openSettingsWindow(
                    tab: tab,
                    userInfo: ["clearTabFilter": true]
                )
            } else {
                appState.selectSettingsTabForDocumentation(tab)
            }
            await waitForTabRender(appState: appState, tab: tab)
            await captureCurrentTab()
        }

        private func waitForTabRender(appState: AppState, tab: SettingsTab) async {
            let ms: UInt64 = tab == .faceRecognition ? 120 : 60
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
            if index == 0 {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            await Task.yield()
            _ = appState
        }

        private func captureCurrentTab() async {
            guard index < specs.count else {
                await finish()
                return
            }
            let (tab, filename) = specs[index]
            guard let window = settingsDialog.preferencesWindowForCapture else {
                failed.append((filename, "capture failed"))
                index += 1
                if index < specs.count {
                    await switchToCurrentTab()
                } else {
                    await finish()
                }
                return
            }

            if let source = PreferencesWindowCapture.capture(window: window, appState: appState) {
                let outURL = URL(fileURLWithPath: DocumentationScreencapService.outputDirectoryPath)
                    .appendingPathComponent(filename)
                let name = filename
                let writeTask = Task.detached(priority: .userInitiated) {
                    do {
                        try WebPImageWriter.write(
                            image: source,
                            to: outURL,
                            compressionMethod: 2,
                            atomicWrite: true
                        )
                        await MainActor.run {
                            self.saved.append(name)
                        }
                    } catch {
                        await MainActor.run {
                            self.failed.append((name, "save failed"))
                        }
                    }
                }
                pendingWrites.append(writeTask)
            } else {
                failed.append((filename, "capture failed (\(tab.title))"))
            }

            index += 1
            if index < specs.count {
                await switchToCurrentTab()
            } else {
                await finish()
            }
        }

        private func finish() async {
            for task in pendingWrites {
                await task.value
            }
            pendingWrites.removeAll()
            settingsDialog.dismissPreferencesWithoutApplying()
            let dir = DocumentationScreencapService.outputDirectoryPath
            let dirHasImages = DocumentationScreencapService.outputDirectoryHasImages(at: dir)

            if dirHasImages {
                openOutputDirectoryInThumbnailView()
            }

            if !failed.isEmpty {
                let lines = failed.map { "  \($0.0): \($0.1)" }.joined(separator: "\n")
                if dirHasImages {
                    StyledMessageDialog.showWarning(
                        title: "Documentation screencaps",
                        message:
                            """
                            Saved \(saved.count) of \(saved.count + failed.count) images to \(dir).

                            Failed:
                            \(lines)
                            """
                    )
                }
            } else if !saved.isEmpty, dirHasImages {
                appState?.status.show(
                    "Documentation screencaps saved (\(saved.count) images):\n\(dir)",
                    duration: 6
                )
            }

            if !dirHasImages {
                DocumentationScreencapService.presentCaptureFailureGuidance(
                    outputDirectory: dir,
                    failedCaptures: failed
                )
            }

            if DocumentationScreencapService.activeRunner === self {
                DocumentationScreencapService.activeRunner = nil
            }
        }

        private func openOutputDirectoryInThumbnailView() {
            guard let appState else { return }
            let pattern = appState.filterSettings.filterPattern
            let namesForFilter = saved.isEmpty
                ? (try? FileManager.default.contentsOfDirectory(atPath: DocumentationScreencapService.outputDirectoryPath)) ?? []
                : saved
            let needsWildcard = namesForFilter.contains {
                !DirectoryScanner.pathMatchesFilenameFilter($0, pattern: pattern)
            }
            if needsWildcard {
                appState.filterSettings.setFilterPattern("*", persist: true, notify: false)
            }
            appState.fileData.setViewMode(.thumbnail)
            appState.loadDirectory(
                DocumentationScreencapService.outputDirectoryPath,
                saveHistory: false,
                scanFilterPattern: "*"
            )
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Renders the preferences ``NSWindow`` in-process (`cacheDisplay`). Does not use Screen Recording TCC.
@MainActor
private enum PreferencesWindowCapture {
    static func capture(window: NSWindow, appState: AppState?) -> CGImage? {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        guard waitForWindowReady(window, appState: appState) else {
            appState?.config.debugLog("documentation screencaps: preferences window not ready")
            return nil
        }
        for view in captureViewCandidates(window) {
            if let image = cacheDisplayImage(from: view) {
                appState?.config.debugLog(
                    "documentation screencaps: captured \(type(of: view)) \(image.width)×\(image.height)"
                )
                return image
            }
        }
        appState?.config.debugLog("documentation screencaps: cacheDisplay produced no image")
        return nil
    }

    private static func waitForWindowReady(_ window: NSWindow, appState: AppState?) -> Bool {
        guard window.isVisible else { return false }
        window.displayIfNeeded()
        window.contentView?.displayIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        return (window.contentView?.bounds.width ?? 0) > 10
    }

    /// Title bar + client area (`NSThemeFrame`); content-only fallback.
    private static func captureViewCandidates(_ window: NSWindow) -> [NSView] {
        guard let content = window.contentView else { return [] }
        if let frameRoot = content.superview {
            return [frameRoot, content]
        }
        return [content]
    }

    private static func cacheDisplayImage(from view: NSView) -> CGImage? {
        view.displayIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        var rect = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        return rep.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}