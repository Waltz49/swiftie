import SwiftUI

@MainActor
struct LoRAImportSheet: View {
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
    @State private var bestGuess = "1"
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
                TextField("Default weight", text: $bestGuess)
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
            DialogButtonRow([
                DialogButton("Cancel", isCancel: true) { dismiss() },
                DialogButton("Find…") { showFindSheet = true },
                DialogButton(testAddTitle, isDefault: true) { Task { await testAndAdd() } },
            ])
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
        case .add: return "Add LoRA"
        case .edit: return "Edit LoRA"
        }
    }

    private var testAddTitle: String {
        switch mode {
        case .add: return "Test & Add"
        case .edit: return "Save"
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
                bestGuess = String(entry.bestGuess)
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

    private func testAndAdd() async {
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
                    bestGuess: Double(bestGuess) ?? 1,
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
            "best_guess": Double(bestGuess) ?? 1,
            "comment": comment,
            "reference_prompt": referencePrompt,
        ]
        if let reuseLoraID { payload["reuse_lora_id"] = reuseLoraID }
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
