import SwiftUI

extension Notification.Name {
    static let prowserLoraCatalogChanged = Notification.Name("prowser.loraCatalogChanged")
    static let prowserSelectLoraSettingsModel = Notification.Name("prowser.selectLoraSettingsModel")
}

@MainActor
struct ImageGenLoraPicker: View {
    @Environment(AppState.self) private var appState
    let pluginID: String
    @Binding var values: [String: Any]
    @Binding var selectionDetailLine: String
    var onValuesChanged: (() -> Void)?

    @State private var choices = LoRAPluginChoices.unsupported()
    @State private var showStackSheet = false
    @State private var draftSelected: Set<String> = []
    @State private var draftScales: [String: Double] = [:]
    @State private var summaryText = "None"

    var body: some View {
        Group {
            if choices.unsupported {
                Text(choices.unsupportedLabel)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if choices.stackMode {
                stackPicker
            } else {
                singlePicker
            }
        }
        .task(id: pluginID) { await refresh() }
        .task(id: loraValuesFingerprint) { await refreshSummaryOnly() }
        .onReceive(NotificationCenter.default.publisher(for: .prowserLoraCatalogChanged)) { _ in
            Task { await refresh() }
        }
        .sheet(isPresented: $showStackSheet) {
            loraStackSheet
        }
    }

    private var stackPicker: some View {
        Button(summaryText) {
            syncDraftFromCurrentValues()
            showStackSheet = true
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var singlePicker: some View {
        Group {
            if choices.selectableChoices.isEmpty {
                loraEmptySelectionView
            } else {
                Picker("LoRA", selection: singleBinding) {
                    Text("—").tag("")
                    ForEach(choices.selectableChoices) { choice in
                        Text(choice.label).tag(choice.presetID)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: singleBinding.wrappedValue) { _, _ in
                    onValuesChanged?()
                    Task { await refreshSummaryOnly() }
                }
            }
        }
    }

    private var loraEmptySelectionView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("None", isOn: .constant(true))
                .disabled(true)
            if let hint = choices.emptySelectionHint, !hint.isEmpty {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if appState.workers.lora.isAvailable {
                Button("Open LoRA settings…") {
                    openLoRASettings()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openLoRASettings() {
        var userInfo: [String: Any] = [:]
        if let hfModelID = ImageGenPluginCatalog.plugin(pluginID: pluginID)?.hfModelID,
           !hfModelID.isEmpty {
            userInfo["lora_model_key"] = hfModelID
        }
        appState.openSettingsWindow(tab: .lora, userInfo: userInfo)
    }

    private var singleBinding: Binding<String> {
        Binding(
            get: {
                let stored = values["mflux_lora"] as? String ?? ""
                if !stored.isEmpty, stored != "none",
                   choices.selectableChoices.contains(where: { $0.presetID == stored }) {
                    return stored
                }
                if let id = choices.selectedIDs.first,
                   id != "none",
                   choices.selectableChoices.contains(where: { $0.presetID == id }) {
                    return id
                }
                return ""
            },
            set: { newValue in
                if newValue.isEmpty || newValue == "none" {
                    values.removeValue(forKey: "mflux_lora")
                    values["mflux_lora_stack"] = []
                } else {
                    values["mflux_lora"] = newValue
                    values.removeValue(forKey: "mflux_lora_stack")
                }
            }
        )
    }

    private var loraStackSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LoRAs").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if choices.selectableChoices.isEmpty {
                        loraEmptySelectionView
                    } else {
                        ForEach(choices.selectableChoices) { choice in
                            HStack {
                                Toggle(choice.label, isOn: Binding(
                                    get: { draftSelected.contains(choice.presetID) },
                                    set: { on in
                                        if on { draftSelected.insert(choice.presetID) }
                                        else { draftSelected.remove(choice.presetID) }
                                    }
                                ))
                                TextField(
                                    "wt",
                                    text: scaleBinding(for: choice.presetID)
                                )
                                .frame(width: 48)
                                .disabled(!draftSelected.contains(choice.presetID))
                            }
                        }
                    }
                }
            }
            DialogButtonRow([
                DialogButton("Cancel", isCancel: true) { showStackSheet = false },
                DialogButton("Apply", isDefault: true) { applyStack() },
            ])
        }
        .padding()
        .frame(width: 420, height: 360)
    }

    private func scaleBinding(for presetID: String) -> Binding<String> {
        Binding(
            get: {
                let v = draftScales[presetID] ?? 1
                return String(v)
            },
            set: { text in
                if let d = Double(text) {
                    draftScales[presetID] = min(2, max(0.1, d))
                }
            }
        )
    }

    private func applyStack() {
        let ids = choices.selectableChoices.map(\.presetID).filter { draftSelected.contains($0) }
        values.removeValue(forKey: "mflux_lora")
        values["mflux_lora_stack"] = ids
        var scales: [String: Any] = [:]
        for id in ids {
            scales[id] = draftScales[id] ?? 1
        }
        values["mflux_lora_scales_by_id"] = scales
        showStackSheet = false
        Task {
            if appState.workers.lora.isAvailable {
                try? await appState.workers.lora.updateEntryScales(
                    pluginID: pluginID,
                    scalesByID: draftScales
                )
            }
            await refreshSummaryOnly()
        }
        onValuesChanged?()
    }

    private var loraValuesFingerprint: String {
        let ids = currentStackIDs().joined(separator: "|")
        let scalePairs = mergedScalesByID()
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: "|")
        return "\(pluginID);\(ids);\(scalePairs)"
    }

    private func refresh() async {
        guard appState.workers.lora.isAvailable else {
            choices = LoRAPluginChoices.unsupported(label: "LoRA unavailable")
            selectionDetailLine = ""
            return
        }
        do {
            choices = try await appState.workers.lora.choicesForPlugin(pluginID: pluginID, values: values)
            await refreshSummaryOnly()
        } catch {
            choices = LoRAPluginChoices.unsupported(label: error.localizedDescription)
        }
    }

    private func syncDraftFromCurrentValues() {
        draftSelected = Set(currentStackIDs())
        draftScales = mergedScalesByID()
    }

    private func currentStackIDs() -> [String] {
        if values.keys.contains("mflux_lora_stack") {
            if let stack = values["mflux_lora_stack"] as? [String] {
                return stack.filter { !$0.isEmpty && $0 != "none" }
            }
            if let stack = values["mflux_lora_stack"] as? [Any] {
                return stack.compactMap { $0 as? String }.filter { !$0.isEmpty && $0 != "none" }
            }
            return []
        }
        if let single = values["mflux_lora"] as? String, single != "none", !single.isEmpty {
            return [single]
        }
        return choices.selectedIDs
    }

    private func mergedScalesByID() -> [String: Double] {
        var scales = choices.scalesByID
        if let raw = values["mflux_lora_scales_by_id"] as? [String: Any] {
            for (k, v) in raw {
                if let n = v as? NSNumber { scales[k] = n.doubleValue }
                else if let d = v as? Double { scales[k] = d }
            }
        }
        return scales
    }

    private func refreshSummaryOnly() async {
        let ids = currentStackIDs()
        let scales = mergedScalesByID()
        rebuildSelectionDetailLine(ids: ids, scales: scales)

        guard !choices.unsupported, choices.stackMode else { return }
        if ids.isEmpty {
            summaryText = "None"
            return
        }
        if ids.count == 1, let label = choices.selectableChoices.first(where: { $0.presetID == ids[0] })?.label {
            summaryText = label
            return
        }
        if ids.count > 1 {
            summaryText = "Multiple LoRAs"
            return
        }
        if appState.workers.lora.isAvailable {
            summaryText = (try? await appState.workers.lora.selectedDisplayText(
                pluginID: pluginID,
                selectedIDs: ids,
                scalesByID: scales
            )) ?? "Multiple LoRAs"
        }
    }

    private func rebuildSelectionDetailLine(ids: [String], scales: [String: Double]) {
        guard !choices.unsupported else {
            selectionDetailLine = ""
            return
        }
        if ids.isEmpty {
            selectionDetailLine = ""
            return
        }
        selectionDetailLine = ids.map { id in
            let label = choices.selectableChoices.first(where: { $0.presetID == id })?.label
                ?? choices.choices.first(where: { $0.presetID == id })?.label
                ?? id
            let scale = scales[id] ?? 1
            return "\(label) [\(formatLoraScale(scale))]"
        }.joined(separator: ", ")
    }

    private func formatLoraScale(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if abs(rounded - rounded.rounded()) < 0.001 {
            return String(format: "%.0f", rounded)
        }
        var text = String(format: "%.2f", rounded)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }
}
