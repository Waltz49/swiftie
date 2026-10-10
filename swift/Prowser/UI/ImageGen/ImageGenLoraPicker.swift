import SwiftUI

extension Notification.Name {
    static let prowserLoraCatalogChanged = Notification.Name("prowser.loraCatalogChanged")
    static let prowserSelectLoraSettingsModel = Notification.Name("prowser.selectLoraSettingsModel")
}

@MainActor
struct ImageGenLoraPicker: View {
    private static let scaleMin = 0.0
    private static let scaleMax = 2.0
    private static let weightColumnWidth: CGFloat = 68

    @Environment(AppState.self) private var appState
    let pluginID: String
    @Binding var values: [String: Any]
    @Binding var selectionDetailLine: String
    var onValuesChanged: (() -> Void)?

    @State private var choices = LoRAPluginChoices.unsupported()
    @State private var showLoraPopup = false
    @State private var loraPopupCommitted = true
    @State private var draftSelected: Set<String> = []
    @State private var draftSingleID = "none"
    @State private var draftScales: [String: Double] = [:]
    @State private var summaryText = "None"

    var body: some View {
        Group {
            if choices.unsupported {
                Text(choices.unsupportedLabel)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if choices.popupMode {
                popupSummaryPicker
            } else {
                singlePicker
            }
        }
        .task(id: pluginID) {
            choices = LoRAPluginChoices(
                unsupported: false,
                unsupportedLabel: "",
                stackMode: true,
                popupMode: false,
                choices: [],
                selectedIDs: [],
                scalesByID: [:],
                catalogScalesByID: [:],
                bestGuessByID: [:],
                emptySelectionHint: nil
            )
            summaryText = "None"
            draftSelected = []
            draftSingleID = "none"
            draftScales = [:]
            await refresh()
        }
        .task(id: loraValuesFingerprint) { await refreshSummaryOnly() }
        .onReceive(NotificationCenter.default.publisher(for: .prowserLoraCatalogChanged)) { _ in
            Task { await refresh() }
        }
    }

    private var popupSummaryPicker: some View {
        ImageGenSummaryComboButton(title: summaryText) {
            syncDraftFromCurrentValues()
            loraPopupCommitted = true
            showLoraPopup = true
        }
        .popover(isPresented: $showLoraPopup, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            loraSelectionPopup
                .onExitCommand {
                    loraPopupCommitted = false
                    showLoraPopup = false
                }
        }
        .onChange(of: showLoraPopup) { wasOpen, isOpen in
            if wasOpen, !isOpen, loraPopupCommitted {
                commitPopupSelection()
            }
        }
    }

    private var loraSelectionPopup: some View {
        VStack(alignment: .leading, spacing: 0) {
            if popupChoices.isEmpty {
                loraEmptySelectionView
                    .padding(8)
            } else {
                popupHeaderRow
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(popupChoices) { choice in
                            loraPopupRow(choice: choice)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: popupMaxHeight)
            }
        }
        .frame(minWidth: 280)
    }

    private var popupHeaderRow: some View {
        HStack(spacing: 8) {
            Text("LoRA")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Wt")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: Self.weightColumnWidth, alignment: .trailing)
            Color.clear
                .frame(width: ImageGenChrome.fieldButtonSize, height: 1)
        }
    }

    @ViewBuilder
    private func loraPopupRow(choice: LoRAChoice) -> some View {
        let presetID = choice.presetID
        let isActive = rowIsSelected(presetID)
        HStack(spacing: 8) {
            if choices.stackMode {
                Toggle("", isOn: Binding(
                    get: { draftSelected.contains(presetID) },
                    set: { on in
                        if on { draftSelected.insert(presetID) }
                        else { draftSelected.remove(presetID) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
            } else {
                Button {
                    draftSingleID = presetID
                } label: {
                    Image(systemName: draftSingleID == presetID ? "largecircle.fill.circle" : "circle")
                        .imageScale(.small)
                        .foregroundStyle(draftSingleID == presetID ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(draftSingleID == presetID ? .isSelected : [])
            }
            Text(choice.label)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField("", text: scaleBinding(for: presetID))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: Self.weightColumnWidth)
                .disabled(!isActive || presetID == "none")
            ImageGenFieldResetButton(
                isActive: isWeightResetActive(presetID: presetID, isActive: isActive),
                tooltip: "Reset weight to catalog best guess",
                action: { resetWeight(for: presetID) }
            )
            .allowsHitTesting(isActive && presetID != "none")
        }
    }

    private var popupChoices: [LoRAChoice] {
        if choices.stackMode {
            return choices.selectableChoices
        }
        var list = choices.choices
        if !list.contains(where: { $0.presetID == "none" }) {
            list.insert(LoRAChoice(presetID: "none", label: "None"), at: 0)
        }
        return list
    }

    private var popupMaxHeight: CGFloat {
        let rowHeight: CGFloat = 28
        let headerHeight: CGFloat = 22
        let padding: CGFloat = 16
        let visibleRows = min(popupChoices.count, 10)
        return headerHeight + CGFloat(visibleRows) * rowHeight + padding
    }

    private func rowIsSelected(_ presetID: String) -> Bool {
        if choices.stackMode {
            return draftSelected.contains(presetID)
        }
        return draftSingleID == presetID
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
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
                .onChange(of: singleBinding.wrappedValue) { _, _ in
                    onValuesChanged?()
                    Task { await refreshSummaryOnly() }
                }
            }
        }
    }

    private var loraEmptySelectionView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !choices.popupMode {
                Toggle("None", isOn: .constant(true))
                    .disabled(true)
            }
            Text(
                choices.emptySelectionHint
                    ?? "No LoRAs available. Enable and download in Settings → LoRA."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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

    private func scaleBinding(for presetID: String) -> Binding<String> {
        Binding(
            get: {
                let v = draftScales[presetID] ?? catalogScale(for: presetID)
                return formatEditableScale(v)
            },
            set: { text in
                if let d = Double(text) {
                    draftScales[presetID] = min(Self.scaleMax, max(Self.scaleMin, d))
                }
            }
        )
    }

    private func formatEditableScale(_ value: Double) -> String {
        let clamped = min(Self.scaleMax, max(Self.scaleMin, value))
        var text = String(format: "%.2f", clamped)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text
    }

    private func catalogScale(for presetID: String) -> Double {
        choices.catalogScalesByID[presetID] ?? choices.scalesByID[presetID] ?? 1
    }

    private func bestGuessScale(for presetID: String) -> Double {
        choices.bestGuessByID[presetID] ?? catalogScale(for: presetID)
    }

    private func isWeightResetActive(presetID: String, isActive: Bool) -> Bool {
        guard isActive, presetID != "none" else { return false }
        let current = draftScales[presetID] ?? catalogScale(for: presetID)
        let target = bestGuessScale(for: presetID)
        return abs(current - target) > 1e-6
    }

    private func resetWeight(for presetID: String) {
        draftScales[presetID] = bestGuessScale(for: presetID)
    }

    private func commitPopupSelection() {
        if choices.stackMode {
            let ids = choices.selectableChoices.map(\.presetID).filter { draftSelected.contains($0) }
            applyCommittedSelection(ids: ids)
        } else {
            if draftSingleID.isEmpty || draftSingleID == "none" {
                applyCommittedSelection(ids: [])
            } else {
                applyCommittedSelection(ids: [draftSingleID])
            }
        }
    }

    private func applyCommittedSelection(ids: [String]) {
        var scales: [String: Any] = [:]
        var scalesForCatalog: [String: Double] = [:]
        for id in ids {
            let scale = draftScales[id] ?? catalogScale(for: id)
            scales[id] = scale
            scalesForCatalog[id] = scale
        }
        var next = values
        next.removeValue(forKey: "mflux_lora")
        if choices.stackMode {
            next["mflux_lora_stack"] = ids
            next["mflux_lora_scales_by_id"] = scales
        } else if let single = ids.first {
            next["mflux_lora"] = single
            next.removeValue(forKey: "mflux_lora_stack")
            if !scales.isEmpty {
                next["mflux_lora_scales_by_id"] = scales
            }
        } else {
            next["mflux_lora_stack"] = []
            next.removeValue(forKey: "mflux_lora_scales_by_id")
        }
        values = next
        onValuesChanged?()
        let plugin = pluginID
        Task {
            if appState.workers.lora.isAvailable, !scalesForCatalog.isEmpty {
                try? await appState.workers.lora.updateEntryScales(
                    pluginID: plugin,
                    scalesByID: scalesForCatalog
                )
            }
            await refreshSummaryOnly()
        }
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
        if choices.stackMode {
            draftSelected = Set(currentStackIDs())
        } else {
            draftSingleID = currentStackIDs().first ?? "none"
        }
        draftScales = mergedScalesByID()
        for choice in popupChoices where choice.presetID != "none" {
            if draftScales[choice.presetID] == nil {
                draftScales[choice.presetID] = mergedScalesByID()[choice.presetID]
                    ?? catalogScale(for: choice.presetID)
            }
        }
    }

    private func currentStackIDs() -> [String] {
        if values.keys.contains("mflux_lora_stack") {
            return mfluxLoraStackIDs(from: values["mflux_lora_stack"])
        }
        if let single = values["mflux_lora"] as? String, single != "none", !single.isEmpty {
            return [single]
        }
        return []
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

        guard !choices.unsupported, choices.popupMode else { return }
        if ids.isEmpty {
            summaryText = "None"
            return
        }
        if ids.count == 1, let label = labelForPresetID(ids[0]) {
            summaryText = truncatedSummary(label)
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

    private func labelForPresetID(_ presetID: String) -> String? {
        choices.selectableChoices.first(where: { $0.presetID == presetID })?.label
            ?? choices.choices.first(where: { $0.presetID == presetID })?.label
    }

    private func truncatedSummary(_ label: String, maxChars: Int = 48) -> String {
        if label.count <= maxChars { return label }
        return String(label.prefix(maxChars - 1)) + "…"
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
            let label = labelForPresetID(id) ?? id
            let scale = scales[id] ?? 1
            return "\(label) [\(formatLoraScale(scale))]"
        }.joined(separator: ", ")
    }

    private func mfluxLoraStackIDs(from raw: Any?) -> [String] {
        if let stack = raw as? [String] {
            return stack.filter { !$0.isEmpty && $0 != "none" }
        }
        if let stack = raw as? [Any] {
            return stack.compactMap { $0 as? String }.filter { !$0.isEmpty && $0 != "none" }
        }
        return []
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
