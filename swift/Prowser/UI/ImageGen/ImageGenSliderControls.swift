import AppKit
import SwiftUI

/// Width/height slider with sparse NSSlider tick marks and floor-to-step snapping.
@MainActor
struct ImageGenDimSliderRow: View {
    let label: String
    let key: String
    let minValue: Int
    let maxValue: Int
    let step: Int
    var resetDefault: Any? = nil
    @Binding var values: [String: Any]
    var onValueChanged: ((Int) -> Void)?

    @State private var textValue = ""
    @FocusState private var isEditing: Bool

    private var pageStep: Int {
        ImageGenDimMath.pageStep(minValue: minValue, maxValue: maxValue, dimStep: step)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ImageGenDimNSSlider(
                    value: sliderBinding,
                    minValue: minValue,
                    maxValue: maxValue,
                    step: step,
                    pageStep: pageStep
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
        .onChange(of: maxValue) { _, _ in
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

    private var sliderBinding: Binding<Int> {
        Binding(
            get: { currentValue },
            set: { newValue in
                setValue(newValue)
                onValueChanged?(newValue)
            }
        )
    }

    private func setValue(_ raw: Int) {
        let clamped = snap(max(minValue, min(maxValue, raw)))
        values[key] = clamped
        textValue = String(clamped)
    }

    private func snap(_ value: Int) -> Int {
        let snapped = ImageGenDimMath.snapDimFloor(value, step: step)
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
        onValueChanged?(currentValue)
    }
}

private struct ImageGenDimNSSlider: NSViewRepresentable {
    @Binding var value: Int
    let minValue: Int
    let maxValue: Int
    let step: Int
    let pageStep: Int

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: Double(value), minValue: Double(minValue), maxValue: Double(maxValue), target: nil, action: nil)
        slider.isContinuous = true
        slider.allowsTickMarkValuesOnly = false
        slider.tickMarkPosition = .below
        applySteps(slider)
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = Double(minValue)
        slider.maxValue = Double(maxValue)
        applySteps(slider)
        let snapped = ImageGenDimMath.snapDimFloor(value, step: step)
        let clamped = max(minValue, min(maxValue, snapped))
        if Int(slider.integerValue) != clamped {
            slider.integerValue = clamped
        }
    }

    private func applySteps(_ slider: NSSlider) {
        slider.altIncrementValue = Double(pageStep)
        let range = max(0, maxValue - minValue)
        if range > 0 && pageStep > 0 {
            let tickCount = max(2, range / pageStep + 1)
            slider.numberOfTickMarks = tickCount
        } else {
            slider.numberOfTickMarks = 0
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject {
        var parent: ImageGenDimNSSlider

        init(_ parent: ImageGenDimNSSlider) {
            self.parent = parent
        }

        @objc func changed(_ sender: NSSlider) {
            let raw = Int(sender.integerValue)
            let snapped = ImageGenDimMath.snapDimFloor(raw, step: parent.step)
            let clamped = max(parent.minValue, min(parent.maxValue, snapped))
            if sender.integerValue != clamped {
                sender.integerValue = clamped
            }
            parent.value = clamped
        }
    }
}

@MainActor
struct ImageGenIntSliderRow: View {
    let label: String
    let key: String
    let minValue: Int
    let maxValue: Int
    let step: Int
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
