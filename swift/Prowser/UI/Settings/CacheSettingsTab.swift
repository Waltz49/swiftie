import SwiftUI

@MainActor
struct CacheSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var totals = CacheManagementService.CacheTotals(thumbnails: 0, metadata: 0, imageRecognition: 0)
    @State private var statusMessage = ""
    @State private var sourceDirectories = ""
    @State private var backgroundEnabled = false
    @State private var gatherThumbnails = true
    @State private var indexingAvailable = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Caches").font(.title2)

                SettingsSection(title: "Cache Controls") {
                    HStack {
                        Text(totalsLabel)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button { refreshTotals() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh cache information")
                    }

                    HStack(spacing: 8) {
                        cacheButton("Clear Thumbs") { clearThumbnails() }
                        cacheButton("Clear Image Rec") { clearImageRecognition() }
                        if FaceRecognitionCapabilities.facesUIEnabled(launchOptions: appState.launchOptions) {
                            cacheButton("Clear Face") { clearFaceCache() }
                        }
                        cacheButton("Scrub") { scrubCaches() }
                    }
                    Button("Clear All") { clearAll() }
                        .buttonStyle(.bordered)
                    Text("This may temporarily slow down the application as caches are rebuilt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if indexingAvailable {
                    SettingsSection(title: "Background Processing") {
                        Toggle("Enable idle search-data collection", isOn: $backgroundEnabled)
                            .onChange(of: backgroundEnabled) { _, on in
                                appState.backgroundImageRecognition.setEnabled(on)
                            }
                        Toggle("Also gather thumbnails", isOn: $gatherThumbnails)
                            .disabled(!backgroundEnabled)
                            .onChange(of: gatherThumbnails) { _, on in
                                appState.config.updateSetting("background_clip_gather_thumbnails", value: on)
                            }
                        Text("Runs while idle; may use battery. Does not extract faces.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Install search models (⌘K / ⌘F or Settings → Models for Search) to enable idle search-data collection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if appState.config.bool(forKey: "debug_mode") {
                    SettingsSection(title: "Source Directories") {
                        Text(sourceDirectories)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear {
            refreshTotals()
            loadSourceDirectories()
            reloadBackgroundSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .imageRecognitionModelsInstalled)) { _ in
            reloadBackgroundSettings()
        }
        .onChange(of: appState.backgroundImageRecognition.isProcessing) { _, _ in
            reloadIndexingAvailability()
        }
    }

    private func reloadBackgroundSettings() {
        reloadIndexingAvailability()
        backgroundEnabled = appState.config.bool(forKey: "background_clip_enabled", default: false)
        gatherThumbnails = appState.config.bool(forKey: "background_clip_gather_thumbnails", default: true)
    }

    private func reloadIndexingAvailability() {
        indexingAvailable = BackgroundImageRecognitionController.indexingAvailable(appState: appState)
        if !indexingAvailable {
            appState.backgroundImageRecognition.applyEnabledFromSettings()
        }
    }

    private var totalsLabel: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let thumbs = formatter.string(fromByteCount: totals.thumbnails)
        let meta = formatter.string(fromByteCount: totals.metadata)
        let ir = formatter.string(fromByteCount: totals.imageRecognition)
        let total = formatter.string(fromByteCount: totals.total)
        return "Total \(total): \(thumbs) Thumbs, \(meta) Metadata, \(ir) Image Rec"
    }

    private func cacheButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
    }

    private var preferencesWindow: NSWindow? {
        KeyboardHandlerController.visiblePreferencesWindow()
    }

    private func refreshTotals() {
        totals = CacheManagementService.cacheTotals(paths: appState.config.profilePaths)
        loadSourceDirectories()
    }

    private func loadSourceDirectories() {
        sourceDirectories = CacheManagementService.cacheSourceDirectories(paths: appState.config.profilePaths).joined(separator: "\n")
    }

    private func clearThumbnails() {
        guard confirm("Clear Thumbnail Cache", "This will clear only the thumbnail cache.") else { return }
        let removed = CacheManagementService.clearThumbnailCache(paths: appState.config.profilePaths)
        statusMessage = "Removed \(removed) cached thumbnails."
        refreshTotals()
    }

    private func clearFaceCache() {
        guard confirm(
            "Clear Face Cache",
            "Clear cached face encodings (for Search by person) and face sample thumbnails (Settings → Face Recognition tab)."
        ) else { return }
        CacheManagementService.clearFaceCache(paths: appState.config.profilePaths)
        statusMessage = "Cleared face cache and sample thumbnails."
        refreshTotals()
    }

    private func clearImageRecognition() {
        guard confirm(
            "Clear Image Recognition Cache",
            "This will clear all cached CNN and CLIP feature data. Features will be recalculated as needed, which may temporarily slow similarity searches."
        ) else { return }
        do {
            let removed = try CacheManagementService.clearImageRecognitionCache(
                paths: appState.config.profilePaths,
                includeDownloadedModels: false
            )
            appState.refreshImageRecognitionForCurrentSettings()
            reloadIndexingAvailability()
            statusMessage = "Cleared image recognition cache (\(removed) entries)."
            refreshTotals()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func scrubCaches() {
        let result = CacheManagementService.scrubCaches(paths: appState.config.profilePaths)
        let reclaimed = ByteCountFormatter.string(fromByteCount: result.bytesReclaimed, countStyle: .file)
        statusMessage = "Scrubbed \(result.thumbnailsRemoved) thumbnails, \(result.imageRecognitionRemoved) image-rec entries. Reclaimed \(reclaimed)."
        refreshTotals()
    }

    private func clearAll() {
        guard confirm(
            "Clear All Caches",
            "This will clear thumbnail, metadata, and image recognition feature caches. Downloaded search models are not removed. Caches will rebuild as needed, which may temporarily slow performance."
        ) else { return }
        let removed = CacheManagementService.clearAllCaches(paths: appState.config.profilePaths)
        appState.refreshImageRecognitionForCurrentSettings()
        reloadIndexingAvailability()
        statusMessage = "Cleared \(removed) cache entries."
        refreshTotals()
    }

    private func confirm(_ title: String, _ message: String) -> Bool {
        StyledMessageDialog.showConfirm(
            title: title,
            message: message,
            confirmTitle: "Clear",
            cancelTitle: "Cancel",
            defaultCancel: true,
            parentWindow: preferencesWindow
        )
    }
}
