import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

            ChatImageThumbRow(paths: $imagePaths, allowRemove: true)
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
        ChatImageThumbDrop.acceptFileURLs(
            from: providers,
            imageExtensions: appState.config.imageExtensions,
            existingPaths: imagePaths,
            maxImages: ChatSelectionImageTrigger.maxChatImages
        ) { added in
            imagePaths.append(contentsOf: added)
        }
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
