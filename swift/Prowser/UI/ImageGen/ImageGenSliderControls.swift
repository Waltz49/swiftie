import SwiftUI

@MainActor
struct ImageGenIntSliderRow: View {
    let label: String
    let key: String
    let minValue: Int
    let maxValue: Int
    let step: Int
    let presetValues: [Int]
    var resetDefault: Any? = nil
    @Binding var values: [String: Any]

    @State private var textValue = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Slider(
                    value: sliderBinding,
                    in: Double(minValue)...Double(maxValue),
                    step: Double(max(1, step))
                )
                TextField("", text: $textValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    .focused($isEditing)
                    .onSubmit { commitTextValue() }
                    .onChange(of: isEditing) { _, editing in
                        if !editing { commitTextValue() }
                    }
                if !presetValues.isEmpty {
                    Menu {
                        ForEach(presetValues, id: \.self) { preset in
                            Button("\(preset)") {
                                setValue(preset)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .frame(width: 20, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .help("Preset values")
                }
                if resetDefault != nil {
                    ImageGenFieldResetButton(
                        isActive: !ImageGenFieldResetLogic.matchesDefault(
                            current: values[key],
                            resetDefault: resetDefault,
                            kind: "int_slider"
                        ),
                        tooltip: "Reset to default",
                        action: resetToDefault
                    )
                }
            }
        }
        .onAppear { syncTextFromValue() }
        .onChange(of: currentValue) { _, _ in
            if !isEditing {
                syncTextFromValue()
            }
        }
    }

    private var currentValue: Int {
        values[key] as? Int ?? minValue
    }

    private func resetToDefault() {
        guard let resetDefault else { return }
        setValue(ImageGenFieldResetLogic.intValue(resetDefault))
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { Double(currentValue) },
            set: { setValue(snap(Int($0.rounded()))) }
        )
    }

    private func setValue(_ raw: Int) {
        let clamped = snap(max(minValue, min(maxValue, raw)))
        values[key] = clamped
        textValue = String(clamped)
    }

    private func snap(_ value: Int) -> Int {
        let s = max(1, step)
        let offset = value - minValue
        let snapped = minValue + (offset / s) * s
        return max(minValue, min(maxValue, snapped))
    }

    private func syncTextFromValue() {
        textValue = String(currentValue)
    }

    private func commitTextValue() {
        let trimmed = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed) else {
            syncTextFromValue()
            return
        }
        setValue(parsed)
    }
}

@MainActor
struct ImageGenFloatSliderRow: View {
    let label: String
    let key: String
    let minValue: Double
    let maxValue: Double
    let step: Double
    let presetValues: [Double]
    var resetDefault: Any? = nil
    @Binding var values: [String: Any]

    @State private var textValue = ""
    @FocusState private var isEditing: Bool

    private var decimalPlaces: Int {
        step < 0.1 ? 2 : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Slider(
                    value: sliderBinding,
                    in: minValue...maxValue,
                    step: max(step, 0.01)
                )
                TextField("", text: $textValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .multilineTextAlignment(.trailing)
                    .focused($isEditing)
                    .onSubmit { commitTextValue() }
                    .onChange(of: isEditing) { _, editing in
                        if !editing { commitTextValue() }
                    }
                if !presetValues.isEmpty {
                    Menu {
                        ForEach(presetValues, id: \.self) { preset in
                            Button(format(preset)) {
                                setValue(preset)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .frame(width: 20, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .help("Preset values")
                }
                if resetDefault != nil {
                    ImageGenFieldResetButton(
                        isActive: !ImageGenFieldResetLogic.matchesDefault(
                            current: values[key],
                            resetDefault: resetDefault,
                            kind: "float_slider",
                            step: step
                        ),
                        tooltip: "Reset to default",
                        action: resetToDefault
                    )
                }
            }
        }
        .onAppear { syncTextFromValue() }
        .onChange(of: currentValue) { _, _ in
            if !isEditing {
                syncTextFromValue()
            }
        }
    }

    private func resetToDefault() {
        guard let resetDefault else { return }
        setValue(ImageGenFieldResetLogic.doubleValue(resetDefault))
    }

    private var currentValue: Double {
        if let value = values[key] as? Double { return value }
        if let value = values[key] as? Int { return Double(value) }
        return minValue
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { currentValue },
            set: { setValue(snap($0)) }
        )
    }

    private func setValue(_ raw: Double) {
        let clamped = snap(max(minValue, min(maxValue, raw)))
        values[key] = clamped
        textValue = format(clamped)
    }

    private func snap(_ value: Double) -> Double {
        let s = max(step, 0.0001)
        let steps = round((value - minValue) / s)
        return max(minValue, min(maxValue, minValue + steps * s))
    }

    private func format(_ value: Double) -> String {
        String(format: "%.\(decimalPlaces)f", value)
    }

    private func syncTextFromValue() {
        textValue = format(currentValue)
    }

    private func commitTextValue() {
        let trimmed = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Double(trimmed) else {
            syncTextFromValue()
            return
        }
        setValue(parsed)
    }
}

enum ImageGenSliderPresets {
    static func intPresets(
        key: String,
        min: Int,
        max: Int,
        step: Int,
        choices: [Any]?
    ) -> [Int] {
        if let choices {
            return choices.compactMap { choice in
                if let value = choice as? Int { return value }
                if let value = Int("\(choice)") { return value }
                return nil
            }
        }
        if key == "width" || key == "height" {
            return dimensionPresets(min: min, max: max, step: step)
        }
        if key == "steps" {
            return [1, 2, 4, 8, 12, 16, 20, 24, 30].filter { $0 >= min && $0 <= max }
        }
        if key == "copies" {
            return [1, 2, 3, 4, 5, 10, 20, 30, 51].filter { $0 >= min && $0 <= max }
        }
        return []
    }

    static func floatPresets(min minimum: Double, max maximum: Double, step: Double, key: String) -> [Double] {
        if key == "guidance_scale" {
            return [0, 1, 1.5, 2, 3, 3.5, 5, 7.5, 10].filter { $0 >= minimum && $0 <= maximum }
        }
        let count = Swift.min(8, Int((maximum - minimum) / Swift.max(step, 0.1)) + 1)
        guard count > 1 else { return [] }
        return (0..<count).map { index in
            minimum + (Double(index) * (maximum - minimum) / Double(count - 1))
        }
    }

    private static func dimensionPresets(min: Int, max: Int, step: Int) -> [Int] {
        let candidates = [256, 512, 640, 768, 832, 896, 1024, 1152, 1280, 1344, 1408, 1536, 1664, 1792, 1920, 2048]
        let filtered = candidates.filter { $0 >= min && $0 <= max }
        if filtered.contains(min) && filtered.contains(max) {
            return filtered
        }
        var presets = Set(filtered)
        presets.insert(min)
        presets.insert(max)
        return presets.sorted()
    }
}
