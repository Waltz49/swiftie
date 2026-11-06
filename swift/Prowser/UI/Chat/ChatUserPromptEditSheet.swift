import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Thumbnail row with remove controls and file drop (Python ``ChatImageThumbRow`` in edit dialogs).
@MainActor
struct ChatEditableThumbRow: View {
    @Binding var paths: [String]
    var maxImages: Int = ChatSelectionImageTrigger.maxChatImages

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                    ZStack(alignment: .topTrailing) {
                        ChatThumbImage(path: path)
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Button {
                            paths.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.isFileURL else { return }
                let path = url.standardizedFileURL.path
                Task { @MainActor in
                    guard !paths.contains(path), paths.count < maxImages else { return }
                    paths.append(path)
                }
            }
        }
        return accepted
    }
}

@MainActor
struct ChatUserPromptEditSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closeDialog) private var closeDialog

    let title: String
    let initialName: String
    let initialText: String
    let initialImagePaths: [String]
    var closesHostWindow = false
    let onSave: (String, String, [String]) -> Void

    @State private var name = ""
    @State private var text = ""
    @State private var imagePaths: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding([.horizontal, .top])

            Text("Name:")
                .padding(.horizontal)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            Text("User prompt:")
                .padding(.horizontal)
            TextEditor(text: $text)
                .frame(minHeight: 160)
                .layoutPriority(1)
                .padding(.horizontal)
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    appendDroppedImages(providers)
                }

            ChatEditableThumbRow(paths: $imagePaths)
                .padding(.horizontal)

            DialogButtonRow(
                [
                    DialogButton("Cancel", isCancel: true) { closeEditor() },
                    DialogButton("Save", isDefault: true) {
                        let saveName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let formatted = ChatPromptFormatting.formatForSave(text)
                        onSave(
                            saveName.isEmpty ? "Untitled" : saveName,
                            formatted,
                            imagePaths
                        )
                        closeEditor()
                    },
                ],
                leading: {
                    ChatPromptGrammarButton(text: $text)
                }
            )
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 480, minHeight: 360)
        .persistedDialogGeometry(
            DialogGeometryKey.favoritePromptEdit,
            defaultWidth: 560,
            defaultHeight: 440,
            minWidth: 480,
            minHeight: 360,
            onlyWhenSheet: !closesHostWindow
        )
        .onAppear {
            name = initialName
            text = initialText
            imagePaths = initialImagePaths
        }
        .onKeyPress(.return, phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            let saveName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let formatted = ChatPromptFormatting.formatForSave(text)
            onSave(saveName.isEmpty ? "Untitled" : saveName, formatted, imagePaths)
            closeEditor()
            return .handled
        }
    }

    private func closeEditor() {
        if closesHostWindow {
            closeDialog()
        }
        dismiss()
    }

    private func appendDroppedImages(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.isFileURL else { return }
                let path = url.standardizedFileURL.path
                Task { @MainActor in
                    guard !imagePaths.contains(path), imagePaths.count < ChatSelectionImageTrigger.maxChatImages else {
                        return
                    }
                    imagePaths.append(path)
                }
            }
        }
        return accepted
    }
}

@MainActor
struct ChatUserPromptDeleteSheet: View {
    @Environment(\.dismiss) private var dismiss

    let entry: ChatFavoritePrompt
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delete user prompt")
                .font(.headline)
                .padding([.horizontal, .top])
            Text("Delete \"\(entry.label.isEmpty ? "Untitled" : entry.label)\"?")
                .padding(.horizontal)
            ScrollView {
                Text(entry.text.isEmpty ? "(empty prompt)" : entry.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 260)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
            .padding(.horizontal)

            let imageCount = ChatUserPromptFavoriteImages.existingImagePaths(entry.imagePaths).count
            if imageCount > 0 {
                Text("\(imageCount) attached image\(imageCount == 1 ? "" : "s")")
                    .padding(.horizontal)
            }

            DialogButtonRow([
                DialogButton("No", isCancel: true) { dismiss() },
                DialogButton("Delete", isDefault: true) {
                    onDelete()
                    dismiss()
                },
            ])
            .padding()
        }
        .frame(minWidth: 440, minHeight: 280)
    }
}
