import SwiftUI

@MainActor
struct LoRASettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = LoRASettingsViewModel()
    @State private var showAddSheet = false
    @State private var editTarget: LoRAEditTarget?

    var body: some View {
        Group {
            if !appState.workers.lora.isAvailable {
                unavailableBody
            } else {
                mainBody
            }
        }
        .task(id: appState.workers.pythonAvailable) {
            viewModel.bind(bridge: appState.workers.lora)
            guard appState.workers.lora.isAvailable else { return }
            await viewModel.loadInitial()
            if let key = appState.pendingLoraSettingsModelKey, !key.isEmpty {
                await viewModel.selectModelKey(key)
                appState.pendingLoraSettingsModelKey = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserSelectLoraSettingsModel)) { note in
            if let key = note.userInfo?["lora_model_key"] as? String {
                Task { await viewModel.selectModelKey(key) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserSettingsWillCommit)) { _ in
            Task {
                try? await viewModel.commitToDisk()
            }
        }
        .onChange(of: viewModel.hideUninstalled) { _, _ in
            Task { await viewModel.reloadEntries() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserLoraCatalogChanged)) { _ in
            Task { await viewModel.reloadEntries() }
        }
        .sheet(isPresented: $showAddSheet) {
            LoRAImportSheet(
                mode: .add,
                modelKey: viewModel.selectedModelKey,
                initialSourcePath: viewModel.pendingImportPath ?? ""
            )
            .onDisappear {
                viewModel.pendingImportPath = nil
                Task { await viewModel.reloadEntries() }
            }
        }
        .sheet(item: $editTarget) { target in
            LoRAImportSheet(mode: .edit(loraID: target.loraID), modelKey: viewModel.selectedModelKey)
                .onDisappear { Task { await viewModel.reloadEntries() } }
        }
    }

    private var unavailableBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LoRA").font(.title2)
            Text("Configure the image-generation Python environment in Settings → Image Generation.")
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private var mainBody: some View {
        LoRASafetensorsDropZone { path in
            viewModel.pendingImportPath = path
            showAddSheet = true
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Text("LoRA").font(.title2)
                modelPicker
                if let note = viewModel.selectedModel?.availableInLabel, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Text("Drag a .safetensors file here or use + to add LoRAs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("LoRA library for this base model:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                toolbar
                if viewModel.isLoading {
                    ProgressView()
                } else {
                    entriesList
                }
                if let error = viewModel.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .padding()
        }
    }

    private var modelPicker: some View {
        Picker("Model", selection: Binding(
            get: { viewModel.selectedModelKey },
            set: { newKey in Task { await viewModel.modelChanged(to: newKey) } }
        )) {
            if viewModel.models.isEmpty {
                Text("No models loaded").tag("")
            }
            ForEach(viewModel.models) { model in
                Text(model.displayName).tag(model.modelKey)
            }
        }
        .pickerStyle(.menu)
        .disabled(viewModel.models.isEmpty)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Toggle("Hide uninstalled", isOn: $viewModel.hideUninstalled)
                .toggleStyle(.checkbox)
            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .help("Add LoRA")
            Button("Save my setup") {
                Task { await viewModel.saveUserPreset() }
            }
            Button("Apply my setup") {
                Task { await viewModel.applyUserPreset() }
            }
            Spacer()
        }
    }

    private var entriesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if viewModel.entries.isEmpty {
                    Text("No LoRAs for this model yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.entries) { entry in
                    entryRow(entry)
                }
            }
        }
    }

    private func entryRow(_ entry: LoRACatalogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { viewModel.enabledIDs.contains(entry.loraID) },
                    set: { viewModel.toggleEnabled(entry.loraID, enabled: $0) }
                )
            )
            .labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                Button(entry.label) { editTarget = LoRAEditTarget(loraID: entry.loraID) }
                    .buttonStyle(.plain)
                    .fontWeight(.medium)
                Text(entry.statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !entry.installed {
                Button("Install") {
                    Task { await viewModel.install(loraID: entry.loraID) }
                }
            }
            Button(role: .destructive) {
                Task { await viewModel.delete(loraID: entry.loraID) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        .cornerRadius(6)
    }
}

struct LoRAEditTarget: Identifiable {
    let loraID: String
    var id: String { loraID }
}
