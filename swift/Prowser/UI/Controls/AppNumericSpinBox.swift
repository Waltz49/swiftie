import AppKit
import SwiftUI

/// Native numeric entry with an adjacent stepper. The binding remains the source of truth.
struct AppNumericSpinBox: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let decimalPlaces: Int
    let controlWidth: CGFloat

    @Environment(\.isEnabled) private var isEnabled

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        decimalPlaces: Int,
        controlWidth: CGFloat
    ) {
        _value = value
        self.range = range
        self.step = step
        self.decimalPlaces = decimalPlaces
        self.controlWidth = controlWidth
    }

    static func integerWidth(minValue: Int, maxValue: Int) -> CGFloat {
        width(for: [String(minValue), String(maxValue)])
    }

    static func floatWidth(minValue: Double, maxValue: Double, decimalPlaces: Int = 2) -> CGFloat {
        width(for: [
            String(format: "%.\(decimalPlaces)f", minValue),
            String(format: "%.\(decimalPlaces)f", maxValue),
        ])
    }

    func makeNSView(context: Context) -> AppNumericSpinBoxView {
        let view = AppNumericSpinBoxView(controlWidth: controlWidth)
        view.textField.delegate = context.coordinator
        view.textField.target = context.coordinator
        view.textField.action = #selector(Coordinator.commitText(_:))
        view.stepper.target = context.coordinator
        view.stepper.action = #selector(Coordinator.stepperChanged(_:))
        configure(view)
        context.coordinator.sync(view, value: value)
        return view
    }

    func updateNSView(_ view: AppNumericSpinBoxView, context: Context) {
        context.coordinator.parent = self
        configure(view)
        if view.window?.firstResponder !== view.textField.currentEditor() {
            context.coordinator.sync(view, value: value)
        } else {
            view.stepper.doubleValue = value
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func configure(_ view: AppNumericSpinBoxView) {
        view.controlWidth = controlWidth
        view.stepper.minValue = range.lowerBound
        view.stepper.maxValue = range.upperBound
        view.stepper.increment = max(step, Double.leastNonzeroMagnitude)
        view.textField.isEnabled = isEnabled
        view.stepper.isEnabled = isEnabled
    }

    private static func width(for samples: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        let textWidth = samples.map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return ceil(max(56, textWidth + 38))
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AppNumericSpinBox
        weak var view: AppNumericSpinBoxView?

        init(_ parent: AppNumericSpinBox) {
            self.parent = parent
        }

        @objc func stepperChanged(_ sender: NSStepper) {
            setValue(sender.doubleValue)
        }

        @objc func commitText(_ sender: NSTextField) {
            commit(sender)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            commit(field)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                step(by: parent.step)
                return true
            case #selector(NSResponder.moveDown(_:)):
                step(by: -parent.step)
                return true
            default:
                return false
            }
        }

        func sync(_ view: AppNumericSpinBoxView, value: Double) {
            self.view = view
            let clamped = min(parent.range.upperBound, max(parent.range.lowerBound, value))
            view.stepper.doubleValue = clamped
            view.textField.stringValue = formatted(clamped)
        }

        private func commit(_ field: NSTextField) {
            guard let parsed = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                if let view { sync(view, value: parent.value) }
                return
            }
            setValue(parsed)
        }

        private func step(by delta: Double) {
            let base = Double(view?.textField.stringValue ?? "") ?? parent.value
            setValue(base + delta)
        }

        private func setValue(_ rawValue: Double) {
            let clamped = min(parent.range.upperBound, max(parent.range.lowerBound, rawValue))
            parent.value = clamped
            if let view {
                sync(view, value: parent.value)
            }
        }

        private func formatted(_ value: Double) -> String {
            String(format: "%.\(parent.decimalPlaces)f", value)
        }
    }
}

final class AppNumericSpinBoxView: NSView {
    let textField = NSTextField()
    let stepper = NSStepper()
    var controlWidth: CGFloat {
        didSet {
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    init(controlWidth: CGFloat) {
        self.controlWidth = controlWidth
        super.init(frame: .zero)

        textField.controlSize = .small
        textField.alignment = .right
        textField.isBezeled = true
        textField.isEditable = true
        textField.isSelectable = true
        textField.focusRingType = .default

        stepper.controlSize = .small
        stepper.valueWraps = false
        stepper.autorepeat = true

        addSubview(textField)
        addSubview(stepper)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: controlWidth,
            height: max(textField.fittingSize.height, stepper.fittingSize.height)
        )
    }

    override func layout() {
        super.layout()
        let stepperWidth = stepper.fittingSize.width
        let height = bounds.height
        textField.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - stepperWidth - 2), height: height)
        stepper.frame = NSRect(x: bounds.width - stepperWidth, y: 0, width: stepperWidth, height: height)
    }
}
