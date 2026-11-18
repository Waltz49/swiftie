import SwiftUI

@MainActor
struct CheckLorasOptionsView: View {
    let choices: [CheckLorasProbeChoice]
    let installedModels: [CheckLorasInstalledModel]
    @Binding var options: CheckLorasOptions
    var appConfig: AppConfig
    var loraBridge: LoRABridge
    var onCancel: () -> Void
    var onRun: (CheckLorasOptions) -> Void
    var onShowPreviousReport: () -> Void

    @State private var validationMessage: String?
    @State private var showClearHistoryConfirm = false
    @State private var clearHistoryCount = 0
    @State private var clearHistoryAlert: String?
    private var canRun: Bool {
        guard !modelKeys.isEmpty, !choices.isEmpty else { return false }
        let models = allModels ? modelKeys : Array(selectedModelKeys)
        guard !models.isEmpty else { return false }
        return !resolvedLoraKeysForScope().isEmpty
    }

    private var sortedInstalledModels: [CheckLorasInstalledModel] {
        installedModels.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var sortedChoices: [CheckLorasProbeChoice] {
        choices.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    private var modelKeys: [String] {
        sortedInstalledModels.map(\.modelKey)
    }

    private var allLoraChoiceKeys: Set<String> {
        Set(choices.map(\.key))
    }

    private var allModelsSelected: Bool {
        !modelKeys.isEmpty && selectedModelKeys == Set(modelKeys)
    }

    private var allLorasSelected: Bool {
        !choices.isEmpty && selectedLoraKeys == allLoraChoiceKeys
    }

    @State private var selectedModelKeys: Set<String>
    @State private var selectedLoraKeys: Set<String>
    @State private var allModels: Bool
    @State private var allLoras: Bool
    @State private var registrationMode: String
    @State private var probePrompt: String
    @State private var skipUnchanged: Bool
    @State private var checkCrossFamilies: Bool
    @State private var removeDownloadsAfterImport: Bool
    init(
        choices: [CheckLorasProbeChoice],
        installedModels: [CheckLorasInstalledModel],
        options: Binding<CheckLorasOptions>,
        appConfig: AppConfig,
        loraBridge: LoRABridge,
        onCancel: @escaping () -> Void,
        onRun: @escaping (CheckLorasOptions) -> Void,
        onShowPreviousReport: @escaping () -> Void = {}
    ) {
        self.choices = choices
        self.installedModels = installedModels
        _options = options
        self.appConfig = appConfig
        self.loraBridge = loraBridge
        self.onCancel = onCancel
        self.onRun = onRun
        self.onShowPreviousReport = onShowPreviousReport

        let modelKeys = installedModels
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            .map(\.modelKey)
        let local = Self.localState(from: options.wrappedValue, choices: choices, modelKeys: modelKeys)
        _selectedModelKeys = State(initialValue: local.selectedModelKeys)
        _selectedLoraKeys = State(initialValue: local.selectedLoraKeys)
        _allModels = State(initialValue: local.allModels)
        _allLoras = State(initialValue: local.allLoras)
        _registrationMode = State(initialValue: local.registrationMode)
        _probePrompt = State(initialValue: local.probePrompt)
        _skipUnchanged = State(initialValue: local.skipUnchanged)
        _checkCrossFamilies = State(initialValue: local.checkCrossFamilies)
        _removeDownloadsAfterImport = State(initialValue: options.wrappedValue.removeDownloadsAfterImport)
        _validationMessage = State(initialValue: nil)
        _showClearHistoryConfirm = State(initialValue: false)
        _clearHistoryCount = State(initialValue: 0)
        _clearHistoryAlert = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    probePromptSection
                    registrationSection
                    downloadsLibrarySection
                    Toggle("Re-probe changed files only (skip unchanged weights)", isOn: $skipUnchanged)
                    Toggle(
                        "Test on other base model families",
                        isOn: $checkCrossFamilies
                    )
                    .help(
                        "When checked, each LoRA is also tested on installed base models "
                            + "outside its usual family. Cross-family passes are marked with * in Map LoRAs."
                    )
                    modelsSection
                    lorasSection
                }
                .padding(.horizontal, 4)
            }

            DialogButtonRow(
                [
                    DialogButton("Run", isDefault: true, isEnabled: canRun) { commitAndRun() },
                    DialogButton("Cancel", isCancel: true) { onCancel() },
                ],
                leadingButtons: [
                    DialogButton("Previous report", id: "previousReport") {
                        onShowPreviousReport()
                    },
                    DialogButton("Clear probe history", id: "clearHistory") {
                        Task { await beginClearProbeHistory() }
                    },
                ],
                focusDefaultOnAppear: true
            )
        }
        .padding(16)
        .onAppear { loadFromOptions() }
        .onChange(of: allLoras) { _, isAll in
            if isAll {
                selectedLoraKeys = allLoraChoiceKeys
            }
        }
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
                    + "? The next Test LoRAs run will re-render all selected LoRAs "
                    + "(unless you skip unchanged weights and files match a new entry)."
            )
        }
        .alert("Test LoRAs", isPresented: Binding(
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
                    .disabled(allModels || modelKeys.isEmpty || allModelsSelected)
                Button("Clear all") { selectedModelKeys = [] }
                    .disabled(allModels || modelKeys.isEmpty || selectedModelKeys.isEmpty)
            }
            .padding(.leading, 20)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(sortedInstalledModels) { model in
                    Toggle(isOn: Binding(
                        get: { selectedModelKeys.contains(model.modelKey) },
                        set: { on in
                            if on { selectedModelKeys.insert(model.modelKey) }
                            else { selectedModelKeys.remove(model.modelKey) }
                        }
                    )) {
                        Text(model.displayName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .toggleStyle(.checkbox)
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
                Button("Select all") { selectedLoraKeys = allLoraChoiceKeys }
                    .disabled(allLoras || choices.isEmpty || allLorasSelected)
                Button("Clear all") { selectedLoraKeys = [] }
                    .disabled(allLoras || choices.isEmpty || selectedLoraKeys.isEmpty)
                Button("Select Downloads only") { selectDownloadsOnly() }
                    .disabled(choices.isEmpty || downloadsChoiceKeys.isEmpty)
            }
            .padding(.leading, 20)
            if choices.isEmpty {
                Text("No LoRA weights found on disk.")
                    .padding(.leading, 20)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sortedChoices) { choice in
                            Toggle(isOn: Binding(
                                get: { allLoras || selectedLoraKeys.contains(choice.key) },
                                set: { on in
                                    if on { selectedLoraKeys.insert(choice.key) }
                                    else { selectedLoraKeys.remove(choice.key) }
                                }
                            )) {
                                Text(choice.label)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .toggleStyle(.checkbox)
                            .disabled(allLoras)
                            .help(choice.fromDownloads
                                ? "Top-level ~/Downloads — passing probe copies into the LoRA library"
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

    private var downloadsChoiceKeys: Set<String> {
        Set(choices.filter(\.fromDownloads).map(\.key))
    }

    @ViewBuilder
    private var downloadsLibrarySection: some View {
        if downloadsChoiceKeys.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Downloads and library").font(.headline)
                let count = downloadsChoiceKeys.count
                let suffix = count == 1 ? "" : "s"
                Text(
                    "\(count) top-level Downloads file\(suffix) in this scan. "
                        + "Passing probes copy weights into the LoRA cache; duplicates of "
                        + "files already in the library may be removed from Downloads before probing."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Toggle(
                    "Remove from Downloads after successful copy to library",
                    isOn: $removeDownloadsAfterImport
                )
                .help(
                    "After a passing probe registers an orphan from Downloads, delete the "
                        + "original top-level .safetensors once a copy is saved in the LoRA library."
                )
            }
        }
    }

    private func selectDownloadsOnly() {
        allLoras = false
        selectedLoraKeys = downloadsChoiceKeys
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
            TextField(CheckLorasOptions.defaultProbePrompt, text: $probePrompt)
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

    private struct LocalState {
        var selectedModelKeys: Set<String>
        var selectedLoraKeys: Set<String>
        var allModels: Bool
        var allLoras: Bool
        var registrationMode: String
        var probePrompt: String
        var skipUnchanged: Bool
        var checkCrossFamilies: Bool
        var removeDownloadsAfterImport: Bool
    }

    private static func localState(
        from options: CheckLorasOptions,
        choices: [CheckLorasProbeChoice],
        modelKeys: [String]
    ) -> LocalState {
        let allModels = options.modelScope == CheckLorasOptions.modelScopeAll
        let useSelectedLoraScope = options.loraScope == CheckLorasOptions.loraScopeSelected
            && !options.selectedLoraKeys.isEmpty
        let allLoras = !useSelectedLoraScope
        let selectedModelKeys = Set(
            options.selectedModelKeys.isEmpty && !allModels
                ? []
                : (options.selectedModelKeys.isEmpty ? modelKeys : options.selectedModelKeys)
        )
        let selectedLoraKeys: Set<String> = useSelectedLoraScope
            ? Set(options.selectedLoraKeys)
            : Set(choices.map(\.key))
        if choices.isEmpty {
            return LocalState(
                selectedModelKeys: selectedModelKeys,
                selectedLoraKeys: [],
                allModels: allModels,
                allLoras: true,
                registrationMode: options.registrationMode,
                probePrompt: CheckLorasOptions.normalizedProbePrompt(options.probePrompt),
                skipUnchanged: options.skipUnchanged,
                checkCrossFamilies: options.checkCrossFamilies,
                removeDownloadsAfterImport: options.removeDownloadsAfterImport
            )
        }
        return LocalState(
            selectedModelKeys: selectedModelKeys,
            selectedLoraKeys: selectedLoraKeys,
            allModels: allModels,
            allLoras: allLoras,
            registrationMode: options.registrationMode,
            probePrompt: CheckLorasOptions.normalizedProbePrompt(options.probePrompt),
            skipUnchanged: options.skipUnchanged,
            checkCrossFamilies: options.checkCrossFamilies,
            removeDownloadsAfterImport: options.removeDownloadsAfterImport
        )
    }

    private func loadFromOptions() {
        let local = Self.localState(from: options, choices: choices, modelKeys: modelKeys)
        selectedModelKeys = local.selectedModelKeys
        selectedLoraKeys = local.selectedLoraKeys
        allModels = local.allModels
        allLoras = local.allLoras
        registrationMode = local.registrationMode
        probePrompt = local.probePrompt
        skipUnchanged = local.skipUnchanged
        checkCrossFamilies = local.checkCrossFamilies
        removeDownloadsAfterImport = local.removeDownloadsAfterImport
    }

    private func resolvedLoraKeysForScope() -> [String] {
        if allLoras {
            return choices.map(\.key)
        }
        var keys = selectedLoraKeys
        for choice in choices {
            let path = choice.weightsPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { continue }
            let standardized = (path as NSString).standardizingPath
            if keys.contains(choice.key) {
                continue
            }
            let pathKeys: Set<String> = [
                path,
                standardized,
                "path:\(path)",
                "path:\(standardized)",
            ]
            if !keys.isDisjoint(with: pathKeys) {
                keys.insert(choice.key)
            }
        }
        return keys.sorted()
    }

    private func snapshotOptions() -> CheckLorasOptions {
        let models = allModels ? modelKeys : selectedModelKeys.sorted()
        let loraKeys = resolvedLoraKeysForScope()
        return CheckLorasOptions(
            modelScope: allModels ? CheckLorasOptions.modelScopeAll : CheckLorasOptions.modelScopeSelected,
            selectedModelKeys: models,
            loraScope: allLoras ? CheckLorasOptions.loraScopeAll : CheckLorasOptions.loraScopeSelected,
            selectedLoraKeys: loraKeys,
            registrationMode: registrationMode,
            probePrompt: CheckLorasOptions.normalizedProbePrompt(probePrompt),
            skipUnchanged: skipUnchanged,
            checkCrossFamilies: checkCrossFamilies,
            removeDownloadsAfterImport: removeDownloadsAfterImport
        )
    }

    private func commitAndRun() {
        validationMessage = nil
        if choices.isEmpty {
            validationMessage = "No LoRA weights were found on disk."
            return
        }
        if modelKeys.isEmpty {
            validationMessage = "No installed base models are available to probe against."
            return
        }
        let models = allModels ? modelKeys : selectedModelKeys.sorted()
        if models.isEmpty {
            validationMessage = "Select at least one model, or choose All models."
            return
        }
        let loraKeys = resolvedLoraKeysForScope()
        if loraKeys.isEmpty {
            validationMessage = "Select at least one LoRA, or choose All discovered LoRAs."
            return
        }
        let snapshot = snapshotOptions()
        options = snapshot
        appConfig.persistCheckLorasOptions(snapshot)
        onRun(snapshot)
    }
}
