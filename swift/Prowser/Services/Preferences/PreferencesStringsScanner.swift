import AppKit
import SwiftUI

@MainActor
enum PreferencesStringsScanner {
    struct ScanMetrics {
        let elapsedMs: Int
        let tabCount: Int
        let stringCount: Int
    }

    private static let hostWidth: CGFloat = 640
    private static let hostHeight: CGFloat = 12_000

    static func scan(appState: AppState) -> (cache: PreferencesStringsCacheFile, metrics: ScanMetrics) {
        let started = CFAbsoluteTimeGetCurrent()
        let fingerprint = PreferencesStringsCacheFile.visibilityFingerprint(
            minBundle: appState.launchOptions.minBundle
        )
        var tabs: [String: [PreferencesStringEntry]] = [:]
        var stringCount = 0

        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: hostWidth, height: hostHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.orderBack(nil)

        defer { window.close() }

        for tab in SettingsTab.allCases {
            var entries: [PreferencesStringEntry] = [
                PreferencesStringEntry(text: tab.title, kind: .header),
            ]
            let recorder = PreferencesScanStringRecorder()
            let rootView = SettingsTabContent.detail(for: tab)
                .environment(appState)
                .environment(\.themeColors, appState.theme.colors)
                .environment(\.preferencesStringScanMode, true)
                .environment(\.preferencesScanStringRecorder, recorder)
                .frame(width: hostWidth, height: hostHeight, alignment: .topLeading)

            let host = NSHostingController(rootView: rootView)
            window.contentViewController = host
            window.orderFrontRegardless()
            host.view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.12))

            mergeCollectedStrings(
                into: &entries,
                texts: PreferencesNSViewStringCollector.collect(from: host.view) + recorder.strings
            )
            tabs[tab.rawValue] = entries
            stringCount += entries.count
        }

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        let cache = PreferencesStringsCacheFile(
            visibilityFingerprint: fingerprint,
            tabs: tabs
        )
        let metrics = ScanMetrics(
            elapsedMs: elapsedMs,
            tabCount: SettingsTab.allCases.count,
            stringCount: stringCount
        )
        return (cache, metrics)
    }

    static func logScan(metrics: ScanMetrics, reason: String) {
        let message =
            "Preferences string index \(reason): \(metrics.elapsedMs) ms, "
            + "\(metrics.tabCount) tabs, \(metrics.stringCount) strings"
        print(message)
    }

    private static func mergeCollectedStrings(
        into entries: inout [PreferencesStringEntry],
        texts: [String]
    ) {
        var seen = Set(entries.map { $0.text.lowercased() })
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            entries.append(PreferencesStringEntry(text: trimmed, kind: .label))
        }
    }
}
