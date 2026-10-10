import SwiftUI

@MainActor
struct LoRAImportSheet: View {
    private static let weightRange = 0.1...2.0
    private static let weightStep = 0.05
    private static let weightControlWidth: CGFloat = 68

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
    @State private var reuseLoraID: String?
    @State private var isImporting = false
    @State private var progressLabel = ""
    @State private var progressStep = 0
    @State private var progressMax = 1
    @State private var errorMessage: String?
    @State private var showFindSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(modeTitle).font(.title2)
            Form {
                TextField("Safetensors path", text: $sourcePath)
                TextField("Display name", text: $displayName)
                TextField("Trigger word", text: $triggerWord)
                LabeledContent("Default weight") {
                    AppNumericSpinBox(
                        value: $bestGuess,
                        in: Self.weightRange,
                        step: Self.weightStep,
                        decimalPlaces: 2,
                        controlWidth: Self.weightControlWidth
                    )
                    .frame(width: Self.weightControlWidth)
                }
                TextField("Comment", text: $comment)
                TextField("Reference prompt (compatibility test)", text: $referencePrompt)
            }
            if isImporting {
                ProgressView(value: Double(progressStep), total: Double(max(progressMax, 1))) {
                    Text(progressLabel)
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }
            DialogButtonRow(addModeButtons)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 360)
        .onAppear {
            if !initialSourcePath.isEmpty {
                sourcePath = initialSourcePath
            }
            if case .add = mode {
                referencePrompt = LoraAddReferencePromptSettings.load(config: appState.config)
            }
            Task { await loadEditIfNeeded() }
        }
        .sheet(isPresented: $showFindSheet) {
            LoRAFindSheet(modelKey: modelKey) { choice in
                sourcePath = choice.path
                if displayName.isEmpty {
                    displayName = choice.label
                }
            }
        }
    }

    private var modeTitle: String {
        switch mode {
        case .add: return "Add LoRA file"
        case .edit: return "Edit LoRA"
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
                DialogButton("Save", isDefault: true) {
                    Task { await importAdd(skipCompatibilityProbe: false) }
                },
            ]
        }
    }

    private func loadEditIfNeeded() async {
        guard case .edit(let loraID) = mode else {
            if !sourcePath.isEmpty { await validatePath() }
            return
        }
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
                    ? LoraAddReferencePromptSettings.load(config: appState.config)
                    : fromEntry
                sourcePath = entry.localPath.isEmpty ? entry.sourcePath : entry.localPath
                reuseLoraID = loraID
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func validatePath() async {
        guard appState.workers.lora.isAvailable else { return }
        let path = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        do {
            let result = try await appState.workers.lora.validateSource(path: path, modelKey: modelKey)
            if result["valid"] as? Bool == true {
                if displayName.isEmpty {
                    displayName = result["display_name"] as? String ?? ""
                }
                if let reuse = result["reuse_lora_id"] as? String {
                    reuseLoraID = reuse
                }
            } else {
                errorMessage = result["error"] as? String ?? "Invalid LoRA file."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importAdd(skipCompatibilityProbe: Bool) async {
        guard !isImporting else { return }
        errorMessage = nil
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

        LoraAddReferencePromptSettings.save(referencePrompt, config: appState.config)

        if case .edit(let loraID) = mode {
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
                    sourcePath: path
                )
                NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
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
        ]
        if let reuseLoraID { payload["reuse_lora_id"] = reuseLoraID }
        if skipCompatibilityProbe {
            payload["skip_compatibility_probe"] = true
        }
        do {
            let result = try await appState.workers.lora.importLora(payload: payload) { activity, step, maximum in
                Task { @MainActor in
                    progressLabel = activity
                    progressStep = step
                    progressMax = maximum
                }
            }
            isImporting = false
            if result["success"] as? Bool == true {
                NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
                dismiss()
            } else {
                errorMessage = result["message"] as? String ?? "Import failed."
            }
        } catch {
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
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading) {
            Text("Find LoRA").font(.title2)
            if isLoading {
                ProgressView("Scanning…")
            } else if choices.isEmpty {
                Text("No LoRA weights found on disk.").foregroundStyle(.secondary)
            } else {
                List(choices) { choice in
                    Button(choice.label) {
                        onPick(choice)
                        dismiss()
                    }
                    .buttonStyle(.plain)
                }
            }
            DialogButtonRow([DialogButton("Close", isCancel: true) { dismiss() }])
        }
        .padding()
        .frame(width: 420, height: 400)
        .task { await load() }
    }

    private func load() async {
        guard appState.workers.lora.isAvailable else {
            isLoading = false
            return
        }
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
        }
        isLoading = false
    }
}
