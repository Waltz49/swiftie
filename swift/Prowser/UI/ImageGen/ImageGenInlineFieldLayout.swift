import AppKit
import SwiftUI

/// Inline label + control rows (Python ``build_image_gen_inline_labeled_row``).
enum ImageGenInlineFieldLayout {
    /// Python ``IMAGE_GEN_FIELD_CONTROL_INDENT``.
    static let controlIndent: CGFloat = 30
    /// Model / LoRA menu fields (Python min-width 280 on combos).
    static let fieldControlMinWidth: CGFloat = 280
    static let fieldControlMaxWidth: CGFloat = 400
    static let labelPad: CGFloat = 12
    static let rowSpacing: CGFloat = 6
    static let blockSpacing: CGFloat = 6
    /// Python ``IMAGE_GEN_FIELD_LABEL_FONT_SIZE``.
    static let labelFontSize: CGFloat = 14
    /// Custom size width/height labels inside ``imageGenCustomSizeGroup``.
    static let customSizeDimLabelSize: CGFloat = 12
    static let infoLineFontSize: CGFloat = 11
    static let defaultLabelTexts = ["Model", "LoRAs"]

    static var labelFont: Font {
        .system(size: labelFontSize, weight: .regular)
    }

    static var customSizeDimLabelFont: Font {
        .system(size: customSizeDimLabelSize, weight: .regular)
    }

    static var stackedFieldLabelFont: Font {
        .system(size: labelFontSize, weight: .regular)
    }

    static var infoLineFont: Font {
        .system(size: infoLineFontSize, weight: .regular)
    }

    static var introFont: Font {
        .system(size: labelFontSize, weight: .regular)
    }

    static func labelColumnWidth(extraLabels: [String] = []) -> CGFloat {
        let labels = defaultLabelTexts + extraLabels
        let font = NSFont.systemFont(ofSize: labelFontSize)
        let maxText = labels.map { textWidth($0, font: font) }.max() ?? 0
        return maxText + labelPad
    }

    /// Shared label column for compact parameter rows (Seed, Steps, Copies, …).
    static var parameterLabelWidth: CGFloat {
        labelColumnWidth(extraLabels: ["Quantization", "Continuous", "Randomize", "Seed", "Steps", "Copies"])
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }
}

@MainActor
struct ImageGenInlineFieldLabel: View {
    let text: String
    var width: CGFloat

    var body: some View {
        Text(text)
            .font(ImageGenInlineFieldLayout.labelFont)
            .foregroundStyle(.primary)
            .frame(width: width, alignment: .leading)
    }
}

@MainActor
struct ImageGenInlineLabeledRow<Control: View, Accessories: View>: View {
    let label: String
    let labelWidth: CGFloat
    @ViewBuilder var control: () -> Control
    @ViewBuilder var accessories: () -> Accessories

    init(
        label: String,
        labelWidth: CGFloat,
        @ViewBuilder control: @escaping () -> Control,
        @ViewBuilder accessories: @escaping () -> Accessories = { EmptyView() }
    ) {
        self.label = label
        self.labelWidth = labelWidth
        self.control = control
        self.accessories = accessories
    }

    var body: some View {
        HStack(alignment: .center, spacing: ImageGenInlineFieldLayout.rowSpacing) {
            ImageGenInlineFieldLabel(text: label, width: labelWidth)
            control()
                .frame(maxWidth: .infinity, alignment: .leading)
            accessories()
        }
    }
}

@MainActor
struct ImageGenInlineInfoLine<Content: View>: View {
    let labelWidth: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: ImageGenInlineFieldLayout.rowSpacing) {
            Color.clear
                .frame(width: labelWidth, height: 1)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
struct ImageGenUnifiedIntroRule: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.65))
            .frame(height: 1)
            .padding(.vertical, 8)
    }
}
