import AppKit
import SwiftUI

@MainActor
struct LoRAImportSheet: View {
    private static let weightRange = 0.1...2.0
    private static let weightStep = 0.05
    private static let weightControlWidth: CGFloat = 68
    private static let referencePromptEditorMinHeight: CGFloat = 88

    enum Mode {
        case add
        case edit(loraID: String)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let mode: Mode
    let modelKey: String
    var initialSourcePath: String = ""

    @State private var sourcePath = ""
    @State private var displayName = ""
    @State private var triggerWord = ""
    @State private var bestGuess = 1.0
    @State private var comment = ""
    @State private var referencePrompt = ""
    @State private var safetensorsOrigin = ""
    @State private var webPageURL = ""
    @State private var reuseLoraID: String?
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showFindSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(modeTitle).font(.title2)
            Form {
                LabeledContent("LoRA location") {
                    HStack(spacing: 6) {
                        TextField("Path to .safetensors", text: $sourcePath)
                        Button("Choose…") {
                            chooseSafetensorsFile()
                        }
                    }
                }
                TextField("Display name", text: $displayName)
                TextField("Trigger word", text: $triggerWord)
                    .imageGenPromptTriggerSentenceCaseOnBlur($triggerWord)
                LabeledContent("Default weight") {
                    AppNumericSpinBox(
                        value: $bestGuess,
                        in: Self.weightRange,
                        step: Self.weightStep,
                        decimalPlaces: 2,
                        controlWidth: Self.weightControlWidth
                    )
                    .frame(width: Self.weightControlWidth)
                    .fixedSize(horizontal: false, vertical: true)
                }
                TextField("Comment", text: $comment)
                    .imageGenPromptSentenceCaseOnBlur($comment)
                LabeledContent("Safetensors origin") {
                    HStack(spacing: 6) {
                        TextField("Download URL", text: $safetensorsOrigin)
                        LoRAImportCopyButton(text: safetensorsOrigin)
                    }
                }
                LabeledContent("Web page") {
                    HStack(spacing: 6) {
                        TextField("Model description URL", text: $webPageURL)
                        LoRAImportOpenWebButton(urlString: webPageURL) { NSWorkspace.shared.open($0) }
                    }
                }
            }
            referencePromptSection
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }
            DialogButtonRow(addModeButtons)
                .disabled(isImporting)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 520, minHeight: 480)
        .persistedDialogGeometry(
            DialogGeometryKey.loraImport,
            defaultWidth: 640,
            defaultHeight: 640,
            minWidth: 520,
            minHeight: 480,
            onlyWhenSheet: true
        )
        // Normalizes bound field text only; catalog/settings are written in importAdd on Save.
        .imageGenPromptSentenceCaseClickAwayCommit()
        .onAppear {
            if !initialSourcePath.isEmpty {
                sourcePath = initialSourcePath
            }
            if case .add = mode {
                referencePrompt = LoraAddReferencePromptSettings.load(config: appState.config)
            }
            Task { await loadEditIfNeeded() }
        }
        .onChange(of: sourcePath) { _, _ in
            guard case .add = mode else { return }
            Task { await validatePath() }
        }
        .background(CopyFeedbackWindowInstaller())
        .sheet(isPresented: $showFindSheet) {
            LoRAFindSheet(modelKey: modelKey) { choice in
                sourcePath = choice.path
                let name = choice.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !name.isEmpty {
                    displayName = name
                }
                Task { await validatePath() }
            }
        }
    }

    private var modeTitle: String {
        switch mode {
        case .add: return "Add LoRA file"
        case .edit: return "Edit LoRA"
        }
    }

    private var referencePromptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Reference prompt")
                    .font(.headline)
                Spacer()
                LoRAImportCopyButton(text: referencePrompt)
            }
            Text("Used for compatibility test images for this LoRA.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LoRAReferencePromptEditor(text: $referencePrompt)
                .frame(minHeight: Self.referencePromptEditorMinHeight)
                .layoutPriority(1)
        }
    }

    private var addModeButtons: [DialogButton] {
        switch mode {
        case .add:
            return [
                DialogButton("Cancel", isCancel: true) { dismiss() },
                DialogButton("Find…") { showFindSheet = true },
                DialogButton(
                    "Save",
                    help: "Save without a GPU test; compatibility with this base model is assumed."
                ) {
                    Task { await importAdd(skipCompatibilityProbe: true) }
                },
                DialogButton("Test & Save", isDefault: true) {
                    Task { await importAdd(skipCompatibilityProbe: false) }
                },
            ]
        case .edit:
            return [
                DialogButton("Cancel", isCancel: true) { dismiss() },
                DialogButton("Find…") { showFindSheet = true },
                DialogButton(
                    "Save",
                    help: "Save metadata without a GPU compatibility test."
                ) {
                    Task { await importAdd(skipCompatibilityProbe: true) }
                },
                DialogButton("Test & Save", isDefault: true) {
                    Task { await importAdd(skipCompatibilityProbe: false) }
                },
            ]
        }
    }

    private func chooseSafetensorsFile() {
        SettingsSupport.pickFile(into: $sourcePath, allowedTypes: ["safetensors"])
    }

    private func loadEditIfNeeded() async {
        guard case .edit(let loraID) = mode else { return }
        guard appState.workers.lora.isAvailable else { return }
        do {
            if let entry = try await appState.workers.lora.getEntry(loraID: loraID, modelKey: modelKey) {
                displayName = entry.displayName
                triggerWord = entry.triggerWord
                bestGuess = min(Self.weightRange.upperBound, max(Self.weightRange.lowerBound, entry.bestGuess))
                comment = entry.comment
                let fromEntry = entry.referencePrompt
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                referencePrompt = fromEntry.isEmpty
                    ? LoraAddReferencePromptSettings.defaultPrompt
                    : fromEntry
                sourcePath = entry.localPath.isEmpty ? entry.sourcePath : entry.localPath
                safetensorsOrigin = entry.safetensorsOrigin
                webPageURL = entry.webPageURL
                if safetensorsOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   webPageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    let legacy = LoRALegacyURLPrefill.suggestions(fromLegacySourcePath: entry.sourcePath)
                    if let origin = legacy.safetensorsOrigin {
                        safetensorsOrigin = origin
                    }
                    if let page = legacy.webPageURL {
                        webPageURL = page
                    }
                }
                reuseLoraID = loraID
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func defaultLabelFromPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let filename = (trimmed as NSString).lastPathComponent
        let stem = (filename as NSString).deletingPathExtension
        return stem.isEmpty ? filename : stem
    }

    private func applyFilenameDefaultsIfNeeded(for path: String) {
        let suggested = Self.defaultLabelFromPath(path)
        guard !suggested.isEmpty else { return }
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayName = suggested
        }
    }

    private func applyPrimingFromValidation(_ result: [String: Any]) {
        if triggerWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let trigger = result["trigger_word"] as? String,
               !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                triggerWord = trigger
            } else {
                let path = (result["display_path"] as? String ?? sourcePath)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !path.isEmpty {
                    let fallback = Self.defaultLabelFromPath(path)
                    if !fallback.isEmpty { triggerWord = fallback }
                }
            }
        }
        if safetensorsOrigin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let origin = result["safetensors_origin"] as? String,
           !origin.isEmpty
        {
            safetensorsOrigin = origin
        }
        if webPageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let page = result["web_page_url"] as? String,
           !page.isEmpty
        {
            webPageURL = page
        }
    }

    private func applyReuseMetadata(from result: [String: Any]) {
        if let name = result["display_name"] as? String {
            displayName = name
        }
        triggerWord = result["trigger_word"] as? String ?? ""
        if let best = result["best_guess"] as? Double {
            bestGuess = min(Self.weightRange.upperBound, max(Self.weightRange.lowerBound, best))
        } else if let best = result["best_guess"] as? NSNumber {
            let value = best.doubleValue
            bestGuess = min(Self.weightRange.upperBound, max(Self.weightRange.lowerBound, value))
        }
        comment = result["comment"] as? String ?? ""
        let ref = (result["reference_prompt"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        referencePrompt = ref.isEmpty ? LoraAddReferencePromptSettings.defaultPrompt : ref
        safetensorsOrigin = result["safetensors_origin"] as? String ?? safetensorsOrigin
        webPageURL = result["web_page_url"] as? String ?? webPageURL
    }

    private func validatePath() async {
        guard case .add = mode else { return }
        guard appState.workers.lora.isAvailable else { return }
        let path = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            reuseLoraID = nil
            return
        }
        do {
            let result = try await appState.workers.lora.validateSource(path: path, modelKey: modelKey)
            if let displayPath = result["display_path"] as? String,
               !displayPath.isEmpty,
               displayPath != path
            {
                sourcePath = displayPath
            }
            let resolvedPath = (result["display_path"] as? String ?? path)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if result["valid"] as? Bool == true {
                errorMessage = nil
                if result["reusing"] as? Bool == true {
                    applyReuseMetadata(from: result)
                    reuseLoraID = result["reuse_lora_id"] as? String
                } else {
                    reuseLoraID = nil
                    applyFilenameDefaultsIfNeeded(for: resolvedPath)
                    applyPrimingFromValidation(result)
                }
            } else {
                reuseLoraID = nil
                applyFilenameDefaultsIfNeeded(for: resolvedPath.isEmpty ? path : resolvedPath)
                errorMessage = result["error"] as? String ?? "Invalid LoRA file."
            }
        } catch {
            reuseLoraID = nil
            applyFilenameDefaultsIfNeeded(for: path)
            errorMessage = error.localizedDescription
        }
    }

    private func importAdd(skipCompatibilityProbe: Bool) async {
        guard !isImporting else { return }
        errorMessage = nil
        ImageGenPromptSentenceCase.flushLoraMetadataStrings(
            triggerWord: &triggerWord,
            comment: &comment,
            referencePrompt: &referencePrompt
        )
        let path = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            errorMessage = "Choose a .safetensors file."
            return
        }
        guard !displayName.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Enter a display name."
            return
        }
        guard appState.workers.lora.isAvailable else {
            errorMessage = "LoRA services are not available."
            return
        }
        if !LoRAURLValidation.isValidOrEmpty(safetensorsOrigin) {
            errorMessage = "Safetensors origin must be a valid http or https URL."
            return
        }
        if !LoRAURLValidation.isValidOrEmpty(webPageURL) {
            errorMessage = "Web page must be a valid http or https URL."
            return
        }

        // Persist only when the user confirms Save / Test & Save; Cancel and Esc dismiss without this path.
        LoraAddReferencePromptSettings.save(referencePrompt, config: appState.config)

        if case .edit(let loraID) = mode, skipCompatibilityProbe {
            do {
                try await appState.workers.lora.saveMetadata(
                    loraID: loraID,
                    displayName: displayName,
                    triggerWord: triggerWord,
                    bestGuess: bestGuess,
                    comment: comment,
                    referencePrompt: referencePrompt,
                    repoID: "",
                    filename: "",
                    sourcePath: path,
                    safetensorsOrigin: safetensorsOrigin,
                    webPageURL: webPageURL
                )
                NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        guard appState.workers.lora.pythonOpsAvailable else {
            errorMessage = "Image generation Python environment is not ready."
            return
        }

        isImporting = true
        var payload: [String: Any] = [
            "model_key": modelKey,
            "source_path": path,
            "display_name": displayName,
            "trigger_word": triggerWord,
            "best_guess": bestGuess,
            "comment": comment,
            "reference_prompt": referencePrompt,
            "safetensors_origin": safetensorsOrigin,
            "web_page_url": webPageURL,
            "recovery_source_path": path,
        ]
        if case .edit(let loraID) = mode {
            payload["reuse_lora_id"] = loraID
        } else if let reuseLoraID {
            payload["reuse_lora_id"] = reuseLoraID
        }
        if skipCompatibilityProbe {
            payload["skip_compatibility_probe"] = true
        }

        let isEditImport: Bool
        if case .edit = mode {
            isEditImport = true
        } else {
            isEditImport = false
        }
        let title: String = {
            if isEditImport {
                return skipCompatibilityProbe ? "Edit LoRA — Saving" : "Edit LoRA"
            }
            return skipCompatibilityProbe ? "Add LoRA — Saving" : "Add LoRA"
        }()
        let progress = CancellableProgressPanelController(
            title: title,
            labelText: skipCompatibilityProbe ? "Saving…" : "Starting…",
            maximum: 100,
            showsTimeRemainingEstimate: false,
            throttleProgressUpdates: false,
            accessoryButtonTitle: "Work directory"
        )
        progress.onCancel = {
            Task { try? await appState.workers.lora.cancelImport() }
        }
        progress.onAccessory = {
            appState.openProfileTemporaryWorkDirectoryInThumbnailView()
        }
        progress.setAccessoryButtonEnabled(
            CheckLorasWorkDirectory.containsWorkImages(config: appState.config)
        )
        progress.show()

        var workDirectoryRefreshTimer: Timer?
        workDirectoryRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                progress.setAccessoryButtonEnabled(
                    CheckLorasWorkDirectory.containsWorkImages(config: appState.config)
                )
            }
        }

        do {
            let result = try await appState.workers.lora.importLora(payload: payload) { activity, step, maximum in
                Task { @MainActor in
                    progress.setMaximum(max(1, maximum))
                    progress.update(value: step, label: activity)
                }
            }
            workDirectoryRefreshTimer?.invalidate()
            progress.close()
            isImporting = false
            if result["success"] as? Bool == true {
                NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
                dismiss()
            } else {
                errorMessage = result["message"] as? String ?? "Import failed."
            }
        } catch {
            workDirectoryRefreshTimer?.invalidate()
            progress.close()
            isImporting = false
            errorMessage = error.localizedDescription
        }
    }
}

struct LoRAFindChoice: Identifiable {
    let id: String
    let label: String
    let path: String
}

@MainActor
struct LoRAFindSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let modelKey: String
    let onPick: (LoRAFindChoice) -> Void

    @State private var choices: [LoRAFindChoice] = []
    @State private var filterText = ""
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var filteredChoices: [LoRAFindChoice] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return choices }
        return choices.filter {
            $0.label.lowercased().contains(needle) || $0.path.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Find LoRA").font(.title2)
            Text("Double-click a name to fill the Add LoRA form. Weights are scanned from LoRA cache folders and top-level Downloads.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isLoading {
                ProgressView("Looking up on-disk LoRA files…")
            } else {
                TextField("Search", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.caption)
                } else if choices.isEmpty {
                    Text("No LoRA weights found on disk.").foregroundStyle(.secondary)
                } else if filteredChoices.isEmpty {
                    Text("No names match your search.").foregroundStyle(.secondary)
                } else {
                    List(filteredChoices) { choice in
                        Button(choice.label) {
                            onPick(choice)
                            dismiss()
                        }
                        .buttonStyle(.plain)
                        .help(choice.path)
                    }
                }
            }
            DialogButtonRow([DialogButton("Close", isCancel: true) { dismiss() }])
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 480, minHeight: 440)
        .persistedDialogGeometry(
            DialogGeometryKey.loraFind,
            defaultWidth: 560,
            defaultHeight: 520,
            minWidth: 480,
            minHeight: 440,
            onlyWhenSheet: true
        )
        .task { await load() }
    }

    private func load() async {
        guard appState.workers.lora.isAvailable else {
            errorMessage = "LoRA settings are not available."
            isLoading = false
            return
        }
        errorMessage = nil
        do {
            let raw = try await appState.workers.lora.findChoices()
            choices = raw.compactMap { dict in
                let path = dict["weights_path"] as? String ?? dict["path"] as? String ?? ""
                let label = dict["display_name"] as? String ?? dict["label"] as? String ?? path
                guard !path.isEmpty else { return nil }
                return LoRAFindChoice(id: path, label: label, path: path)
            }
        } catch {
            choices = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
