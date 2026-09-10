import SwiftUI

extension Notification.Name {
    static let prowserLoraCatalogChanged = Notification.Name("prowser.loraCatalogChanged")
    static let prowserSelectLoraSettingsModel = Notification.Name("prowser.selectLoraSettingsModel")
}

/// LoRA summary combo + checkable popup (Python `LoraStackField` / `LoraSelectionPopup`).
@MainActor
struct ImageGenLoraPicker: View {
    @Environment(AppState.self) private var appState
    let pluginID: String
    @Binding var values: [String: Any]
    var onValuesChanged: (() -> Void)?

    @State private var choicesState = LoRAPluginChoices(
        unsupported: false,
        unsupportedLabel: "",
        stackMode: true,
        popupMode: true,
        choices: [],
        selectedIDs: [],
        scalesByID: [:]
    )
    @State private var draftSelectedIDs: [String] = []
    @State private var draftScales: [String: Double] = [:]
    @State private var showPopover = false
    @State private var infoText = ""
    @State private var isLoading = false

    private let scaleMin = 0.1
    private let scaleMax = 2.0

    private var summaryText: String {
        if choicesState.unsupported {
            return choicesState.unsupportedLabel
        }
        if draftSelectedIDs.isEmpty {
            return "None"
        }
        if choicesState.stackMode && draftSelectedIDs.count > 1 {
            return "Multiple LoRAs"
        }
        let first = draftSelectedIDs[0]
        let label = choicesState.choices.first(where: { $0.presetID == first })?.label ?? first
        if label.count > 48 {
            return String(label.prefix(47)) + "…"
        }
        return label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if choicesState.popupMode && !choicesState.unsupported {
                    draftSelectedIDs = currentSelectedIDs()
                    draftScales = currentScalesByID()
                    showPopover = true
                }
            } label: {
                HStack {
                    Text(summaryText)
                        .lineLimit(1)
                        .foregroundStyle(choicesState.unsupported ? .secondary : .primary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.35))
                )
            }
            .buttonStyle(.plain)
            .disabled(!choicesState.popupMode || choicesState.unsupported || isLoading)
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                popupContent
                    .frame(minWidth: 300, maxWidth: 420)
                    .padding(8)
            }
            .onChange(of: showPopover) { wasOpen, isOpen in
                if wasOpen && !isOpen && choicesState.stackMode {
                    commitSelection()
                }
            }

            if !infoText.isEmpty {
                Text(infoText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .task(id: reloadKey) {
            await reloadChoices()
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserLoraCatalogChanged)) { _ in
            Task { await reloadChoices() }
        }
    }

    private var reloadKey: String {
        "\(pluginID)|\(valuesSignature)"
    }

    private var valuesSignature: String {
        let stack = (values["mflux_lora_stack"] as? [Any])?.map { String(describing: $0) }.joined(separator: ",") ?? ""
        let preset = values["mflux_lora"] as? String ?? ""
        return "\(stack)|\(preset)"
    }

    @ViewBuilder
    private var popupContent: some View {
        if selectableChoices.isEmpty {
            Text("No LoRAs available. Enable and download in Settings → LoRA.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("LoRA").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("Wt").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(popupRows, id: \.presetID) { row in
                            popupRow(row)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
    }

    private struct PopupRow {
        let presetID: String
        let label: String
        let bestGuess: Double
    }

    private var selectableChoices: [LoRAChoice] {
        if choicesState.stackMode {
            return choicesState.choices.filter { $0.presetID != "none" }
        }
        return choicesState.choices
    }

    private var popupRows: [PopupRow] {
        selectableChoices.map { choice in
            PopupRow(
                presetID: choice.presetID,
                label: choice.label,
                bestGuess: fallbackScale(for: choice.presetID)
            )
        }
    }

    @ViewBuilder
    private func popupRow(_ row: PopupRow) -> some View {
        HStack(spacing: 8) {
            if choicesState.stackMode {
                Toggle("", isOn: bindingForSelection(row.presetID))
                    .labelsHidden()
            } else {
                Button {
                    applySingleSelection(row.presetID)
                } label: {
                    Image(systemName: draftSelectedIDs.first == row.presetID ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(row.label)
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.presetID != "none" {
                TextField(
                    "",
                    text: weightBinding(for: row.presetID, bestGuess: row.bestGuess)
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 52)
                .multilineTextAlignment(.trailing)
                .disabled(!draftSelectedIDs.contains(row.presetID))
            } else {
                Color.clear.frame(width: 52, height: 1)
            }
        }
    }

    private func bindingForSelection(_ presetID: String) -> Binding<Bool> {
        Binding(
            get: { draftSelectedIDs.contains(presetID) },
            set: { checked in
                if checked {
                    if !draftSelectedIDs.contains(presetID) {
                        draftSelectedIDs.append(presetID)
                    }
                } else {
                    draftSelectedIDs.removeAll { $0 == presetID }
                }
            }
        )
    }

    private func weightBinding(for presetID: String, bestGuess: Double) -> Binding<String> {
        Binding(
            get: {
                let scale = draftScales[presetID] ?? bestGuess
                return formatScale(scale)
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    draftScales[presetID] = clampScale(bestGuess)
                    return
                }
                if let value = Double(trimmed) {
                    draftScales[presetID] = clampScale(value)
                }
            }
        )
    }

    private func applySingleSelection(_ presetID: String) {
        if presetID == "none" {
            draftSelectedIDs = []
        } else {
            draftSelectedIDs = [presetID]
        }
        commitSelection()
        showPopover = false
    }

    private func commitSelection() {
        var selected = draftSelectedIDs.filter { $0 != "none" }
        if choicesState.stackMode {
            values["mflux_lora_stack"] = selected
            values.removeValue(forKey: "mflux_lora")
        } else {
            values["mflux_lora"] = selected.first ?? "none"
            values.removeValue(forKey: "mflux_lora_stack")
        }
        var scalesByID = values["mflux_lora_scales_by_id"] as? [String: Any] ?? [:]
        for pid in selected {
            scalesByID[pid] = draftScales[pid] ?? fallbackScale(for: pid)
        }
        values["mflux_lora_scales_by_id"] = scalesByID
        onValuesChanged?()
        Task {
            try? await appState.workers.lora.updateEntryScales(
                selected.reduce(into: [String: Double]()) { out, pid in
                    if let scale = scalesByID[pid] as? Double {
                        out[pid] = scale
                    } else if let scale = scalesByID[pid] as? Int {
                        out[pid] = Double(scale)
                    }
                }
            )
            await refreshInfoText()
        }
    }

    private func currentSelectedIDs() -> [String] {
        if let stack = values["mflux_lora_stack"] as? [Any], !stack.isEmpty {
            return stack.compactMap { item in
                let text = String(describing: item)
                return text.isEmpty || text == "none" ? nil : text
            }
        }
        let preset = values["mflux_lora"] as? String ?? "none"
        return preset == "none" || preset.isEmpty ? [] : [preset]
    }

    private func currentScalesByID() -> [String: Double] {
        let raw = values["mflux_lora_scales_by_id"] as? [String: Any] ?? [:]
        var out: [String: Double] = [:]
        for (key, value) in raw {
            if let d = value as? Double {
                out[key] = d
            } else if let i = value as? Int {
                out[key] = Double(i)
            }
        }
        for pid in currentSelectedIDs() where out[pid] == nil {
            out[pid] = fallbackScale(for: pid)
        }
        return out
    }

    private func fallbackScale(for presetID: String) -> Double {
        if let scale = choicesState.scalesByID[presetID] {
            return scale
        }
        return 1.0
    }

    private func clampScale(_ value: Double) -> Double {
        min(scaleMax, max(scaleMin, value))
    }

    private func formatScale(_ value: Double) -> String {
        let text = String(format: "%g", value)
        return text
    }

    private func reloadChoices() async {
        guard appState.workers.lora.isAvailable, !pluginID.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await appState.workers.lora.choicesForPlugin(
                pluginID: pluginID,
                currentStack: currentSelectedIDs(),
                currentPresetID: values["mflux_lora"] as? String ?? "none",
                scaleOverrides: currentScalesByID()
            )
            choicesState = loaded
            draftSelectedIDs = loaded.selectedIDs
            draftScales = loaded.scalesByID
            await refreshInfoText()
        } catch {
            appState.status.show("Could not load LoRA choices.")
        }
    }

    private func refreshInfoText() async {
        let ids = currentSelectedIDs()
        guard !ids.isEmpty else {
            infoText = ""
            return
        }
        do {
            infoText = try await appState.workers.lora.selectedDisplayText(
                pluginID: pluginID,
                selectedIDs: ids,
                scalesByID: currentScalesByID()
            )
        } catch {
            infoText = ""
        }
    }
}
