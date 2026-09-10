import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct LoRASettingsTab: View {
    @Environment(AppState.self) private var appState

    @State private var models: [LoRASettingsModel] = []
    @State private var selectedModelKey = ""
    @State private var entries: [LoRACatalogEntry] = []
    @State private var enabledIDs: Set<String> = []
    @State private var draftByModel: [String: [String: Any]] = [:]
    @State private var hideUninstalled = false
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var showImportSheet = false
    @State private var editLoraID = ""
    @State private var showEditSheet = false
    @State private var droppedImportPath: String?

    private var selectedModel: LoRASettingsModel? {
        models.first { $0.modelKey == selectedModelKey }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("LoRA").font(.title2)

                if !appState.workers.lora.isAvailable {
                    Text("LoRA management requires the Python image generation environment.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsSection(title: "Base model") {
                    if models.isEmpty {
                        ProgressView("Loading models…")
                    } else {
                        Picker("Model", selection: $selectedModelKey) {
                            ForEach(models) { model in
                                Text(model.displayName).tag(model.modelKey)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedModelKey) { oldValue, newValue in
                            guard oldValue != newValue else { return }
                            saveDraftForModel(oldValue)
                            Task { await loadEntries() }
                        }
                        if let model = selectedModel, !model.availableInLabel.isEmpty {
                            Text(model.availableInLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text("💡 Drag a .safetensors file onto this pane to add a LoRA, or press the + button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("LoRA library for this base model:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isLoading {
                    ProgressView()
                } else if entries.isEmpty {
                    Text(
                        "No LoRAs passed Check LoRAs for this base model yet. "
                            + "Run Tools → Debug → Check LoRAs, or pick another model above."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            loraRow(entry)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        hideUninstalled.toggle()
                        Task { await loadEntries() }
                    } label: {
                        Image(systemName: hideUninstalled ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .help(hideUninstalled ? "Show uninstalled LoRAs" : "Hide uninstalled LoRAs")

                    Button {
                        droppedImportPath = nil
                        showImportSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add downloaded LoRA (.safetensors)…")

                    Button("Save my setup") {
                        Task { await saveUserPreset() }
                    }
                    Button("Apply my setup") {
                        Task { await applyUserPreset() }
                    }
                    Button("Restore app recommendations") {
                        Task { await restoreRecommendations() }
                    }
                }

                SettingsSection(title: "Catalog file") {
                    SettingsPathRow(
                        title: "LoRA catalog",
                        path: appState.config.dataDirectory.appendingPathComponent("lora_catalog.json").path
                    )
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .task { await bootstrap() }
        .onDisappear {
            Task { await persistDrafts() }
        }
        .sheet(isPresented: $showImportSheet) {
            LoRAImportSheet(
                mode: .add,
                modelKey: selectedModelKey,
                initialSourcePath: droppedImportPath
            )
        }
        .sheet(isPresented: $showEditSheet) {
            if !editLoraID.isEmpty {
                LoRAImportSheet(
                    mode: .edit(loraID: editLoraID),
                    modelKey: selectedModelKey
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserLoraCatalogChanged)) { _ in
            Task { await loadEntries() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserOpenSettingsTab)) { notification in
            guard let raw = notification.userInfo?["tab"] as? String, raw == SettingsTab.lora.rawValue else { return }
            if let modelKey = notification.userInfo?["lora_model_key"] as? String,
               models.contains(where: { $0.modelKey == modelKey }) {
                saveDraftForModel(selectedModelKey)
                selectedModelKey = modelKey
                Task { await loadEntries() }
            }
        }
    }

    @ViewBuilder
    private func loraRow(_ entry: LoRACatalogEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    editLoraID = entry.loraID
                    showEditSheet = true
                } label: {
                    Text(entry.label)
                        .font(entry.installed ? .body.weight(.semibold) : .body)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .help("Click to edit LoRA details.")
                if !entry.comment.isEmpty {
                    Text(entry.comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(entry.statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if entry.lifecycle == "uninstalled" && entry.hasRecoverySource {
                Button("Install") {
                    Task { await installEntry(entry) }
                }
            }

            Button {
                editLoraID = entry.loraID
                showEditSheet = true
            } label: {
                Image(systemName: "pencil")
            }
            .help("Edit LoRA details…")

            Toggle("", isOn: bindingEnabled(entry.loraID))
                .labelsHidden()
                .disabled(entry.lifecycle == "uninstalled")

            Button(role: .destructive) {
                Task { await deleteEntry(entry) }
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete or remove LoRA")
        }
        .padding(.vertical, 4)
    }

    private func bindingEnabled(_ loraID: String) -> Binding<Bool> {
        Binding(
            get: { enabledIDs.contains(loraID) },
            set: { enabled in
                if enabled {
                    enabledIDs.insert(loraID)
                } else {
                    enabledIDs.remove(loraID)
                }
                saveDraftForModel(selectedModelKey)
            }
        )
    }

    private func bootstrap() async {
        guard appState.workers.lora.isAvailable else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            models = try await appState.workers.lora.settingsModels()
            let savedKey = appState.config.string(forKey: "imagegen_lora_model_key", default: "")
            if !savedKey.isEmpty, models.contains(where: { $0.modelKey == savedKey }) {
                selectedModelKey = savedKey
            } else if let first = models.first {
                selectedModelKey = first.modelKey
            }
            await loadEntries()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadEntries() async {
        guard !selectedModelKey.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await appState.workers.lora.settingsEntries(
                modelKey: selectedModelKey,
                hideUninstalled: hideUninstalled,
                draftByModel: draftByModel
            )
            entries = result.entries
            enabledIDs = Set(result.enabledIDs)
            draftByModel[selectedModelKey] = [
                "enabled_ids": result.enabledIDs,
                "deleted_ids": result.deletedIDs,
            ]
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveDraftForModel(_ modelKey: String) {
        guard !modelKey.isEmpty else { return }
        draftByModel[modelKey] = [
            "enabled_ids": Array(enabledIDs).sorted(),
            "deleted_ids": draftByModel[modelKey]?["deleted_ids"] as? [String] ?? [],
        ]
    }

    private func persistDrafts() async {
        guard !draftByModel.isEmpty else { return }
        saveDraftForModel(selectedModelKey)
        do {
            try await appState.workers.lora.saveCatalogState(
                modelKey: selectedModelKey,
                byModel: draftByModel
            )
            appState.config.updateSetting("imagegen_lora_model_key", value: selectedModelKey)
            NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installEntry(_ entry: LoRACatalogEntry) async {
        do {
            try await appState.workers.lora.install(loraID: entry.loraID)
            await loadEntries()
            NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteEntry(_ entry: LoRACatalogEntry) async {
        let onDisk = entry.lifecycle == "active" || entry.lifecycle == "installed"
        let doUninstall = onDisk && entry.hasRecoverySource
        let title = doUninstall ? "Remove from disk" : "Delete LoRA"
        let message = doUninstall
            ? "Remove downloaded weights for «\(entry.displayName)» from disk?\n\nThe LoRA stays in your library."
            : "Delete «\(entry.displayName)» permanently from disk and remove it from your library?"
        let confirmed = await confirmAlert(title: title, message: message)
        guard confirmed else { return }
        do {
            try await appState.workers.lora.delete(
                loraID: entry.loraID,
                modelKey: selectedModelKey,
                doUninstall: doUninstall
            )
            await loadEntries()
            NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveUserPreset() async {
        await persistDrafts()
        do {
            try await appState.workers.lora.saveUserPreset()
            appState.status.show("Your LoRA setup was saved.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyUserPreset() async {
        let confirmed = await confirmAlert(
            title: "Apply LoRA setup",
            message: "Restore your saved enabled LoRAs for each base model?\n\nMissing weights are not downloaded automatically."
        )
        guard confirmed else { return }
        await persistDrafts()
        do {
            let count = try await appState.workers.lora.applyUserPreset()
            draftByModel = [:]
            await loadEntries()
            NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
            appState.status.show("Restored \(count) enabled LoRA(s) from your saved setup.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restoreRecommendations() async {
        let confirmed = await confirmAlert(
            title: "Restore app recommendations",
            message: "Restore the app's recommended LoRAs?\n\nWeights are not downloaded automatically."
        )
        guard confirmed else { return }
        await persistDrafts()
        do {
            let count = try await appState.workers.lora.restoreRecommendations()
            draftByModel = [:]
            await loadEntries()
            NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
            appState.status.show("Restored \(count) recommended LoRA(s) to your library.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.pathExtension.lowercased() == "safetensors" else { return }
            Task { @MainActor in
                droppedImportPath = url.path
                showImportSheet = true
            }
        }
        return true
    }

    private func confirmAlert(title: String, message: String) async -> Bool {
        await MainActor.run {
            StyledMessageDialog.showOkCancel(title: title, message: message, defaultCancel: false)
        }
    }
}
