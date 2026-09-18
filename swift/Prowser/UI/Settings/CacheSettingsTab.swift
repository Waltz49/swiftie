import SwiftUI

@MainActor
struct CacheSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var totals = CacheManagementService.CacheTotals(thumbnails: 0, metadata: 0, imageRecognition: 0)
    @State private var statusMessage = ""
    @State private var sourceDirectories = ""
    @State private var backgroundEnabled = false
    @State private var gatherThumbnails = true

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
                        cacheButton("Scrub") { scrubCaches() }
                    }
                    Button("Clear All") { clearAll() }
                    Text("This may temporarily slow down the application as caches are rebuilt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsSection(title: "Background Processing") {
                    Toggle("Enable idle search-data collection", isOn: $backgroundEnabled)
                        .onChange(of: backgroundEnabled) { _, on in
                            appState.config.updateSetting("background_clip_enabled", value: on)
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
            backgroundEnabled = appState.config.bool(forKey: "background_clip_enabled", default: false)
            gatherThumbnails = appState.config.bool(forKey: "background_clip_gather_thumbnails", default: true)
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

    private func clearImageRecognition() {
        let alsoModels = StyledMessageDialog.present(
            title: "Clear Image Recognition Cache",
            message: "Remove CNN/CLIP feature caches. Also delete downloaded Core ML model files?",
            buttons: [
                StyledMessageDialog.Button("Cancel", role: .dismissive),
                StyledMessageDialog.Button("Features Only"),
                StyledMessageDialog.Button("Features + Models"),
            ],
            defaultButtonIndex: 1,
            escapeButtonIndex: 0
        )
        guard let alsoModels, alsoModels > 0 else { return }
        let includeModels = alsoModels == 2
        do {
            let removed = try CacheManagementService.clearImageRecognitionCache(
                paths: appState.config.profilePaths,
                includeDownloadedModels: includeModels
            )
            appState.imageRecognition.rebind(config: appState.config)
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
        guard confirm("Clear All Caches", "This will clear thumbnail, metadata, and image recognition caches (including downloaded models).") else { return }
        let removed = CacheManagementService.clearAllCaches(paths: appState.config.profilePaths)
        appState.imageRecognition.rebind(config: appState.config)
        statusMessage = "Cleared \(removed) cache entries."
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
}
