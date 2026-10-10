import AppKit
import SwiftUI

struct ThemeColorSwatchRow: View {
    let label: String
    let hex: String
    var width: Int?
    var widthRange: ClosedRange<Int> = 0...10
    var widthTooltip: String?
    let onColorChange: (String) -> Void
    var onWidthChange: ((Int) -> Void)?

    @State private var swatchHex: String

    init(
        label: String,
        hex: String,
        width: Int? = nil,
        widthRange: ClosedRange<Int> = 0...10,
        widthTooltip: String? = nil,
        onColorChange: @escaping (String) -> Void,
        onWidthChange: ((Int) -> Void)? = nil
    ) {
        self.label = label
        self.hex = hex
        self.width = width
        self.widthRange = widthRange
        self.widthTooltip = widthTooltip
        self.onColorChange = onColorChange
        self.onWidthChange = onWidthChange
        _swatchHex = State(initialValue: hex)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if !label.isEmpty {
                Text(label)
                    .frame(minWidth: 200, alignment: .leading)
            }
            Spacer(minLength: 8)
            Button {
                ThemeColorPanelController.shared.pickColor(
                    hex: swatchHex,
                    onSwatchChange: { swatchHex = $0 },
                    onThemeChange: onColorChange
                )
            } label: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: swatchHex) ?? .gray)
                    .frame(width: 28, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Click to choose color")

            if let width, let onWidthChange {
                HStack(spacing: 8) {
                    AppMiniSlider(
                        value: Binding(
                            get: { Double(width) },
                            set: { onWidthChange(Int($0.rounded())) }
                        ),
                        in: Double(widthRange.lowerBound)...Double(widthRange.upperBound),
                        step: 1
                    )
                    .frame(width: 120)
                    Text("\(width) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                .help(widthTooltip ?? "Border width")
            }
        }
        .onChange(of: hex) { _, newValue in
            swatchHex = newValue
        }
    }
}

struct ThemeMutedBlendRow: View {
    let label: String
    let percent: Int
    let previewHex: String
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(minWidth: 200, alignment: .leading)
            Spacer(minLength: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: previewHex) ?? .gray)
                .frame(width: 28, height: 28)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.4)))
            AppMiniSlider(
                value: Binding(
                    get: { Double(percent) },
                    set: { onChange(Int($0.rounded())) }
                ),
                in: 0...100,
                step: 1
            )
            .frame(width: 140)
            Text("\(percent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

struct ThemeBorderWidthRow: View {
    let label: String
    let width: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(minWidth: 200, alignment: .leading)
            Spacer(minLength: 8)
            AppMiniSlider(
                value: Binding(
                    get: { Double(width) },
                    set: { onChange(Int($0.rounded())) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .frame(width: 180)
            Text("\(width) px")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}
