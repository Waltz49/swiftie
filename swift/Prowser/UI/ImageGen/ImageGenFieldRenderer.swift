import SwiftUI

@MainActor
struct ImageGenFieldRenderer: View {
    let layout: [[String: Any]]
    var compactSliderTracks: Bool = false
    /// When set (unified dialog / panel mode), copies slider max is 51 (continuous).
    var copiesSliderMax: Int? = nil
    @Binding var values: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(layout.indices, id: \.self) { index in
                ImageGenFieldNodeView(
                    node: layout[index],
                    compactSliderTracks: compactSliderTracks,
                    copiesSliderMax: copiesSliderMax,
                    values: $values
                )
            }
        }
    }
}

@MainActor
private struct ImageGenFieldNodeView: View {
    let node: [String: Any]
    var compactSliderTracks: Bool = false
    var copiesSliderMax: Int? = nil
    @Binding var values: [String: Any]

    var body: some View {
        let type = node["type"] as? String ?? "field"
        if type == "group" {
            let layout = node["layout"] as? String ?? ""
            if layout == "seed_row" {
                ImageGenSeedRowGroup(
                    node: node,
                    inlineLabel: compactSliderTracks,
                    values: $values
                )
            } else if layout == "steps_quant_row" {
                ImageGenStepsQuantRowGroup(
                    node: node,
                    compactSliderTracks: compactSliderTracks,
                    copiesSliderMax: copiesSliderMax,
                    values: $values
                )
            } else if layout == "prompt_block" {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let label = node["label"] as? String, !label.isEmpty {
                        Text(label)
                            .font(ImageGenInlineFieldLayout.stackedFieldLabelFont)
                            .foregroundStyle(.primary)
                            .padding(.top, 4)
                    }
                    if let children = node["children"] as? [[String: Any]] {
                        ForEach(children.indices, id: \.self) { idx in
                            ImageGenFieldNodeView(
                                node: children[idx],
                                compactSliderTracks: compactSliderTracks,
                                copiesSliderMax: copiesSliderMax,
                                values: $values
                            )
                        }
                    }
                }
            }
        } else if let spec = node["spec"] as? [String: Any] {
            ImageGenFieldSpecView(
                spec: spec,
                compactSliderTracks: compactSliderTracks,
                copiesSliderMax: copiesSliderMax,
                values: $values
            )
        }
    }
}

@MainActor
private struct ImageGenFieldSpecView: View {
    let spec: [String: Any]
    var compactSliderTracks: Bool = false
    var copiesSliderMax: Int? = nil
    @Binding var values: [String: Any]

    private func effectiveIntSliderMax(spec: [String: Any], key: String) -> Int {
        if key == "copies", let copiesSliderMax {
            return copiesSliderMax
        }
        return spec["max_value"] as? Int ?? 100
    }

    var body: some View {
        let key = spec["key"] as? String ?? ""
        let label = spec["label"] as? String ?? key
        let kind = spec["kind"] as? String ?? "text"
        switch kind {
        case "text":
            TextField(label, text: bindingString(key, default: spec["default"] as? String ?? ""))
        case "bool":
            Toggle(label, isOn: bindingBool(key, default: spec["default"] as? Bool ?? false))
        case "int_slider":
            ImageGenIntSliderRow(
                label: label,
                key: key,
                minValue: spec["min_value"] as? Int ?? 0,
                maxValue: effectiveIntSliderMax(spec: spec, key: key),
                step: spec["step"] as? Int ?? 1,
                resetDefault: spec["reset_default"],
                compactTrack: compactSliderTracks,
                inlineLabel: compactSliderTracks,
                continuousAt: key == "copies" && copiesSliderMax != nil
                    ? JobStepQueue.seriesContinuousCopies
                    : nil,
                values: $values
            )
        case "float_slider":
            ImageGenFloatSliderRow(
                label: label,
                key: key,
                minValue: doubleValue(spec["min_value"], default: 0),
                maxValue: doubleValue(spec["max_value"], default: 1),
                step: doubleValue(spec["step"], default: 0.1),
                resetDefault: spec["reset_default"],
                compactTrack: compactSliderTracks,
                inlineLabel: compactSliderTracks,
                values: $values
            )
        case "choice":
            ImageGenChoiceRow(
                label: label,
                key: key,
                spec: spec,
                inlineLabel: compactSliderTracks,
                values: $values
            )
        case "seed":
            ImageGenSeedRow(spec: spec, values: $values)
        default:
            EmptyView()
        }
    }

    private func doubleValue(_ raw: Any?, default defaultValue: Double) -> Double {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        return defaultValue
    }

    private func bindingString(_ key: String, default defaultValue: String) -> Binding<String> {
        Binding(
            get: { values[key] as? String ?? defaultValue },
            set: { values[key] = $0 }
        )
    }

    private func bindingBool(_ key: String, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { values[key] as? Bool ?? defaultValue },
            set: { values[key] = $0 }
        )
    }
}

@MainActor
private struct ImageGenChoiceRow: View {
    let label: String
    let key: String
    let spec: [String: Any]
    var inlineLabel: Bool = false
    var inlineLabelWidth: CGFloat = ImageGenInlineFieldLayout.parameterLabelWidth
    @Binding var values: [String: Any]

    private var options: [(title: String, tag: String)] {
        if let pairs = spec["choices"] as? [[Any]] {
            return pairs.map { pair in
                let title = stringifyChoiceValue(pair.first)
                let tag = stringifyChoiceValue(pair.count > 1 ? pair[1] : pair.first)
                return (title, tag)
            }
        }
        let choices = (spec["choices"] as? [Any])?.map { stringifyChoiceValue($0) } ?? []
        return choices.map { ($0, $0) }
    }

    private var controlRow: some View {
        HStack(spacing: 8) {
            Picker("", selection: selectionBinding) {
                ForEach(options, id: \.tag) { option in
                    Text(option.title).tag(option.tag)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: isQuantizationChoice ? 64 : nil)
            .frame(minWidth: isQuantizationChoice ? nil : 140)
            if spec["reset_default"] != nil {
                ImageGenFieldResetButton(
                    isActive: !ImageGenFieldResetLogic.matchesDefault(
                        current: values[key],
                        resetDefault: spec["reset_default"],
                        kind: "choice"
                    ),
                    tooltip: "Reset to default",
                    action: resetToDefault
                )
            }
        }
    }

    var body: some View {
        Group {
            if inlineLabel {
                HStack(alignment: .center, spacing: ImageGenInlineFieldLayout.rowSpacing) {
                    Text(label)
                        .font(ImageGenInlineFieldLayout.stackedFieldLabelFont)
                        .foregroundStyle(.primary)
                        .frame(width: inlineLabelWidth, alignment: .leading)
                    controlRow
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(ImageGenInlineFieldLayout.stackedFieldLabelFont)
                        .foregroundStyle(.primary)
                        .padding(.top, 4)
                    controlRow
                }
            }
        }
    }

    private var isQuantizationChoice: Bool {
        key == "mflux_quantize" || label.caseInsensitiveCompare("Quantization") == .orderedSame
    }

    private var selectionBinding: Binding<String> {
        return Binding(
            get: {
                if let string = values[key] as? String { return string }
                return stringifyChoiceValue(values[key])
            },
            set: { newValue in
                if let intValue = Int(newValue) {
                    values[key] = intValue
                } else if let doubleValue = Double(newValue) {
                    values[key] = doubleValue
                } else {
                    values[key] = newValue
                }
            }
        )
    }

    private func stringifyChoiceValue(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? Int { return String(number) }
        if let number = value as? Double { return String(number) }
        return ""
    }

    private func resetToDefault() {
        guard let resetDefault = spec["reset_default"] else { return }
        if let intValue = resetDefault as? Int {
            values[key] = intValue
        } else if let doubleValue = resetDefault as? Double {
            values[key] = doubleValue
        } else {
            values[key] = ImageGenFieldResetLogic.stringify(resetDefault)
        }
    }
}

@MainActor
private struct ImageGenSeedRowGroup: View {
    let node: [String: Any]
    var inlineLabel: Bool = false
    var inlineLabelWidth: CGFloat = ImageGenInlineFieldLayout.parameterLabelWidth
    @Binding var values: [String: Any]

    private var childSpecs: [[String: Any]] {
        (node["children"] as? [[String: Any]] ?? []).compactMap { child in
            child["spec"] as? [String: Any]
        }
    }

    var body: some View {
        let seedSpec = childSpecs.first { $0["key"] as? String == "seed" }
        let randomSpec = childSpecs.first { $0["key"] as? String == "random_seed" }
        let seedLabel = seedSpec?["label"] as? String ?? "Seed"
        let controls = HStack(alignment: .center, spacing: 10) {
            if let seedSpec {
                ImageGenSeedInput(spec: seedSpec, values: $values)
            }
            if let randomSpec {
                let label = randomSpec["bool_label_override"] as? String
                    ?? randomSpec["label"] as? String
                    ?? "Randomize"
                Toggle(label, isOn: bindingBool(randomSpec, key: "random_seed", default: true))
                    .help(
                        "Use a new random number\n"
                        + "each time you generate."
                    )
            }
        }
        Group {
            if inlineLabel {
                HStack(alignment: .center, spacing: ImageGenInlineFieldLayout.rowSpacing) {
                    Text(seedLabel)
                        .font(ImageGenInlineFieldLayout.stackedFieldLabelFont)
                        .foregroundStyle(.primary)
                        .frame(width: inlineLabelWidth, alignment: .leading)
                    controls
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(seedLabel)
                        .font(ImageGenInlineFieldLayout.stackedFieldLabelFont)
                        .foregroundStyle(.primary)
                        .padding(.top, 4)
                    controls
                }
            }
        }
    }

    private func bindingBool(_ spec: [String: Any], key: String, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { values[key] as? Bool ?? spec["default"] as? Bool ?? defaultValue },
            set: { values[key] = $0 }
        )
    }
}

@MainActor
private struct ImageGenStepsQuantRowGroup: View {
    let node: [String: Any]
    var compactSliderTracks: Bool = false
    var copiesSliderMax: Int? = nil
    @Binding var values: [String: Any]

    private var childSpecs: [[String: Any]] {
        (node["children"] as? [[String: Any]] ?? []).compactMap { child in
            child["spec"] as? [String: Any]
        }
    }

    var body: some View {
        HStack(alignment: compactSliderTracks ? .center : .top, spacing: 12) {
            if let stepsSpec = childSpecs.first(where: { $0["key"] as? String == "steps" }) {
                ImageGenFieldSpecView(
                    spec: stepsSpec,
                    compactSliderTracks: compactSliderTracks,
                    copiesSliderMax: copiesSliderMax,
                    values: $values
                )
                .fixedSize(horizontal: compactSliderTracks, vertical: false)
            }
            if let quantSpec = childSpecs.first(where: { $0["key"] as? String == "mflux_quantize" }) {
                ImageGenFieldSpecView(
                    spec: quantSpec,
                    compactSliderTracks: compactSliderTracks,
                    copiesSliderMax: copiesSliderMax,
                    values: $values
                )
                .fixedSize(horizontal: compactSliderTracks, vertical: false)
            }
        }
    }
}

@MainActor
private struct ImageGenSeedRow: View {
    let spec: [String: Any]
    @Binding var values: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(spec["label"] as? String ?? "Seed")
                .font(ImageGenInlineFieldLayout.stackedFieldLabelFont)
                .foregroundStyle(.primary)
                .padding(.top, 4)
            ImageGenSeedInput(spec: spec, values: $values)
        }
    }
}

@MainActor
private struct ImageGenSeedInput: View {
    let spec: [String: Any]
    @Binding var values: [String: Any]

    @State private var seedText = ""
    @FocusState private var isEditing: Bool

    private var seedMaximum: Int { Int(UInt32.max) }

    var body: some View {
        TextField("Seed", text: $seedText)
            .textFieldStyle(.roundedBorder)
            .frame(width: 96)
            .focused($isEditing)
            .onSubmit { commitSeedText() }
            .onChange(of: isEditing) { _, editing in
                if !editing { commitSeedText() }
            }
            .onAppear { syncSeedText() }
            .onChange(of: values["seed"] as? Int) { _, _ in
                if !isEditing {
                    syncSeedText()
                }
            }
    }

    private func syncSeedText() {
        seedText = String(values["seed"] as? Int ?? spec["default"] as? Int ?? 0)
    }

    private func commitSeedText() {
        guard let parsed = Int(seedText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            syncSeedText()
            return
        }
        let clamped = max(0, min(seedMaximum, parsed))
        values["seed"] = clamped
        seedText = String(clamped)
    }
}
