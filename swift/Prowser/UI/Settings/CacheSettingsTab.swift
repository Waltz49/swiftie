import SwiftUI

@MainActor
struct CacheSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var totals = CacheManagementService.CacheTotals(thumbnails: 0, metadata: 0, imageRecognition: 0)
    @State private var statusMessage = ""
    @State private var sourceDirectories = ""
    @State private var backgroundEnabled = false
    @State private var gatherThumbnails = true
    @State private var extractFaces = false
    @State private var indexingAvailable = false
    @State private var faceIndexingAvailable = false

    var body: some View {
        ScrollView {
            VStack() {
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

                SettingsSection(title: "Background Processing") {
                    SettingsPreferencePanel {
                        SettingsPreferenceToggleRow(
                            title: "Gather thumbnails while idle",
                            subtitle: "While idle, cache thumbnails for favorites, recent folders, and the current directory.",
                            isOn: $gatherThumbnails
                        )
                        .help("Cache thumbnails for uncached images in favorites, recent folders, and the current directory.")
                        .onChange(of: gatherThumbnails) { _, on in
                            appState.backgroundImageRecognition.setGatherThumbnails(on)
                        }
                        SettingsPreferenceToggleRow(
                            title: "Gather CLIP and CNN image data while idle",
                            subtitle: "While idle, build CLIP and CNN feature caches for favorites, recent folders, and the current directory.",
                            isOn: $backgroundEnabled
                        )
                        .disabled(!indexingAvailable)
                        .help(
                            indexingAvailable
                                ? "Pre-compute CLIP and CNN features for similarity and text search. Runs one idle task at a time with thumbnails and face data."
                                : "Install search models (⌘K / ⌘F or Settings → Models for Search) to enable idle CLIP/CNN collection."
                        )
                        .onChange(of: backgroundEnabled) { _, on in
                            appState.backgroundImageRecognition.setEnabled(on)
                        }
                        if FaceRecognitionCapabilities.facesUIEnabled(launchOptions: appState.launchOptions) {
                            SettingsPreferenceToggleRow(
                                title: "Gather face data while idle",
                                subtitle: "While idle, extract and cache face encodings for favorites, recent folders, and the current directory.",
                                isOn: $extractFaces
                            )
                            .disabled(!faceIndexingAvailable)
                            .help(
                                faceIndexingAvailable
                                    ? "Pre-compute face encodings for known-person search. Runs one idle task at a time with thumbnails and CLIP/CNN."
                                    : "Install face recognition models (Settings → Face Recognition) to enable idle face collection."
                            )
                            .onChange(of: extractFaces) { _, on in
                                appState.backgroundImageRecognition.setExtractFaces(on)
                            }
                        }
                    }
                    Text(footerNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
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
        extractFaces = appState.config.bool(forKey: "background_clip_extract_faces", default: false)
    }

    private func reloadIndexingAvailability() {
        indexingAvailable = BackgroundImageRecognitionController.indexingAvailable(appState: appState)
        faceIndexingAvailable = FaceRecognitionCapabilities.faceFeaturesAvailable(
            profile: appState.config.profilePaths
        )
        appState.backgroundImageRecognition.applyEnabledFromSettings()
    }

    private var footerNote: String {
        "Enabled idle tasks run one at a time (thumbnails, CLIP, CNN, or faces). May use battery."
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
        appState.refreshThumbnailsAfterDiskCacheMutation()
        statusMessage = "Removed \(removed) cached thumbnails."
        refreshTotals()
    }

    private func clearFaceCache() {
        guard confirm(
            "Clear Face Cache",
            "Clear cached face encodings (for Search for Known Person) and face sample thumbnails (Settings → Face Recognition tab)."
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
            appState.imageRecognition.discardInMemoryFeatureCaches(config: appState.config)
            reloadIndexingAvailability()
            statusMessage = "Cleared image recognition cache (\(removed) entries)."
            refreshTotals()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func scrubCaches() {
        Task {
            let paths = Array(
                Set(appState.metadataCache.allCachedPaths() + appState.fileData.displayedImages)
            )
            var cacheKeyForPath: [String: String] = [:]
            for path in paths {
                cacheKeyForPath[path] = await appState.thumbnailCache.cacheKey(for: path)
            }
            let result = CacheManagementService.scrubCaches(
                paths: appState.config.profilePaths,
                cacheKeyForPath: cacheKeyForPath
            )
            if result.thumbnailsRemoved > 0 {
                appState.refreshThumbnailsAfterDiskCacheMutation()
            }
            let reclaimed = ByteCountFormatter.string(fromByteCount: result.bytesReclaimed, countStyle: .file)
            statusMessage = "Scrubbed \(result.thumbnailsRemoved) thumbnails, \(result.imageRecognitionRemoved) image-rec entries. Reclaimed \(reclaimed)."
            refreshTotals()
        }
    }

    private func clearAll() {
        guard confirm(
            "Clear All Caches",
            "This will clear thumbnail, metadata, and image recognition feature caches. Downloaded search models are not removed. Caches will rebuild as needed, which may temporarily slow performance."
        ) else { return }
        let removed = CacheManagementService.clearAllCaches(paths: appState.config.profilePaths)
        appState.refreshThumbnailsAfterDiskCacheMutation()
        appState.imageRecognition.discardInMemoryFeatureCaches(config: appState.config)
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
