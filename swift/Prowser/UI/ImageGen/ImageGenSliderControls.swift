import AppKit
import SwiftUI

/// Slider row metrics aligned with Python ``IMAGE_GEN_SLIDER_*`` (unified dialog uses ~half track width).
enum ImageGenSliderLayout {
    static let rowSpacing: CGFloat = 8
    static let rowHeight: CGFloat = 28
    /// Python ``IMAGE_GEN_SLIDER_TRACK_WIDTH``; compact rows flow at their natural width.
    static let unifiedTrackWidth: CGFloat = 200
}

@MainActor
struct ImageGenSliderTrackRow<Slider: View, Trailing: View>: View {
    var compactTrack: Bool
    var includesReset: Bool
    var valueControlWidth: CGFloat
    @ViewBuilder var slider: () -> Slider
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        if compactTrack {
            HStack(spacing: ImageGenSliderLayout.rowSpacing) {
                slider()
                    .frame(width: ImageGenSliderLayout.unifiedTrackWidth)
                trailing()
            }
            .frame(height: ImageGenSliderLayout.rowHeight)
            .fixedSize(horizontal: true, vertical: false)
        } else {
            HStack(spacing: ImageGenSliderLayout.rowSpacing) {
                slider()
                trailing()
            }
        }
    }
}

/// Width/height NSSlider with floor-to-step snapping (no visible tick marks).
@MainActor
struct ImageGenDimSliderRow: View {
    let label: String
    let key: String
    let minValue: Int
    let maxValue: Int
    let step: Int
    var resetDefault: Any? = nil
    var compactTrack: Bool = false
    var inlineLabel: Bool = false
    var inlineLabelWidth: CGFloat = 44
    @Binding var values: [String: Any]
    var onValueChanged: ((Int) -> Void)?

    private var pageStep: Int {
        ImageGenDimMath.pageStep(minValue: minValue, maxValue: maxValue, dimStep: step)
    }

    private var includesReset: Bool { resetDefault != nil }
    private var valueControlWidth: CGFloat {
        AppNumericSpinBox.integerWidth(minValue: minValue, maxValue: maxValue)
    }

    private var sliderTrackRow: some View {
        ImageGenSliderTrackRow(
            compactTrack: compactTrack,
            includesReset: includesReset,
            valueControlWidth: valueControlWidth
        ) {
            AppMiniSlider(
                value: sliderBinding,
                in: Double(minValue)...Double(maxValue),
                step: Double(step),
                alternateStep: Double(pageStep)
            )
        } trailing: {
            AppNumericSpinBox(
                value: sliderBinding,
                in: Double(minValue)...Double(maxValue),
                step: Double(step),
                decimalPlaces: 0,
                controlWidth: valueControlWidth
            )
            .frame(width: valueControlWidth)
            if includesReset {
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

    var body: some View {
        Group {
            if inlineLabel {
                HStack(alignment: .center, spacing: 6) {
                    Text(label)
                        .font(ImageGenInlineFieldLayout.customSizeDimLabelFont)
                        .foregroundStyle(.primary)
                        .frame(width: inlineLabelWidth, alignment: .leading)
                    sliderTrackRow
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(ImageGenInlineFieldLayout.stackedFieldLabelFont)
                        .foregroundStyle(.primary)
                        .padding(.top, 4)
                    sliderTrackRow
                }
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
            set: { newValue in
                setValue(Int(newValue.rounded()))
                onValueChanged?(currentValue)
            }
        )
    }

    private func setValue(_ raw: Int) {
        let clamped = snap(max(minValue, min(maxValue, raw)))
        values[key] = clamped
    }

    private func snap(_ value: Int) -> Int {
        let snapped = ImageGenDimMath.snapDimFloor(value, step: step)
        return max(minValue, min(maxValue, snapped))
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
    var compactTrack: Bool = false
    var inlineLabel: Bool = false
    var inlineLabelWidth: CGFloat = ImageGenInlineFieldLayout.parameterLabelWidth
    @Binding var values: [String: Any]

    private var includesReset: Bool { resetDefault != nil }
    private var valueControlWidth: CGFloat {
        AppNumericSpinBox.integerWidth(minValue: minValue, maxValue: maxValue)
    }

    private var sliderTrackRow: some View {
        ImageGenSliderTrackRow(
            compactTrack: compactTrack,
            includesReset: includesReset,
            valueControlWidth: valueControlWidth
        ) {
            AppMiniSlider(
                value: sliderBinding,
                in: Double(minValue)...Double(maxValue),
                step: Double(max(1, step))
            )
        } trailing: {
            AppNumericSpinBox(
                value: sliderBinding,
                in: Double(minValue)...Double(maxValue),
                step: Double(max(1, step)),
                decimalPlaces: 0,
                controlWidth: valueControlWidth
            )
            .frame(width: valueControlWidth)
            if includesReset {
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

    var body: some View {
        Group {
            if inlineLabel {
                HStack(alignment: .center, spacing: ImageGenInlineFieldLayout.rowSpacing) {
                    Text(label)
                        .font(ImageGenInlineFieldLayout.stackedFieldLabelFont)
                        .foregroundStyle(.primary)
                        .frame(width: inlineLabelWidth, alignment: .leading)
                    sliderTrackRow
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(ImageGenInlineFieldLayout.stackedFieldLabelFont)
                        .foregroundStyle(.primary)
                        .padding(.top, 4)
                    sliderTrackRow
                }
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
    }

    private func snap(_ value: Int) -> Int {
        let s = max(1, step)
        let offset = value - minValue
        let snapped = minValue + (offset / s) * s
        return max(minValue, min(maxValue, snapped))
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
    var compactTrack: Bool = false
    var inlineLabel: Bool = false
    var inlineLabelWidth: CGFloat = ImageGenInlineFieldLayout.parameterLabelWidth
    @Binding var values: [String: Any]

    private var includesReset: Bool { resetDefault != nil }
    private let decimalPlaces = 2
    private var valueControlWidth: CGFloat {
        AppNumericSpinBox.floatWidth(
            minValue: minValue,
            maxValue: maxValue,
            decimalPlaces: decimalPlaces
        )
    }

    private var sliderTrackRow: some View {
        ImageGenSliderTrackRow(
            compactTrack: compactTrack,
            includesReset: includesReset,
            valueControlWidth: valueControlWidth
        ) {
            AppMiniSlider(
                value: sliderBinding,
                in: minValue...maxValue,
                step: max(step, 0.01)
            )
        } trailing: {
            AppNumericSpinBox(
                value: sliderBinding,
                in: minValue...maxValue,
                step: max(step, 0.01),
                decimalPlaces: decimalPlaces,
                controlWidth: valueControlWidth
            )
            .frame(width: valueControlWidth)
            if includesReset {
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

    var body: some View {
        Group {
            if inlineLabel {
                HStack(alignment: .center, spacing: ImageGenInlineFieldLayout.rowSpacing) {
                    Text(label)
                        .font(ImageGenInlineFieldLayout.stackedFieldLabelFont)
                        .foregroundStyle(.primary)
                        .frame(width: inlineLabelWidth, alignment: .leading)
                    sliderTrackRow
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(label)
                        .font(ImageGenInlineFieldLayout.stackedFieldLabelFont)
                        .foregroundStyle(.primary)
                        .padding(.top, 4)
                    sliderTrackRow
                }
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
    }

    private func snap(_ value: Double) -> Double {
        let s = max(step, 0.0001)
        let steps = round((value - minValue) / s)
        return max(minValue, min(maxValue, minValue + steps * s))
    }

}
