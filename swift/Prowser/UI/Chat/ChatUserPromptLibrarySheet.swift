import SwiftUI

/// Port of ``ChatUserPromptLibraryDialog`` / ``run_chat_user_prompt_library``.
@MainActor
struct ChatUserPromptLibrarySheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDialog) private var closeDialog

    @State private var draft = ChatUserPromptStore.Config(selectedFavoriteID: "", favoritePrompts: [])
    @State private var selectedID = ""
    @State private var previewText = ""
    @State private var previewReadOnly = false
    @State private var showAddPrompt = false
    @State private var editEntry: ChatFavoritePrompt?
    @State private var deleteEntry: ChatFavoritePrompt?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Favorite user prompts")
                .font(.headline)
                .padding()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Select a favorite to use:")
                        .font(.subheadline)
                    AppAssetIconButton(
                        normalName: "copy",
                        hoverName: "copy_hover",
                        size: ImageGenChrome.fieldButtonSize,
                        iconSize: ImageGenChrome.fieldResetIconSize,
                        tooltip: "Copy to clipboard",
                        action: copyPreview
                    )
                    Spacer(minLength: 0)
                }

                TextEditor(text: $previewText)
                    .font(.body)
                    .frame(minHeight: 140)
                    .layoutPriority(1)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
                    .disabled(previewReadOnly)
                    .onChange(of: selectedID) { oldID, newID in
                        commitPreview(to: oldID, text: previewText)
                        loadPreview(for: newID)
                    }

                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if draft.favoritePrompts.isEmpty {
                            Text("No favorite user prompts yet.")
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                        } else {
                            ForEach(draft.favoritePrompts) { entry in
                                HStack(spacing: 6) {
                                    promptRow(entry: entry)
                                    ChatLibraryRowIconButton(
                                        normalName: "edit_icon",
                                        hoverName: "edit_icon_hover",
                                        tooltip: "Edit prompt",
                                        action: {
                                            commitPreview(to: selectedID, text: previewText)
                                            editEntry = entry
                                        }
                                    )
                                    ChatLibraryRowIconButton(
                                        normalName: "trash_icon",
                                        hoverName: "trash_icon_hover",
                                        tooltip: "Delete prompt",
                                        action: {
                                            commitPreview(to: selectedID, text: previewText)
                                            deleteEntry = entry
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 120)
                .layoutPriority(1)

                Button("Add Favorite Prompt…") {
                    commitPreview(to: selectedID, text: previewText)
                    showAddPrompt = true
                }
            }
            .padding(.horizontal)

            DialogButtonRow(
                [
                    DialogButton("Cancel", isCancel: true) {
                        closeDialog()
                        dismiss()
                    },
                    DialogButton("OK", isDefault: true) {
                        accept()
                    },
                ],
                focusDefaultOnAppear: true
            )
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 480, minHeight: 360)
        .persistedDialogGeometry(
            DialogGeometryKey.favoritePrompts,
            defaultWidth: 560,
            defaultHeight: 480,
            minWidth: 480,
            minHeight: 360
        )
        .onAppear(perform: loadInitialState)
        .sheet(isPresented: $showAddPrompt) {
            ChatUserPromptEditSheet(
                title: "New user prompt",
                initialName: "New prompt",
                initialText: appState.chat.userPromptLibrarySuggestionText,
                initialImagePaths: appState.chat.userPromptLibrarySuggestionImages
            ) { name, text, paths in
                addNewPrompt(name: name, text: text, imagePaths: paths)
            }
            .environment(appState)
        }
        .sheet(item: $editEntry) { entry in
            ChatUserPromptEditSheet(
                title: "Edit user prompt",
                initialName: entry.label,
                initialText: entry.text,
                initialImagePaths: entry.imagePaths
            ) { name, text, paths in
                updatePrompt(entryID: entry.id, name: name, text: text, imagePaths: paths)
            }
            .environment(appState)
        }
        .sheet(item: $deleteEntry) { entry in
            ChatUserPromptDeleteSheet(entry: entry) {
                deletePrompt(entryID: entry.id)
            }
        }
    }

    @ViewBuilder
    private func promptRow(entry: ChatFavoritePrompt) -> some View {
        Button {
            selectedID = entry.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selectedID == entry.id ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selectedID == entry.id ? Color.accentColor : Color.secondary)
                Text(rowLabel(for: entry))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .help(ChatUserPromptLibraryTooltip.radioTooltip(entry.text))
    }

    private func rowLabel(for entry: ChatFavoritePrompt) -> String {
        let name = entry.label.isEmpty ? "Untitled" : entry.label
        let count = ChatUserPromptFavoriteImages.existingImagePaths(entry.imagePaths).count
        if count > 0 {
            return "\(name) (\(count) image\(count == 1 ? "" : "s"))"
        }
        return name
    }

    private func loadInitialState() {
        draft = ChatUserPromptStore.load(dataDirectory: appState.config.dataDirectory)
        selectedID = draft.selectedFavoriteID
        if !draft.favoritePrompts.contains(where: { $0.id == selectedID }) {
            selectedID = draft.favoritePrompts.first?.id ?? ""
        }
        loadPreview(for: selectedID)
    }

    private func loadPreview(for id: String) {
        guard let entry = draft.favoritePrompts.first(where: { $0.id == id }) else {
            previewReadOnly = true
            previewText = ""
            return
        }
        previewReadOnly = false
        previewText = entry.text
    }

    private func commitPreview(to id: String, text: String) {
        guard !id.isEmpty, !previewReadOnly else { return }
        let formatted = ChatPromptFormatting.formatForSave(text)
        guard let idx = draft.favoritePrompts.firstIndex(where: { $0.id == id }) else { return }
        draft.favoritePrompts[idx].text = formatted
    }

    private func copyPreview() {
        if previewReadOnly {
            appState.copyTextToClipboard("")
        } else {
            appState.copyTextToClipboard(previewText)
        }
    }

    private func addNewPrompt(name: String, text: String, imagePaths: [String]) {
        let id = ChatUserPromptStore.newEntryID()
        let stored = ChatUserPromptFavoriteImages.persistFavoriteImagePaths(
            favoriteID: id,
            sourcePaths: imagePaths,
            dataDirectory: appState.config.dataDirectory,
            imageExtensions: appState.config.imageExtensions
        )
        let entry = ChatFavoritePrompt(id: id, label: name, text: text, imagePaths: stored)
        draft.favoritePrompts.append(entry)
        draft.selectedFavoriteID = id
        selectedID = id
        previewText = text
        previewReadOnly = false
    }

    private func updatePrompt(entryID: String, name: String, text: String, imagePaths: [String]) {
        guard let idx = draft.favoritePrompts.firstIndex(where: { $0.id == entryID }) else { return }
        let previous = draft.favoritePrompts[idx].imagePaths
        let stored = ChatUserPromptFavoriteImages.persistFavoriteImagePaths(
            favoriteID: entryID,
            sourcePaths: imagePaths,
            dataDirectory: appState.config.dataDirectory,
            imageExtensions: appState.config.imageExtensions
        )
        ChatUserPromptFavoriteImages.removeFavoriteImageFiles(
            paths: previous.filter { !stored.contains($0) },
            dataDirectory: appState.config.dataDirectory
        )
        draft.favoritePrompts[idx].label = name
        draft.favoritePrompts[idx].text = text
        draft.favoritePrompts[idx].imagePaths = stored
        if selectedID == entryID {
            previewText = text
        }
    }

    private func deletePrompt(entryID: String) {
        guard let idx = draft.favoritePrompts.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = draft.favoritePrompts[idx]
        ChatUserPromptFavoriteImages.removeFavoriteImageFiles(
            paths: entry.imagePaths,
            dataDirectory: appState.config.dataDirectory
        )
        draft.favoritePrompts.remove(at: idx)
        if draft.selectedFavoriteID == entryID {
            draft.selectedFavoriteID = draft.favoritePrompts.first?.id ?? ""
        }
        if selectedID == entryID {
            selectedID = draft.selectedFavoriteID
            loadPreview(for: selectedID)
        }
    }

    @MainActor
    private func accept() {
        commitPreview(to: selectedID, text: previewText)
        draft.selectedFavoriteID = selectedID
        let selected = draft.favoritePrompts.first(where: { $0.id == selectedID })
        appState.chat.finishUserPromptLibraryOK(config: draft, selectedEntry: selected)
        dismiss()
    }
}

private struct ChatLibraryRowIconButton: View {
    let normalName: String
    let hoverName: String
    let tooltip: String
    let action: () -> Void

    var body: some View {
        AppAssetIconButton(
            normalName: normalName,
            hoverName: hoverName,
            size: ChatMessageChrome.buttonSize,
            iconSize: ChatMessageChrome.iconSize,
            tooltip: tooltip,
            action: action
        )
    }
}

@MainActor
struct ChatUserPromptSaveSheet: View {
    @Environment(AppState.self) private var appState

    let draft: ChatController.UserPromptSaveDraft

    var body: some View {
        ChatUserPromptEditSheet(
            title: "Save user prompt",
            initialName: draft.defaultName,
            initialText: draft.text,
            initialImagePaths: draft.imagePaths,
            closesHostWindow: true
        ) { name, text, paths in
            appState.chat.commitSaveUserPrompt(name: name, text: text, imagePaths: paths)
        }
        .environment(appState)
    }
}

