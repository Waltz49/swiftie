import SwiftUI

@MainActor
struct CacheSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var totals = CacheManagementService.CacheTotals(thumbnails: 0, similarity: 0, search: 0)
    @State private var statusMessage = ""
    @State private var sourceDirectories = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Caches").font(.title2)

                SettingsSection(title: "Cache Controls") {
                    HStack {
                        Text(totalsLabel)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button {
                            refreshTotals()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh cache information")
                    }

                    HStack(spacing: 8) {
                        cacheButton("Clear Thumbs") { clearThumbnails() }
                        if BundleCapabilities.similaritySearchUIEnabled || BundleCapabilities.clipSearchUIEnabled {
                            cacheButton("Clear Image Rec") { clearImageRec() }
                        }
                        if BundleCapabilities.facesUIEnabled {
                            cacheButton("Clear Face") { clearFace() }
                        }
                        cacheButton("Scrub") { scrubCaches() }
                    }
                    Button("Clear All") { clearAll() }
                    Text("This may temporarily slow down the application as caches are rebuilt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if BundleCapabilities.clipSearchUIEnabled {
                    SettingsSection(title: "Background Processing") {
                        Toggle("Enable idle search-data collection", isOn: boolBinding("background_clip_enabled"))
                        Toggle(
                            "Gather thumbnails for uncached images",
                            isOn: boolBinding("background_clip_gather_thumbnails", default: true)
                        )
                        .disabled(!appState.config.bool(forKey: "background_clip_enabled", default: false))
                        if BundleCapabilities.facesUIEnabled {
                            Toggle(
                                "Extract face encodings in background",
                                isOn: boolBinding("background_clip_extract_faces")
                            )
                            .disabled(!appState.config.bool(forKey: "background_clip_enabled", default: false))
                        }
                    }
                }

                if appState.config.bool(forKey: "debug_mode") {
                    SettingsSection(title: "Source Directories") {
                        Text(sourceDirectories)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Directories from which cached images were loaded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            refreshTotals()
            loadSourceDirectories()
        }
    }

    private var totalsLabel: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let thumbs = formatter.string(fromByteCount: totals.thumbnails)
        if BundleCapabilities.pythonMLEnabled {
            let total = formatter.string(fromByteCount: totals.total)
            let sim = formatter.string(fromByteCount: totals.similarity)
            let search = formatter.string(fromByteCount: totals.search)
            return "Total \(total): \(thumbs) Thumbs, \(sim) Similarity, \(search) Search"
        }
        return "Thumbnails \(thumbs)"
    }

    private func cacheButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
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

    private func clearImageRec() {
        guard confirm("Clear Image Recognition Cache", "This will clear all cached CNN and CLIP feature data.") else { return }
        let removed = CacheManagementService.clearImageRecognitionCache(paths: appState.config.profilePaths)
        statusMessage = "Cleared \(removed) image recognition cache entries."
        appState.workers.reloadSettings(config: appState.config)
        refreshTotals()
    }

    private func clearFace() {
        guard confirm("Clear Face Cache", "This will delete cached face encodings and face sample thumbnails.") else { return }
        let removed = CacheManagementService.clearFaceCache(paths: appState.config.profilePaths, dataDirectory: appState.config.dataDirectory)
        statusMessage = "Cleared \(removed) face cache entries."
        refreshTotals()
    }

    private func scrubCaches() {
        let result = CacheManagementService.scrubCaches(paths: appState.config.profilePaths)
        let reclaimed = ByteCountFormatter.string(fromByteCount: result.bytesReclaimed, countStyle: .file)
        statusMessage = "Scrubbed \(result.thumbnailsRemoved) thumbnails, \(result.recognitionRemoved) recognition entries. Reclaimed \(reclaimed)."
        refreshTotals()
    }

    private func clearAll() {
        let message = BundleCapabilities.pythonMLEnabled
            ? "This will clear all thumbnail, metadata, and recognition caches."
            : "This will clear all thumbnail and metadata caches."
        guard confirm("Clear All Caches", message) else { return }
        let removed = CacheManagementService.clearAllCaches(paths: appState.config.profilePaths, dataDirectory: appState.config.dataDirectory)
        statusMessage = "Cleared \(removed) cache entries."
        appState.workers.reloadSettings(config: appState.config)
        refreshTotals()
    }

    private func confirm(_ title: String, _ message: String) -> Bool {
        StyledMessageDialog.showConfirm(
            title: title,
            message: message,
            confirmTitle: "Clear",
            cancelTitle: "Cancel",
            defaultCancel: true
        )
    }

    private func boolBinding(_ key: String, default defaultValue: Bool = false) -> Binding<Bool> {
        SettingsSupport.boolBinding(config: appState.config, key: key, default: defaultValue) {
            appState.config.applySettingsChange(emit: appState.eventBus)
            appState.workers.reloadSettings(config: appState.config)
        }
    }
}
