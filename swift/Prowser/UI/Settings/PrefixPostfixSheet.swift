import SwiftUI

@MainActor
struct PrefixPostfixSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var entries: [PrefixPostfixEntry] = []
    @State private var editingEntry: PrefixPostfixEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prefix and Postfix text")
                .font(.title2)
            Text("Rules applied when sending chat or image prompts (enable in Settings → General → Image Generation).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Table(entries) {
                TableColumn("T") { entry in
                    Toggle("", isOn: binding(for: entry.id, key: .useWithText))
                        .labelsHidden()
                        .disabled(!entry.active)
                }
                .width(28)
                TableColumn("I") { entry in
                    Toggle("", isOn: binding(for: entry.id, key: .useWithImages))
                        .labelsHidden()
                        .disabled(!entry.active)
                }
                .width(28)
                TableColumn("<") { entry in
                    Toggle("", isOn: binding(for: entry.id, key: .isPrefix))
                        .labelsHidden()
                        .disabled(!entry.active)
                }
                .width(28)
                TableColumn(">") { entry in
                    Toggle("", isOn: binding(for: entry.id, key: .isPostfix))
                        .labelsHidden()
                        .disabled(!entry.active)
                }
                .width(28)
                TableColumn("Text") { entry in
                    Text(entry.text).lineLimit(2)
                }
                TableColumn("On") { entry in
                    Toggle("", isOn: binding(for: entry.id, key: .active))
                        .labelsHidden()
                }
                .width(36)
                TableColumn("") { entry in
                    HStack {
                        Button("Edit") { editingEntry = entry }
                        Button("Delete") { deleteEntry(entry.id) }
                    }
                }
                .width(100)
            }

            HStack {
                Button("Add") { addEntry() }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("OK") {
                    PrefixPostfixStore.save(entries, dataDirectory: appState.config.dataDirectory)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 400)
        .onAppear {
            entries = PrefixPostfixStore.load(dataDirectory: appState.config.dataDirectory)
        }
        .sheet(item: $editingEntry) { entry in
            PrefixPostfixTextEditSheet(
                title: entry.text.isEmpty ? "New text" : "Edit text",
                text: entry.text,
                onSave: { newText in
                    if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                        entries[index].text = newText
                    }
                }
            )
        }
    }

    private enum EntryKey {
        case useWithText, useWithImages, isPrefix, isPostfix, active
    }

    private func binding(for id: String, key: EntryKey) -> Binding<Bool> {
        Binding(
            get: {
                guard let entry = entries.first(where: { $0.id == id }) else { return false }
                switch key {
                case .useWithText: return entry.useWithText
                case .useWithImages: return entry.useWithImages
                case .isPrefix: return entry.isPrefix
                case .isPostfix: return entry.isPostfix
                case .active: return entry.active
                }
            },
            set: { newValue in
                guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
                switch key {
                case .useWithText: entries[index].useWithText = newValue
                case .useWithImages: entries[index].useWithImages = newValue
                case .isPrefix: entries[index].isPrefix = newValue
                case .isPostfix: entries[index].isPostfix = newValue
                case .active: entries[index].active = newValue
                }
            }
        )
    }

    private func addEntry() {
        let entry = PrefixPostfixEntry(
            id: String(UUID().uuidString.prefix(10)),
            text: "",
            useWithText: false,
            useWithImages: false,
            isPrefix: false,
            isPostfix: false,
            active: true
        )
        entries.append(entry)
        editingEntry = entry
    }

    private func deleteEntry(_ id: String) {
        entries.removeAll { $0.id == id }
    }
}

@MainActor
private struct PrefixPostfixTextEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var text: String
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 120)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("OK") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
