import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let defaultReferencePrompt = "test image of person standing"

@MainActor
struct LoRAImportSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum Mode {
        case add
        case edit(loraID: String)
    }

    let mode: Mode
    let modelKey: String
    var initialSourcePath: String?

    @State private var sourcePath = ""
    @State private var displayName = ""
    @State private var triggerWord = ""
    @State private var referencePrompt = defaultReferencePrompt
    @State private var currentScale = 1.0
    @State private var bestGuess = 1.0
    @State private var comment = ""
    @State private var repoID = ""
    @State private var filename = ""
    @State private var recoveryPath = ""
    @State private var reuseLoraID: String?
    @State private var isReusing = false
    @State private var pathReadOnly = false
    @State private var errorMessage = ""
    @State private var showFindSheet = false
    @State private var isFindingOrigin = false
    @State private var introText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(modeTitle)
                .font(.headline)
            Text(introText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Form {
                if modeIsAdd || !pathReadOnly {
                    HStack(spacing: 8) {
                        TextField("Drop a .safetensors file here or paste a path…", text: $sourcePath)
                            .textFieldStyle(.roundedBorder)
                            .disabled(pathReadOnly)
                            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                                handleDrop(providers)
                            }
                            .onChange(of: sourcePath) { _, newValue in
                                Task { await validatePath(newValue) }
                            }
                        Button("Browse…") { browseForFile() }
                            .disabled(pathReadOnly)
                        if modeIsAdd {
                            Button("Find") { showFindSheet = true }
                        }
                    }
                }
                TextField("Display name", text: $displayName)
                TextField("Trigger word (optional)", text: $triggerWord)
                TextField("Reference prompt", text: $referencePrompt)
                HStack {
                    Text("Current:")
                    Text(String(format: "%.2f", currentScale))
                        .foregroundStyle(.secondary)
                    Text("Best guess:")
                    TextField("", value: $bestGuess, format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                }
                TextField("Comment (optional)", text: $comment)
                TextField("HF repo (optional)", text: $repoID)
                TextField("HF file (optional)", text: $filename)
                TextField("Recovery path or URL", text: $recoveryPath)
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        handleRecoveryDrop(providers)
                    }
            }
            .formStyle(.grouped)

            if !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            DialogButtonRow([
                DialogButton("Cancel", isCancel: true) { dismiss() },
                DialogButton(primaryButtonTitle, isDefault: true) {
                    Task { await primaryAction() }
                },
            ], leadingButtons: modeIsEdit ? [
                DialogButton("Find source online", isEnabled: !isFindingOrigin) {
                    Task { await findOriginOnline() }
                },
            ] : [], focusDefaultOnAppear: true)
        }
        .padding(16)
        .frame(width: 580)
        .task { await loadInitialState() }
        .sheet(isPresented: $showFindSheet) {
            LoRAFindSheet(modelKey: modelKey) { choice in
                applyFindChoice(choice)
            }
        }
        .overlay {
            if appState.workers.lora.isImporting {
                LoRAImportProgressOverlay(
                    progress: appState.workers.lora.importProgress,
                    onCancel: {
                        Task { await appState.workers.lora.cancelImport() }
                    }
                )
            }
        }
    }

    private var modeIsAdd: Bool {
        if case .add = mode { return true }
        return false
    }

    private var modeIsEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var modeTitle: String {
        modeIsAdd ? "Add Downloaded LoRA" : "Edit LoRA"
    }

    private var primaryButtonTitle: String {
        modeIsAdd ? "Test & Add" : "Save"
    }

    private func loadInitialState() async {
        updateIntro(reusing: false)
        if let initialSourcePath, !initialSourcePath.isEmpty {
            sourcePath = initialSourcePath
            await validatePath(initialSourcePath)
        }
        if case .edit(let loraID) = mode {
            do {
                let entry = try await appState.workers.lora.getEntry(loraID: loraID, modelKey: modelKey)
                displayName = entry.displayName
                triggerWord = entry.triggerWord
                referencePrompt = entry.referencePrompt.isEmpty ? defaultReferencePrompt : entry.referencePrompt
                currentScale = entry.scale
                bestGuess = entry.bestGuess
                comment = entry.comment
                repoID = entry.repoID
                filename = entry.filename
                if !entry.localPath.isEmpty {
                    sourcePath = entry.localPath
                    pathReadOnly = true
                }
                let recovery = entry.sourcePath.isEmpty ? entry.localPath : entry.sourcePath
                recoveryPath = recovery
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            referencePrompt = defaultReferencePrompt
        }
    }

    private func updateIntro(reusing: Bool) {
        if modeIsEdit {
            introText = "Edit LoRA details for this base model."
            return
        }
        if reusing {
            introText = "This file is already imported. Adding will enable it for this base model using the existing LoRA entry."
        } else {
            introText = "Import a .safetensors LoRA. The file is copied into the app cache and tested before it is added."
        }
    }

    private func validatePath(_ path: String) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reuseLoraID = nil
            isReusing = false
            updateIntro(reusing: false)
            return
        }
        do {
            let result = try await appState.workers.lora.validateSource(modelKey: modelKey, path: trimmed)
            guard result["valid"] as? Bool == true else {
                reuseLoraID = nil
                isReusing = false
                if displayName.isEmpty, let suggested = result["display_name"] as? String {
                    displayName = suggested
                }
                updateIntro(reusing: false)
                return
            }
            if let displayPath = result["display_path"] as? String, displayPath != trimmed {
                sourcePath = displayPath
            }
            if result["reusing"] as? Bool == true {
                reuseLoraID = result["reuse_lora_id"] as? String
                isReusing = true
                displayName = result["display_name"] as? String ?? displayName
                triggerWord = result["trigger_word"] as? String ?? triggerWord
                if let ref = result["reference_prompt"] as? String, !ref.isEmpty {
                    referencePrompt = ref
                }
                currentScale = result["scale"] as? Double ?? currentScale
                bestGuess = result["best_guess"] as? Double ?? bestGuess
                comment = result["comment"] as? String ?? comment
            } else {
                reuseLoraID = nil
                isReusing = false
                if displayName.isEmpty, let suggested = result["display_name"] as? String {
                    displayName = suggested
                }
            }
            updateIntro(reusing: isReusing)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func browseForFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "safetensors") ?? .data]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sourcePath = url.path
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.pathExtension.lowercased() == "safetensors" else { return }
            Task { @MainActor in
                sourcePath = url.path
            }
        }
        return true
    }

    private func handleRecoveryDrop(_ providers: [NSItemProvider]) -> Bool {
        handleDrop(providers)
    }

    private func applyFindChoice(_ choice: LoRAFindChoice) {
        if !choice.weightsPath.isEmpty {
            sourcePath = choice.weightsPath
        }
        if !choice.displayName.isEmpty {
            displayName = choice.displayName
        }
        triggerWord = choice.triggerWord
        if !isReusing {
            currentScale = choice.scale
            bestGuess = 1.0
        }
        comment = choice.comment
        repoID = choice.repoID
        filename = choice.filename
        let recovery = choice.sourcePath.isEmpty ? choice.weightsPath : choice.sourcePath
        if !recovery.isEmpty {
            recoveryPath = recovery
        }
    }

    private func primaryAction() async {
        errorMessage = ""
        if modeIsEdit, case .edit(let loraID) = mode {
            do {
                try await appState.workers.lora.saveMetadata(
                    loraID: loraID,
                    displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                    triggerWord: triggerWord,
                    bestGuess: bestGuess,
                    comment: comment,
                    referencePrompt: referencePrompt,
                    repoID: repoID,
                    filename: filename,
                    sourcePath: recoveryPath
                )
                NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        }

        let path = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            errorMessage = "Choose a .safetensors file."
            return
        }
        if name.isEmpty {
            errorMessage = "Enter a display name."
            return
        }
        let recovery = recoveryPath.isEmpty ? path : recoveryPath
        do {
            try await appState.workers.lora.importLoRA(
                modelKey: modelKey,
                sourcePath: path,
                displayName: name,
                triggerWord: triggerWord,
                bestGuess: bestGuess,
                comment: comment,
                referencePrompt: referencePrompt,
                reuseLoraID: reuseLoraID,
                repoID: repoID,
                filename: filename,
                recoverySourcePath: recovery,
                onComplete: { success, message, _ in
                    if success {
                        NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
                        dismiss()
                        appState.status.show("«\(name)» was added and enabled.")
                    } else if !message.isEmpty && message != "Cancelled" {
                        errorMessage = message
                    }
                }
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func findOriginOnline() async {
        guard case .edit(let loraID) = mode else { return }
        isFindingOrigin = true
        defer { isFindingOrigin = false }
        do {
            try await appState.workers.lora.findOrigin(loraID: loraID) { success, message in
                if success {
                    Task {
                        if let entry = try? await appState.workers.lora.getEntry(loraID: loraID, modelKey: modelKey) {
                            triggerWord = entry.triggerWord
                            comment = entry.comment
                            repoID = entry.repoID
                            filename = entry.filename
                            recoveryPath = entry.sourcePath.isEmpty ? entry.localPath : entry.sourcePath
                        }
                    }
                    appState.status.show(message)
                } else if !message.isEmpty {
                    errorMessage = message
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct LoRAFindSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let modelKey: String
    let onSelect: (LoRAFindChoice) -> Void

    @State private var choices: [LoRAFindChoice] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find LoRA").font(.headline)
            Text("Double-click a LoRA name to fill the Add LoRA form.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isLoading {
                ProgressView("Looking up on-disk LoRA files…")
            } else if choices.isEmpty {
                Text("No LoRA weights found on disk.")
                    .foregroundStyle(.secondary)
            } else {
                List(choices) { choice in
                    Text(choice.displayName)
                        .onTapGesture(count: 2) {
                            onSelect(choice)
                            dismiss()
                        }
                }
            }
            DialogButtonRow([
                DialogButton("Cancel", isDefault: true, isCancel: true) { dismiss() },
            ], focusDefaultOnAppear: true)
        }
        .padding(16)
        .frame(width: 480, height: 420)
        .task {
            isLoading = true
            choices = (try? await appState.workers.lora.findChoices()) ?? []
            isLoading = false
        }
    }
}

@MainActor
private struct LoRAImportProgressOverlay: View {
    let progress: LoRAImportProgress?
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                Text("Add LoRA").font(.headline)
                Text(progress?.activity ?? "Starting…")
                    .font(.caption)
                if let progress {
                    ProgressView(
                        value: Double(progress.step),
                        total: Double(max(progress.maximum, 1))
                    )
                    Text("\(progress.step) / \(progress.maximum)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
                DialogButtonRow([
                    DialogButton("Cancel", isDefault: true, isCancel: true, action: onCancel),
                ], focusDefaultOnAppear: true)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .frame(width: 420)
        }
    }
}
