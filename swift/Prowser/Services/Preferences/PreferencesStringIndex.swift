import Foundation

extension Notification.Name {
    /// Posted on the main queue after the preferences search string index loads or rescans.
    static let prowserPreferencesStringIndexDidUpdate = Notification.Name("prowser.preferencesStringIndexDidUpdate")
}

@MainActor
final class PreferencesStringIndex {
    static let shared = PreferencesStringIndex()

    private var loadedCache: PreferencesStringsCacheFile?
    private var runtimeValuesByTab: [SettingsTab: [PreferencesStringEntry]] = [:]
    private var scanTask: Task<Void, Never>?

    private init() {}

    func entries(for tab: SettingsTab) -> [PreferencesStringEntry] {
        let stored = loadedCache?.tabs[tab.rawValue] ?? []
        let runtime = runtimeValuesByTab[tab] ?? []
        if runtime.isEmpty { return stored }
        return stored + runtime
    }

    func tabMatches(tab: SettingsTab, query: String) -> Bool {
        PreferencesStringMatching.tabMatches(
            tabTitle: tab.title,
            query: query,
            entries: entries(for: tab)
        )
    }

    /// Merge additional searchable strings at runtime (e.g. future LoRA names).
    func setRuntimeValues(_ entries: [PreferencesStringEntry], for tab: SettingsTab) {
        runtimeValuesByTab[tab] = entries
    }

    func ensureLoaded(appState: AppState) {
        let fingerprint = PreferencesStringsCacheFile.visibilityFingerprint(
            minBundle: appState.launchOptions.minBundle
        )
        let fileURL = appState.config.profilePaths.preferencesStringsCacheFile

        if loadedCache != nil { return }

        if let loaded = loadFromDisk(url: fileURL, fingerprint: fingerprint) {
            loadedCache = loaded
            notifyUpdated()
            return
        }

        if let scanTask, !scanTask.isCancelled { return }

        scanTask = Task { @MainActor in
            defer { scanTask = nil }
            _ = await performScan(appState: appState)
        }
    }

    @discardableResult
    func forceRescan(appState: AppState) async -> PreferencesStringsScanner.ScanMetrics {
        let fileURL = appState.config.profilePaths.preferencesStringsCacheFile
        try? FileManager.default.removeItem(at: fileURL)
        loadedCache = nil
        scanTask?.cancel()
        scanTask = nil
        return await performScan(appState: appState)
    }

    @discardableResult
    private func performScan(appState: AppState) async -> PreferencesStringsScanner.ScanMetrics {
        let (cache, metrics) = PreferencesStringsScanner.scan(appState: appState)
        loadedCache = cache
        persist(cache, to: appState.config.profilePaths.preferencesStringsCacheFile)
        PreferencesStringsScanner.logScan(metrics: metrics, reason: "scan")
        SessionViewLog.appendLine(
            "[\(SessionViewLog.debugTimestamp())] Preferences string index scan: "
                + "\(metrics.elapsedMs) ms, \(metrics.tabCount) tabs, \(metrics.stringCount) strings\n",
            config: appState.config
        )
        notifyUpdated()
        return metrics
    }

    private func loadFromDisk(url: URL, fingerprint: String) -> PreferencesStringsCacheFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let file = try? decoder.decode(PreferencesStringsCacheFile.self, from: data) else {
            return nil
        }
        guard file.isValid(forFingerprint: fingerprint) else { return nil }
        return file
    }

    private func persist(_ cache: PreferencesStringsCacheFile, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func notifyUpdated() {
        NotificationCenter.default.post(name: .prowserPreferencesStringIndexDidUpdate, object: nil)
    }
}
