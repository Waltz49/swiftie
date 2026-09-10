import AppKit
import SwiftUI

@MainActor
struct ImageGenPromptSection: View {
    @Environment(AppState.self) private var appState

    let function: String
    @Binding var values: [String: Any]
    @Binding var selectedPluginID: String
    let plugins: [[String: Any]]
    let sourcePath: String?
    var showNegativePrompt: Bool = false
    var onValuesChanged: (() -> Void)?

    @State private var showImportButtons = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer(minLength: 0)
                AppAssetIconButton(
                    normalName: "copy",
                    hoverName: "copy_hover",
                    tooltip: "Copy to clipboard",
                    action: copyPrompt
                )
                AppAssetIconButton(
                    normalName: "bullhorn",
                    hoverName: "bullhorn_hover",
                    tooltip: "Read prompt aloud",
                    action: speakPrompt
                )
                AppAssetIconButton(
                    normalName: "chatfav",
                    hoverName: "chatfav_hover",
                    tooltip: "Append from favorite prompts",
                    action: appendFavoritePrompt
                )
                AppAssetIconButton(
                    normalName: "trash_icon",
                    hoverName: "trash_icon_hover",
                    tooltip: "Clear prompt",
                    action: clearPrompt
                )
            }

            TextField("Prompt", text: promptBinding, axis: .vertical)
                .lineLimit(3...8)

            if showNegativePrompt {
                TextField("Negative prompt", text: negativePromptBinding, axis: .vertical)
                    .lineLimit(2...5)
            }

            if showImportButtons {
                HStack(spacing: 6) {
                    importSideButton(title: "Import Prompt", action: importPrompt)
                    importSideButton(title: "Import Rest", action: importRest)
                }
            }
        }
        .onAppear {
            showImportButtons = shouldShowImportButtons
        }
    }

    private var shouldShowImportButtons: Bool {
        switch function {
        case "create":
            return true
        case "edit", "expand", "infill":
            return sourcePath != nil
        default:
            return false
        }
    }

    private func importSideButton(title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: 112, alignment: .center)
            .help(title == "Import Prompt"
                ? "Load prompt text from the image EXIF user comment."
                : "Import seed, steps, model, and other generation settings from EXIF.")
    }

    private var promptBinding: Binding<String> {
        Binding(
            get: { values["prompt"] as? String ?? "" },
            set: { values["prompt"] = $0 }
        )
    }

    private var negativePromptBinding: Binding<String> {
        Binding(
            get: { values["negative_prompt"] as? String ?? "" },
            set: { values["negative_prompt"] = $0 }
        )
    }

    private func copyPrompt() {
        let text = values["prompt"] as? String ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appState.status.show("Copied to clipboard.")
    }

    private func speakPrompt() {
        let text = (values["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(text)
    }

    private func appendFavoritePrompt() {
        // Favorite prompt picker is chat-specific; stub shows status until ported.
        appState.status.show("Favorite prompts: use chat prompt library (not yet ported).")
    }

    private func clearPrompt() {
        values["prompt"] = ""
        onValuesChanged?()
    }

    private func importPrompt() {
        if function == "create", !isBrowseOrThumbnail {
            ImageGenExifImport.showWarning(
                title: "Import Text",
                message: "Select an image in browse view, or select a single thumbnail, before importing."
            )
            return
        }
        Task { @MainActor in
        guard let prompt = await ImageGenExifImport.importPrompt(
            function: function,
            sourcePath: sourcePath,
            appState: appState
        ) else {
            let title = function == "create" ? "Import Text" : "Import"
            if ImageGenExifImport.imagePathForImport(function: function, sourcePath: sourcePath, appState: appState) == nil {
                ImageGenExifImport.showWarning(title: title, message: "No image selected.")
            } else {
                ImageGenExifImport.showWarning(title: title, message: "No EXIF user comment was found for this image.")
            }
            return
        }
        values["prompt"] = prompt
        onValuesChanged?()
        appState.status.show("Prompt imported.")
        }
    }

    private func importRest() {
        if function == "create", !isBrowseOrThumbnail {
            ImageGenExifImport.showWarning(
                title: "Import Rest",
                message: "Select an image in browse view, or select a single thumbnail, before importing."
            )
            return
        }
        Task { @MainActor in
        guard let result = await ImageGenExifImport.applyImportRest(
            function: function,
            sourcePath: sourcePath,
            values: values,
            selectedPluginID: selectedPluginID,
            plugins: plugins,
            appState: appState
        ) else {
            if ImageGenExifImport.imagePathForImport(function: function, sourcePath: sourcePath, appState: appState) == nil {
                ImageGenExifImport.showWarning(title: "Import Rest", message: "No image selected.")
            } else {
                ImageGenExifImport.showWarning(title: "Import Rest", message: "No EXIF user comment was found for this image.")
            }
            return
        }
        values = result.values
        if let pluginID = result.selectedPluginID {
            selectedPluginID = pluginID
        }
        onValuesChanged?()
        appState.status.show("Settings imported from EXIF.")
        }
    }

    private var isBrowseOrThumbnail: Bool {
        switch appState.fileData.currentViewMode {
        case .browse, .thumbnail: return true
        default: return false
        }
    }
}
