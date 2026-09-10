import SwiftUI

@MainActor
struct ImageGenFieldRenderer: View {
    let layout: [[String: Any]]
    @Binding var values: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(layout.indices, id: \.self) { index in
                ImageGenFieldNodeView(node: layout[index], values: $values)
            }
        }
    }
}

@MainActor
private struct ImageGenFieldNodeView: View {
    let node: [String: Any]
    @Binding var values: [String: Any]

    var body: some View {
        let type = node["type"] as? String ?? "field"
        if type == "group" {
            let layout = node["layout"] as? String ?? ""
            if layout == "seed_row" {
                ImageGenSeedRowGroup(node: node, values: $values)
            } else if layout == "steps_quant_row" {
                ImageGenStepsQuantRowGroup(node: node, values: $values)
            } else if layout == "prompt_block" {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let label = node["label"] as? String, !label.isEmpty {
                        Text(label).font(.caption).foregroundStyle(.secondary)
                    }
                    if let children = node["children"] as? [[String: Any]] {
                        ForEach(children.indices, id: \.self) { idx in
                            ImageGenFieldNodeView(node: children[idx], values: $values)
                        }
                    }
                }
            }
        } else if let spec = node["spec"] as? [String: Any] {
            ImageGenFieldSpecView(spec: spec, values: $values)
        }
    }
}

@MainActor
private struct ImageGenFieldSpecView: View {
    let spec: [String: Any]
    @Binding var values: [String: Any]

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
                maxValue: spec["max_value"] as? Int ?? 100,
                step: spec["step"] as? Int ?? 1,
                presetValues: ImageGenSliderPresets.intPresets(
                    key: key,
                    min: spec["min_value"] as? Int ?? 0,
                    max: spec["max_value"] as? Int ?? 100,
                    step: spec["step"] as? Int ?? 1,
                    choices: spec["choices"] as? [Any]
                ),
                resetDefault: spec["reset_default"],
                values: $values
            )
        case "float_slider":
            ImageGenFloatSliderRow(
                label: label,
                key: key,
                minValue: doubleValue(spec["min_value"], default: 0),
                maxValue: doubleValue(spec["max_value"], default: 1),
                step: doubleValue(spec["step"], default: 0.1),
                presetValues: ImageGenSliderPresets.floatPresets(
                    min: doubleValue(spec["min_value"], default: 0),
                    max: doubleValue(spec["max_value"], default: 1),
                    step: doubleValue(spec["step"], default: 0.1),
                    key: key
                ),
                resetDefault: spec["reset_default"],
                values: $values
            )
        case "choice":
            ImageGenChoiceRow(label: label, key: key, spec: spec, values: $values)
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
    @Binding var values: [String: Any]

    @State private var textValue = ""
    @FocusState private var isEditing: Bool

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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Picker("", selection: selectionBinding) {
                    ForEach(options, id: \.tag) { option in
                        Text(option.title).tag(option.tag)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 140)
                TextField("", text: $textValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 88)
                    .focused($isEditing)
                    .onSubmit { commitTextValue() }
                    .onChange(of: isEditing) { _, editing in
                        if !editing { commitTextValue() }
                    }
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
        .onAppear { syncTextFromSelection() }
        .onChange(of: selectionBinding.wrappedValue) { _, _ in
            if !isEditing {
                syncTextFromSelection()
            }
        }
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

    private func syncTextFromSelection() {
        textValue = selectionBinding.wrappedValue
    }

    private func commitTextValue() {
        let trimmed = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            syncTextFromSelection()
            return
        }
        if let match = options.first(where: { $0.tag == trimmed || $0.title == trimmed }) {
            values[key] = match.tag
            textValue = match.tag
        } else {
            values[key] = trimmed
        }
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
        syncTextFromSelection()
    }
}

@MainActor
private struct ImageGenSeedRowGroup: View {
    let node: [String: Any]
    @Binding var values: [String: Any]

    private var childSpecs: [[String: Any]] {
        (node["children"] as? [[String: Any]] ?? []).compactMap { child in
            child["spec"] as? [String: Any]
        }
    }

    var body: some View {
        let seedSpec = childSpecs.first { $0["key"] as? String == "seed" }
        let randomSpec = childSpecs.first { $0["key"] as? String == "random_seed" }
        HStack(alignment: .top, spacing: 12) {
            if let seedSpec {
                ImageGenSeedRow(spec: seedSpec, values: $values)
            }
            if let randomSpec {
                let label = randomSpec["bool_label_override"] as? String
                    ?? randomSpec["label"] as? String
                    ?? "Randomize"
                Toggle(label, isOn: bindingBool(randomSpec, key: "random_seed", default: true))
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
    @Binding var values: [String: Any]

    private var childSpecs: [[String: Any]] {
        (node["children"] as? [[String: Any]] ?? []).compactMap { child in
            child["spec"] as? [String: Any]
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let stepsSpec = childSpecs.first(where: { $0["key"] as? String == "steps" }) {
                ImageGenFieldSpecView(spec: stepsSpec, values: $values)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let quantSpec = childSpecs.first(where: { $0["key"] as? String == "mflux_quantize" }) {
                ImageGenFieldSpecView(spec: quantSpec, values: $values)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

@MainActor
private struct ImageGenSeedRow: View {
    let spec: [String: Any]
    @Binding var values: [String: Any]

    @State private var seedText = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(spec["label"] as? String ?? "Seed")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !(values["random_seed"] as? Bool ?? true) {
                HStack(spacing: 8) {
                    Slider(
                        value: seedSliderBinding,
                        in: 0...Double(Int.max / 4),
                        step: 1
                    )
                    TextField("Seed", text: $seedText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .focused($isEditing)
                        .onSubmit { commitSeedText() }
                        .onChange(of: isEditing) { _, editing in
                            if !editing { commitSeedText() }
                        }
                }
            }
        }
        .onAppear { syncSeedText() }
        .onChange(of: values["seed"] as? Int) { _, _ in
            if !isEditing {
                syncSeedText()
            }
        }
    }

    private var seedSliderBinding: Binding<Double> {
        Binding(
            get: { Double(values["seed"] as? Int ?? spec["default"] as? Int ?? 0) },
            set: { values["seed"] = max(0, Int($0.rounded())) }
        )
    }

    private func bindingBool(_ key: String, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { values[key] as? Bool ?? defaultValue },
            set: { values[key] = $0 }
        )
    }

    private func syncSeedText() {
        seedText = String(values["seed"] as? Int ?? spec["default"] as? Int ?? 0)
    }

    private func commitSeedText() {
        guard let parsed = Int(seedText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            syncSeedText()
            return
        }
        values["seed"] = max(0, parsed)
        seedText = String(max(0, parsed))
    }
}
