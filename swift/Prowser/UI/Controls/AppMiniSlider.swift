import AppKit
import SwiftUI

/// Native mini slider used throughout the app for a circular thumb and no tick marks.
struct AppMiniSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var alternateStep: Double?

    @Environment(\.isEnabled) private var isEnabled

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        alternateStep: Double? = nil
    ) {
        _value = value
        self.range = range
        self.step = step
        self.alternateStep = alternateStep
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = AppKeyboardSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        configure(slider)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        configure(slider)
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        if slider.doubleValue != clamped {
            slider.doubleValue = clamped
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func configure(_ slider: NSSlider) {
        slider.controlSize = .mini
        slider.sliderType = .linear
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.isEnabled = isEnabled
        slider.altIncrementValue = alternateStep ?? step ?? 0
        if let slider = slider as? AppKeyboardSlider {
            slider.keyboardStep = step
            slider.keyboardAlternateStep = alternateStep
        }
    }

    final class Coordinator: NSObject {
        var parent: AppMiniSlider

        init(_ parent: AppMiniSlider) {
            self.parent = parent
        }

        @objc func changed(_ sender: NSSlider) {
            let range = parent.range
            var newValue = min(range.upperBound, max(range.lowerBound, sender.doubleValue))
            if let step = parent.step, step > 0 {
                newValue = range.lowerBound
                    + ((newValue - range.lowerBound) / step).rounded() * step
                newValue = min(range.upperBound, max(range.lowerBound, newValue))
                sender.doubleValue = newValue
            }
            parent.value = newValue
        }
    }
}

private final class AppKeyboardSlider: NSSlider {
    var keyboardStep: Double?
    var keyboardAlternateStep: Double?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let direction: Double
        switch event.keyCode {
        case 123, 125:
            direction = -1
        case 124, 126:
            direction = 1
        default:
            super.keyDown(with: event)
            return
        }

        guard let keyboardStep, keyboardStep > 0 else {
            super.keyDown(with: event)
            return
        }
        let increment = event.modifierFlags.contains(.option)
            ? keyboardAlternateStep ?? keyboardStep
            : keyboardStep
        doubleValue = min(maxValue, max(minValue, doubleValue + direction * increment))
        sendAction(action, to: target)
    }
}
