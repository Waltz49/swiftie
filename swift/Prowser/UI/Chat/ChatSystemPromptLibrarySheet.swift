import SwiftUI

/// Port of ``ChatSystemPromptLibraryDialog`` in ``chat_named_system_prompts.py``.
struct ChatSystemPromptLibrarySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDialog) private var closeDialog

    @State private var draft = ChatSystemPromptStore.Config(
        systemPrompt: ChatSystemPromptStore.defaultPromptText,
        activeNamedPromptID: "",
        namedPrompts: []
    )
    @State private var selectedID = ChatSystemPromptStore.systemDefaultID
    @State private var previewText = ""
    @State private var showAddPrompt = false
    @State private var renameEntry: ChatNamedPrompt?
    @State private var deletePrompt: ChatNamedPrompt?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("System Prompt for Chat")
                .font(.headline)
                .padding()

            VStack(alignment: .leading, spacing: 8) {
                Text("Active system prompt:")
                    .font(.subheadline)
                TextEditor(text: $previewText)
                    .font(.body)
                    .frame(minHeight: 140)
                    .layoutPriority(1)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
                    .onChange(of: selectedID) { oldID, newID in
                        commitPreview(to: oldID, text: previewText)
                        previewText = promptText(for: newID)
                    }

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        promptRow(
                            id: ChatSystemPromptStore.systemDefaultID,
                            title: "System default",
                            tooltip: draft.systemPrompt
                        )
                        ForEach(draft.namedPrompts) { entry in
                            HStack(spacing: 6) {
                                promptRow(id: entry.id, title: entry.name, tooltip: entry.text)
                                Button {
                                    renameEntry = entry
                                } label: {
                                    Image(systemName: "pencil")
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)
                                .help("Edit name")
                                Button {
                                    deletePrompt = entry
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)
                                .help("Delete prompt")
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 120)
                .layoutPriority(1)

                Button("Add System Prompt…") {
                    commitPreview(to: selectedID, text: previewText)
                    showAddPrompt = true
                }
            }
            .padding(.horizontal)

            DialogButtonRow(
                [
                    DialogButton("Cancel", isCancel: true) { closeDialog(); dismiss() },
                    DialogButton("OK", isDefault: true) { accept() },
                ],
                focusDefaultOnAppear: true
            )
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 480, minHeight: 420)
        .persistedDialogGeometry(
            DialogGeometryKey.chatSystemPrompt,
            defaultWidth: 560,
            defaultHeight: 520,
            minWidth: 480,
            minHeight: 420
        )
        .onAppear {
            draft = appState.chat.systemPromptConfig
            selectedID = draft.activeNamedPromptID.isEmpty
                ? ChatSystemPromptStore.systemDefaultID
                : draft.activeNamedPromptID
            previewText = promptText(for: selectedID)
        }
        .sheet(isPresented: $showAddPrompt) {
            ChatSystemPromptAddSheet(defaultText: previewText) { name, text in
                let id = String(UUID().uuidString.prefix(10))
                let entry = ChatNamedPrompt(id: id, name: name.isEmpty ? "Untitled" : name, text: text)
                draft.namedPrompts.append(entry)
                selectedID = id
                previewText = text
            }
        }
        .sheet(item: $renameEntry) { entry in
            ChatSystemPromptRenameSheet(name: entry.name) { newName in
                guard let idx = draft.namedPrompts.firstIndex(where: { $0.id == entry.id }) else { return }
                draft.namedPrompts[idx].name = newName.isEmpty ? "Untitled" : newName
            }
        }
        .sheet(item: $deletePrompt) { entry in
            ChatSystemPromptDeleteSheet(entry: entry) {
                draft.namedPrompts.removeAll { $0.id == entry.id }
                if selectedID == entry.id {
                    selectedID = ChatSystemPromptStore.systemDefaultID
                    previewText = promptText(for: selectedID)
                }
                if draft.activeNamedPromptID == entry.id {
                    draft.activeNamedPromptID = ""
                }
            }
        }
    }

    @ViewBuilder
    private func promptRow(id: String, title: String, tooltip: String) -> some View {
        HStack {
            Button {
                selectedID = id
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: selectedID == id ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selectedID == id ? Color.accentColor : Color.secondary)
                    Text(title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .help(tooltip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(empty prompt)" : tooltip)
        }
    }

    private func promptText(for id: String) -> String {
        if id == ChatSystemPromptStore.systemDefaultID {
            let base = draft.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return base.isEmpty ? ChatSystemPromptStore.defaultPromptText : draft.systemPrompt
        }
        return draft.namedPrompts.first(where: { $0.id == id })?.text ?? ""
    }

    private func commitPreview(to id: String, text: String) {
        let formatted = ChatPromptFormatting.formatForSave(text)
        if id == ChatSystemPromptStore.systemDefaultID {
            draft.systemPrompt = formatted
            return
        }
        guard let idx = draft.namedPrompts.firstIndex(where: { $0.id == id }) else { return }
        draft.namedPrompts[idx].text = formatted
    }

    @MainActor
    private func accept() {
        commitPreview(to: selectedID, text: previewText)
        if selectedID == ChatSystemPromptStore.systemDefaultID {
            draft.activeNamedPromptID = ""
        } else {
            draft.activeNamedPromptID = selectedID
        }
        let finalDraft = draft
        appState.chat.applySystemPromptSelection(finalDraft)
        closeDialog()
        dismiss()
    }
}

private struct ChatSystemPromptAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    let defaultText: String
    let onSave: (String, String) -> Void

    @State private var name = "New prompt"
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New prompt").font(.headline).padding([.horizontal, .top])
            Text("Name:").padding(.horizontal)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).padding(.horizontal)
            Text("System prompt:").padding(.horizontal)
            TextEditor(text: $text)
                .frame(minHeight: 160)
                .layoutPriority(1)
                .padding(.horizontal)
            DialogButtonRow([
                DialogButton("Cancel", isCancel: true) { dismiss() },
                DialogButton("Save", isDefault: true) {
                    onSave(name, ChatPromptFormatting.formatForSave(text))
                    dismiss()
                },
            ])
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 440, minHeight: 320)
        .persistedDialogGeometry(
            DialogGeometryKey.chatSystemPromptEdit,
            defaultWidth: 520,
            defaultHeight: 420,
            minWidth: 440,
            minHeight: 320,
            onlyWhenSheet: true
        )
        .onAppear { text = defaultText }
    }
}

private struct ChatSystemPromptRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    let onSave: (String) -> Void

    @State private var draftName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Edit prompt name").font(.headline).padding([.horizontal, .top])
            Text("Name:").padding(.horizontal)
            TextField("Name", text: $draftName).textFieldStyle(.roundedBorder).padding(.horizontal)
            DialogButtonRow([
                DialogButton("Cancel", isCancel: true) { dismiss() },
                DialogButton("Save", isDefault: true) {
                    onSave(draftName)
                    dismiss()
                },
            ])
            .padding()
        }
        .frame(minWidth: 360, minHeight: 140)
        .onAppear { draftName = name }
    }
}

private struct ChatSystemPromptDeleteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: ChatNamedPrompt
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delete prompt").font(.headline).padding([.horizontal, .top])
            Text("Delete \"\(entry.name)\"?").padding(.horizontal)
            ScrollView {
                Text(entry.text.isEmpty ? "(empty prompt)" : entry.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 160)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
            .padding(.horizontal)
            DialogButtonRow([
                DialogButton("No", isCancel: true) { dismiss() },
                DialogButton("Delete", isDefault: true) {
                    onDelete()
                    dismiss()
                },
            ])
            .padding()
        }
        .frame(minWidth: 440, minHeight: 260)
    }
}
