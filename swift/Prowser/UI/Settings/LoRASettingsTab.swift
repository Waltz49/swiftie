import AppKit
import SwiftUI

@MainActor
struct LoRASettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = LoRASettingsViewModel()
    @State private var showAddSheet = false
    @State private var editTarget: LoRAEditTarget?
    @State private var showAdvanced = false

    var body: some View {
        Group {
            if !appState.workers.lora.isAvailable {
                unavailableBody
            } else {
                mainBody
            }
        }
        .task(id: appState.workers.pythonAvailable) {
            viewModel.bind(bridge: appState.workers.lora, config: appState.config)
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
                Text(lorasForModelTitle)
                    .font(.headline)
                Text("LoRA files are found automatically from your profile and Downloads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Drag a .safetensors file here or use + to add a LoRA file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                toolbar
                listFilterPicker
                if viewModel.isLoading {
                    ProgressView()
                } else {
                    entriesList
                }
                if let error = viewModel.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                advancedSection
            }
            .padding()
        }
    }

    private var lorasForModelTitle: String {
        let name = viewModel.selectedModel?.displayName ?? "this model"
        return "LoRAs for \(name)"
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

    private var listFilterPicker: some View {
        Picker("Filter", selection: $viewModel.listFilter) {
            ForEach(LoRASettingsListFilter.allCases) { filter in
                Text(filter.rawValue).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Toggle("Hide uninstalled", isOn: $viewModel.hideUninstalled)
                .toggleStyle(.checkbox)
            Button("Test LoRAs…") {
                CheckLorasController.present(from: appState)
            }
            Button {
                showAddSheet = true
            } label: {
                Image(systemName: "plus")
            }
            .help("Add LoRA file…")
            Spacer()
        }
    }

    private var advancedSection: some View {
        DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
            HStack(spacing: 8) {
                Button("Save my setup") {
                    Task { await viewModel.saveUserPreset() }
                }
                Button("Apply my setup") {
                    Task { await viewModel.applyUserPreset() }
                }
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    private var entriesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if viewModel.filteredRows.isEmpty {
                    Text("No LoRAs match this filter.")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.filteredRows) { row in
                    settingsRow(row)
                }
            }
        }
    }

    @ViewBuilder
    private func settingsRow(_ row: LoRASettingsRow) -> some View {
        switch row.kind {
        case .needsSetup:
            discoveredEntryRow(row)
        case .saved:
            entryRow(row)
        }
    }

    private func discoveredEntryRow(_ row: LoRASettingsRow) -> some View {
        let entry = row.entry
        return HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: .constant(false))
                .labelsHidden()
                .disabled(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                    .fontWeight(.medium)
                Text(viewModel.compatibilitySubtitle(for: row))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .help(entry.localPath)
            Spacer()
            Button("Set up…") {
                viewModel.pendingImportPath = entry.localPath
                showAddSheet = true
            }
        }
        .padding(6)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.2))
        .cornerRadius(6)
    }

    private func entryRow(_ row: LoRASettingsRow) -> some View {
        let entry = row.entry
        let canEnable = row.compatibility == .works
        return HStack(alignment: .top, spacing: 8) {
            Toggle(
                "",
                isOn: Binding(
                    get: { viewModel.enabledIDs.contains(entry.loraID) },
                    set: { viewModel.toggleEnabled(entry.loraID, enabled: $0) }
                )
            )
            .labelsHidden()
            .disabled(!canEnable)
            .help(canEnable ? "In Create menu" : "Works with this model before enabling")
            VStack(alignment: .leading, spacing: 2) {
                Button(entry.label) { editTarget = LoRAEditTarget(loraID: entry.loraID) }
                    .buttonStyle(.plain)
                    .fontWeight(.medium)
                Text(viewModel.compatibilitySubtitle(for: row))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !entry.installed {
                Button("Install") {
                    Task { await viewModel.install(loraID: entry.loraID) }
                }
            }
            if entry.registered {
                Button(role: .destructive) {
                    Task {
                        await viewModel.removeSavedLoRA(
                            loraID: entry.loraID,
                            parentWindow: preferencesWindow
                        )
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove LoRA…")
            }
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

private extension LoRASettingsTab {
    var preferencesWindow: NSWindow? {
        NSApp.windows.first { $0.title.localizedCaseInsensitiveContains("Preferences") }
    }
}
