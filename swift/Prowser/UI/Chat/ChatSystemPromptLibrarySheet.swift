import SwiftUI

@MainActor
struct ChatSystemPromptLibrarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var store: ChatPromptConfig.SystemPromptStore
    @State private var previewText = ""
    @State private var selectedID = ChatPromptConfig.systemDefaultID
    @State private var newName = ""
    @State private var showAddPrompt = false
    @State private var showRenamePrompt = false

    init(store: ChatPromptConfig.SystemPromptStore) {
        _store = State(initialValue: store)
        _previewText = State(initialValue: store.activePromptText())
        if let activeID = store.activeNamedPromptID {
            _selectedID = State(initialValue: activeID)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Prompt Library")
                .font(.headline)

            Text("Preview")
                .font(.subheadline)
            TextEditor(text: $previewText)
                .font(.body)
                .frame(minHeight: 120, maxHeight: 180)
                .border(Color.secondary.opacity(0.25))

            Text("Saved prompts")
                .font(.subheadline)
            Picker("Saved prompts", selection: $selectedID) {
                Text("System default").tag(ChatPromptConfig.systemDefaultID)
                ForEach(store.namedPrompts) { prompt in
                    Text(prompt.name).tag(prompt.id)
                }
            }
            .pickerStyle(.inline)
            .onChange(of: selectedID) { _, _ in
                syncPreviewFromSelection()
            }

            HStack(spacing: 8) {
                Button("Add…") { showAddPrompt = true }
                Button("Rename") {
                    if selectedID != ChatPromptConfig.systemDefaultID,
                       let prompt = store.namedPrompts.first(where: { $0.id == selectedID }) {
                        newName = prompt.name
                        showRenamePrompt = true
                    }
                }
                .disabled(selectedID == ChatPromptConfig.systemDefaultID)
                Button("Delete", role: .destructive) { deleteSelected() }
                    .disabled(selectedID == ChatPromptConfig.systemDefaultID)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 520)
        .alert("New prompt", isPresented: $showAddPrompt) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Add") { addPrompt() }
        } message: {
            Text("Enter a name for the new system prompt.")
        }
        .alert("Rename prompt", isPresented: $showRenamePrompt) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Rename") { renameSelected() }
        }
    }

    private func syncPreviewFromSelection() {
        if selectedID == ChatPromptConfig.systemDefaultID {
            previewText = store.systemPrompt
        } else if let prompt = store.namedPrompts.first(where: { $0.id == selectedID }) {
            previewText = prompt.text
        }
    }

    private func addPrompt() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let entry = ChatPromptConfig.NamedPrompt(
            id: UUID().uuidString,
            name: name,
            text: previewText
        )
        store.namedPrompts.insert(entry, at: 0)
        selectedID = entry.id
        newName = ""
    }

    private func renameSelected() {
        guard selectedID != ChatPromptConfig.systemDefaultID,
              let index = store.namedPrompts.firstIndex(where: { $0.id == selectedID }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        store.namedPrompts[index].name = trimmed
        newName = ""
    }

    private func deleteSelected() {
        guard selectedID != ChatPromptConfig.systemDefaultID else { return }
        store.namedPrompts.removeAll { $0.id == selectedID }
        selectedID = ChatPromptConfig.systemDefaultID
        syncPreviewFromSelection()
    }

    private func save() {
        if selectedID == ChatPromptConfig.systemDefaultID {
            store.activeNamedPromptID = nil
            store.systemPrompt = previewText
        } else if let index = store.namedPrompts.firstIndex(where: { $0.id == selectedID }) {
            store.activeNamedPromptID = selectedID
            store.namedPrompts[index].text = previewText
        }
        appState.chat.applySystemPromptSelection(store)
        dismiss()
    }
}
