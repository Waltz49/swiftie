import SwiftUI

/// Edit saved filter presets (Python `FilterDialog`).
struct FilterDialogSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [FilterEntry] = []
    @State private var validationMessages: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Filters")
                .font(.headline)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                TextField("Pattern", text: binding(for: entry.id))
                                    .textFieldStyle(.roundedBorder)
                                Button("−") {
                                    removeEntry(entry.id)
                                }
                                .buttonStyle(.bordered)
                            }
                            if let message = validationMessages[entry.id], !message.isEmpty {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 200)

            HStack {
                Button("+") {
                    addEntry(prefill: prefillPattern())
                }
                .help("Add a new filter")

                Spacer()

                Button("Cancel") { dismiss() }
                Button("OK") {
                    appState.saveFilterPresets(validEntries())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!allValid)
            }
        }
        .padding(16)
        .frame(minWidth: 320, minHeight: 360)
        .themeDialogStyle()
        .persistedDialogGeometry(
            DialogGeometryKey.filter,
            defaultWidth: 360,
            defaultHeight: 400,
            minWidth: 320,
            minHeight: 360
        )
        .onAppear {
            entries = appState.config.getSavedFilters().map {
                FilterEntry(pattern: FilterPatternFormatting.forEditing($0))
            }
            if entries.isEmpty {
                entries = [FilterEntry(pattern: "")]
            }
            validateAll()
        }
    }

    private var allValid: Bool {
        entries.allSatisfy { entry in
            let message = FilterPatternValidator.validate(entry.pattern)
            return message == nil
        }
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { entries.first(where: { $0.id == id })?.pattern ?? "" },
            set: { newValue in
                guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
                entries[index].pattern = newValue
                validateAll()
            }
        )
    }

    private func addEntry(prefill: String) {
        entries.append(FilterEntry(pattern: prefill))
    }

    private func removeEntry(_ id: UUID) {
        entries.removeAll { $0.id == id }
        validationMessages[id] = nil
    }

    @MainActor
    private func prefillPattern() -> String {
        let current = FilterPatternFormatting.forStorage(appState.filterSettings.filterPattern)
        guard !current.isEmpty else { return "" }
        let saved = appState.config.getSavedFilters()
        if saved.contains(current) { return "" }
        return FilterPatternFormatting.forEditing(current)
    }

    @MainActor
    private func validEntries() -> [String] {
        entries
            .map { FilterPatternFormatting.forStorage($0.pattern) }
            .filter { !$0.isEmpty }
    }

    private func validateAll() {
        var messages: [UUID: String] = [:]
        for entry in entries {
            messages[entry.id] = FilterPatternValidator.validate(entry.pattern) ?? ""
        }
        validationMessages = messages
    }

    private func normalizeForComparison(_ pattern: String) -> String {
        var value = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("*") { value = String(value.dropLast()) }
        if value.isEmpty { return "*" }
        return value
    }
}

private struct FilterEntry: Identifiable {
    let id = UUID()
    var pattern: String
}

enum FilterPatternValidator {
    static func validate(_ pattern: String) -> String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "*" { return nil }
        if trimmed.contains("/") || trimmed.contains("\\") {
            return "Pattern cannot contain path separators (/, \\)"
        }
        if trimmed.contains(":") {
            return "Pattern cannot contain colon (:) - basename only"
        }
        let open = trimmed.filter { $0 == "[" }.count
        let close = trimmed.filter { $0 == "]" }.count
        if open != close {
            return "Unmatched brackets [ ]"
        }
        return nil
    }
}
