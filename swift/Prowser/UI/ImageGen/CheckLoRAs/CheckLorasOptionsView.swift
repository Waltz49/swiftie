import SwiftUI

@MainActor
struct CheckLorasOptionsView: View {
    let choices: [CheckLorasProbeChoice]
    let installedModels: [CheckLorasInstalledModel]
    @Binding var options: CheckLorasOptions
    var loraBridge: LoRABridge
    var onCancel: () -> Void
    var onRun: () -> Void

    @State private var validationMessage: String?
    @State private var showClearHistoryConfirm = false
    @State private var clearHistoryCount = 0
    @State private var clearHistoryAlert: String?
    private var modelKeys: [String] {
        installedModels.map(\.modelKey)
    }

    private var modelDisplayName: [String: String] {
        Dictionary(uniqueKeysWithValues: installedModels.map { ($0.modelKey, $0.displayName) })
    }

    @State private var selectedModelKeys: Set<String> = []
    @State private var selectedLoraKeys: Set<String> = []
    @State private var allModels = true
    @State private var allLoras = true
    @State private var registrationMode: String = CheckLorasOptions.registrationIgnorePrevious
    @State private var probePrompt = "test"
    @State private var skipUnchanged = true
    @State private var checkCrossFamilies = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    modelsSection
                    lorasSection
                    registrationSection
                    probePromptSection
                    Toggle("Re-probe changed files only (skip unchanged weights)", isOn: $skipUnchanged)
                    Toggle(
                        "Check cross families (probe LoRAs on other host families too)",
                        isOn: $checkCrossFamilies
                    )
                    .help(
                        "When checked, each LoRA is also tested on installed base models "
                            + "outside its catalog host family. Cross-family passes are marked with * in Map LoRAs."
                    )
                }
                .padding(.horizontal, 4)
            }

            DialogButtonRow(
                [
                    DialogButton("Run", isDefault: true) { commitAndRun() },
                    DialogButton("Cancel", isCancel: true) { onCancel() },
                ],
                leadingButtons: [
                    DialogButton("Clear probe history", id: "clearHistory") {
                        Task { await beginClearProbeHistory() }
                    },
                ],
                focusDefaultOnAppear: true
            )
        }
        .padding(16)
        .onAppear { loadFromOptions() }
        .confirmationDialog(
            "Clear probe history?",
            isPresented: $showClearHistoryConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task { await performClearProbeHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Delete \(clearHistoryCount) cached probe result"
                    + (clearHistoryCount == 1 ? "" : "s")
                    + "? The next Check LoRAs run will re-render all selected LoRAs "
                    + "(unless you skip unchanged weights and files match a new entry)."
            )
        }
        .alert("Check LoRAs", isPresented: Binding(
            get: { clearHistoryAlert != nil },
            set: { if !$0 { clearHistoryAlert = nil } }
        )) {
            Button("OK", role: .cancel) { clearHistoryAlert = nil }
        } message: {
            Text(clearHistoryAlert ?? "")
        }
    }

    private func beginClearProbeHistory() async {
        do {
            let count = try await loraBridge.checkLorasProbeHistoryCount()
            if count == 0 {
                clearHistoryAlert = "Probe history is already empty."
                return
            }
            clearHistoryCount = count
            showClearHistoryConfirm = true
        } catch {
            clearHistoryAlert = error.localizedDescription
        }
    }

    private func performClearProbeHistory() async {
        do {
            let removed = try await loraBridge.checkLorasClearProbeHistory()
            clearHistoryAlert =
                "Cleared \(removed) probe history entr"
                + (removed == 1 ? "y" : "ies")
                + "."
        } catch {
            clearHistoryAlert = error.localizedDescription
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Models").font(.headline)
            Picker("Model scope", selection: $allModels) {
                Text("All models").tag(true)
                Text("Selected models").tag(false)
            }
            .pickerStyle(.radioGroup)
            HStack(spacing: 8) {
                Button("Select all") { selectedModelKeys = Set(modelKeys) }
                    .disabled(allModels || modelKeys.isEmpty)
                Button("Clear all") { selectedModelKeys = [] }
                    .disabled(allModels || modelKeys.isEmpty)
            }
            .padding(.leading, 20)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(installedModels) { model in
                    Toggle(
                        model.displayName,
                        isOn: Binding(
                            get: { selectedModelKeys.contains(model.modelKey) },
                            set: { on in
                                if on { selectedModelKeys.insert(model.modelKey) }
                                else { selectedModelKeys.remove(model.modelKey) }
                            }
                        )
                    )
                    .disabled(allModels)
                }
            }
            .padding(.leading, 20)
        }
    }

    private var lorasSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LoRAs").font(.headline)
            Picker("LoRA scope", selection: $allLoras) {
                Text("All discovered LoRAs").tag(true)
                Text("Selected LoRAs").tag(false)
            }
            .pickerStyle(.radioGroup)
            Text(
                "Found \(choices.count) LoRA weight file\(choices.count == 1 ? "" : "s") on disk."
            )
            .padding(.leading, 20)
            HStack(spacing: 8) {
                Button("Select all") { selectedLoraKeys = Set(choices.map(\.key)) }
                    .disabled(allLoras || choices.isEmpty)
                Button("Clear all") { selectedLoraKeys = [] }
                    .disabled(allLoras || choices.isEmpty)
            }
            .padding(.leading, 20)
            if choices.isEmpty {
                Text("No LoRA weights found on disk.")
                    .padding(.leading, 20)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(choices) { choice in
                            Toggle(
                                choice.label,
                                isOn: Binding(
                                    get: { selectedLoraKeys.contains(choice.key) },
                                    set: { on in
                                        if on { selectedLoraKeys.insert(choice.key) }
                                        else { selectedLoraKeys.remove(choice.key) }
                                    }
                                )
                            )
                            .disabled(allLoras)
                            .help(choice.fromDownloads
                                ? "Unregistered .safetensors (cache or Downloads)"
                                : "")
                        }
                    }
                }
                .frame(maxHeight: 220)
                .padding(.leading, 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                )
                .padding(.leading, 20)
            }
        }
    }

    private var registrationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Registration").font(.headline)
            Picker("Registration", selection: $registrationMode) {
                Text("Skip registered model/LoRA combinations")
                    .tag(CheckLorasOptions.registrationSkipRegistered)
                Text("Only registered model/LoRA combinations")
                    .tag(CheckLorasOptions.registrationOnlyRegistered)
                Text("Ignore previous registrations")
                    .tag(CheckLorasOptions.registrationIgnorePrevious)
            }
            .pickerStyle(.radioGroup)
        }
    }

    private var probePromptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Probe prompt").font(.headline)
            TextField("test", text: $probePrompt)
            Text(
                "Used for every probe render (baseline and each LoRA). "
                    + "All known triggers from the LoRAs in this run are gathered once "
                    + "and ensured in this prompt so every render uses the same text; "
                    + "you can also include triggers here yourself."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func loadFromOptions() {
        allModels = options.modelScope == CheckLorasOptions.modelScopeAll
        allLoras = options.loraScope == CheckLorasOptions.loraScopeAll
            || options.selectedLoraKeys.isEmpty
        selectedModelKeys = Set(
            options.selectedModelKeys.isEmpty ? modelKeys : options.selectedModelKeys
        )
        if options.loraScope == CheckLorasOptions.loraScopeSelected, !options.selectedLoraKeys.isEmpty {
            selectedLoraKeys = Set(options.selectedLoraKeys)
        } else {
            selectedLoraKeys = Set(choices.map(\.key))
        }
        registrationMode = options.registrationMode
        probePrompt = options.probePrompt
        skipUnchanged = options.skipUnchanged
        checkCrossFamilies = options.checkCrossFamilies
        if choices.isEmpty {
            allLoras = true
        }
    }

    private func commitAndRun() {
        validationMessage = nil
        let models = allModels ? modelKeys : selectedModelKeys.sorted()
        if !allModels, models.isEmpty {
            validationMessage = "Select at least one model, or choose All models."
            return
        }
        let loraKeys = allLoras ? choices.map(\.key) : selectedLoraKeys.sorted()
        if !allLoras, loraKeys.isEmpty {
            validationMessage = "Select at least one LoRA, or choose All discovered LoRAs."
            return
        }
        options = CheckLorasOptions(
            modelScope: allModels ? CheckLorasOptions.modelScopeAll : CheckLorasOptions.modelScopeSelected,
            selectedModelKeys: models,
            loraScope: allLoras ? CheckLorasOptions.loraScopeAll : CheckLorasOptions.loraScopeSelected,
            selectedLoraKeys: loraKeys,
            registrationMode: registrationMode,
            probePrompt: probePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "test"
                : probePrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            skipUnchanged: skipUnchanged,
            checkCrossFamilies: checkCrossFamilies
        )
        onRun()
    }
}
