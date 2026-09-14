import SwiftUI

@MainActor
struct CacheSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var totals = CacheManagementService.CacheTotals(thumbnails: 0, metadata: 0)
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
                        cacheButton("Scrub") { scrubCaches() }
                    }
                    Button("Clear All") { clearAll() }
                    Text("This may temporarily slow down the application as caches are rebuilt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
        let meta = formatter.string(fromByteCount: totals.metadata)
        let total = formatter.string(fromByteCount: totals.total)
        return "Total \(total): \(thumbs) Thumbs, \(meta) Metadata"
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

    private func scrubCaches() {
        let result = CacheManagementService.scrubCaches(paths: appState.config.profilePaths)
        let reclaimed = ByteCountFormatter.string(fromByteCount: result.bytesReclaimed, countStyle: .file)
        statusMessage = "Scrubbed \(result.thumbnailsRemoved) thumbnails. Reclaimed \(reclaimed)."
        refreshTotals()
    }

    private func clearAll() {
        guard confirm("Clear All Caches", "This will clear all thumbnail and metadata caches.") else { return }
        let removed = CacheManagementService.clearAllCaches(paths: appState.config.profilePaths)
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
