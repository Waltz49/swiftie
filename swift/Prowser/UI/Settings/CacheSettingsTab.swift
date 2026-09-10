import SwiftUI

@MainActor
struct CacheSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var thumbnailCacheSize = ""
    @State private var statusMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Caches").font(.title2)

                SettingsSection(title: "Thumbnail Cache") {
                    Text(appState.config.thumbnailCacheDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Size on disk: \(thumbnailCacheSize)")
                    Button("Clear Thumbnail Cache") {
                        clearThumbnailCache()
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
        .onAppear { refreshSize() }
    }

    private func refreshSize() {
        thumbnailCacheSize = formattedSize(at: appState.config.thumbnailCacheDirectory)
    }

    private func clearThumbnailCache() {
        let url = appState.config.thumbnailCacheDirectory
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            statusMessage = "Could not read cache directory."
            return
        }
        var removed = 0
        for file in files {
            if (try? fm.removeItem(at: file)) != nil { removed += 1 }
        }
        statusMessage = "Removed \(removed) cached thumbnails."
        refreshSize()
    }

    private func formattedSize(at url: URL) -> String {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return "unknown"
        }
        let total = files.reduce(Int64(0)) { partial, file in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partial + Int64(size)
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }
}
