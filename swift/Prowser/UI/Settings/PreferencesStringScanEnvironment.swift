import SwiftUI

private struct PreferencesStringScanModeKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PreferencesScanStringRecorderKey: EnvironmentKey {
    static let defaultValue: PreferencesScanStringRecorder? = nil
}

extension EnvironmentValues {
    var preferencesStringScanMode: Bool {
        get { self[PreferencesStringScanModeKey.self] }
        set { self[PreferencesStringScanModeKey.self] = newValue }
    }

    var preferencesScanStringRecorder: PreferencesScanStringRecorder? {
        get { self[PreferencesScanStringRecorderKey.self] }
        set { self[PreferencesScanStringRecorderKey.self] = newValue }
    }
}

/// Collects label/header text while preferences tabs are hosted for indexing.
@MainActor
final class PreferencesScanStringRecorder {
    private(set) var strings: [String] = []
    private var seen = Set<String>()

    func record(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = trimmed.lowercased()
        guard seen.insert(key).inserted else { return }
        strings.append(trimmed)
    }
}

/// During scan, render tab content without `ScrollView` so labels mount for indexing.
struct SettingsTabScrollContainer<Content: View>: View {
    @Environment(\.preferencesStringScanMode) private var preferencesStringScanMode
    @ViewBuilder var content: () -> Content

    var body: some View {
        if preferencesStringScanMode {
            content()
        } else {
            ScrollView {
                content()
            }
        }
    }
}

extension View {
    func preferencesScanRecordsLabel(_ text: String) -> some View {
        modifier(PreferencesScanRecordLabelModifier(text: text))
    }
}

private struct PreferencesScanRecordLabelModifier: ViewModifier {
    let text: String
    @Environment(\.preferencesStringScanMode) private var scanMode
    @Environment(\.preferencesScanStringRecorder) private var recorder

    func body(content: Content) -> some View {
        content.onAppear {
            guard scanMode, let recorder else { return }
            recorder.record(text)
        }
    }
}
