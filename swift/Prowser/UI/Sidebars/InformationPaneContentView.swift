import SwiftUI

@MainActor
struct InformationPaneContentView: View {
    @Environment(\.informationPaneScrollCoordinator) private var scrollCoordinator

    let content: InformationPaneContent
    /// Live active-job label (not tied to EXIF / metadata rebuild).
    let activeJobHeading: String?
    let colors: ThemeColors
    let onToggleSection: (String, Bool) -> Void
    let onCopySeed: (String) -> Void
    let onReferenceLevel: (Bool) -> Void
    let onEditUserComment: () -> Void

    private let bodyFontSize: CGFloat = 10
    private let filenameHeaderFontSize: CGFloat = 11
    private let sectionHeaderFontSize: CGFloat = 10
    private let contentPaddingH: CGFloat = 18
    private let contentPaddingV: CGFloat = 15
    private static var referenceLinkColor: Color {
        Color(hex: InformationPaneLayoutBuilder.referenceLinkColorHex) ?? Color(red: 51 / 255, green: 153 / 255, blue: 1)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    InformationPaneScrollViewAttachment()
                        .frame(width: 0, height: 0)

                    filenameBlock(content.filenameSection)

                    descriptionBlock(content.descriptionSection)
                }
                .padding(.horizontal, contentPaddingH)
                .padding(.vertical, contentPaddingV)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(colors.sidebarBackground)

            if let heading = activeJobHeading, !heading.isEmpty {
                activeJobHeadingOverlay(heading)
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Painted above the scroll surface; does not participate in scroll content layout.
    private func activeJobHeadingOverlay(_ heading: String) -> some View {
        Text(heading)
            .font(.system(size: sectionHeaderFontSize, weight: .semibold))
            .foregroundStyle(colors.sidebarEmphasizedText)
            .padding(.leading, contentPaddingH)
            .padding(.trailing, contentPaddingH + scrollCoordinator.verticalScrollbarReserve)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.sidebarBackground)
            .fixedSize(horizontal: false, vertical: true)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func filenameBlock(_ section: InformationFilenameSection) -> some View {
        collapsibleHeader(
            sectionKey: section.sectionKey,
            title: section.title,
            expanded: section.expanded,
            fontSize: filenameHeaderFontSize,
            headingColor: colors.sidebarHeaderText,
            bottomSpacing: section.expanded ? 12 : 4
        )
        if section.expanded, !section.fieldRows.isEmpty {
            fieldTable(rows: section.fieldRows, bordered: section.borderedTable)
        }
        if section.expanded {
            filenameSectionSeparator
        }
    }

    private var filenameSectionSeparator: some View {
        Rectangle()
            .fill(colors.sidebarMutedText)
            .frame(height: 1)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    @ViewBuilder
    private func descriptionBlock(_ section: InformationDescriptionSection) -> some View {
        switch section.body {
        case .addUserComment:
            Button(action: onEditUserComment) {
                Text("Add user comment")
                    .font(monospaceFont(bodyFontSize))
                    .foregroundStyle(colors.currentImageBorder)
                    .underline()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .padding(.top, bodyFontSize + 4)
            .help("Edit EXIF user comment (⇧⌘E)")
        case .blocks(let blocks):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    descriptionBlockItem(block)
                }
            }
        }
    }

    @ViewBuilder
    private func descriptionBlockItem(_ block: InformationDescriptionBlock) -> some View {
        if let sectionKey = block.sectionKey {
            collapsibleHeader(
                sectionKey: sectionKey,
                title: block.title,
                expanded: block.expanded,
                fontSize: sectionHeaderFontSize,
                headingColor: colors.sidebarHeaderText,
                bottomSpacing: block.expanded ? 6 : 2
            )
            if block.expanded {
                descriptionParts(block.parts)
            }
        } else if !block.title.isEmpty {
            Text(block.title)
                .font(monospaceFont(sectionHeaderFontSize).weight(.bold))
                .foregroundStyle(colors.sidebarHeaderText)
                .padding(.bottom, 4)
            descriptionParts(block.parts)
        } else {
            descriptionParts(block.parts)
        }
    }

    @ViewBuilder
    private func descriptionParts(_ parts: [InformationDescriptionPart]) -> some View {
        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
            switch part {
            case .plainText(let text):
                plainDescriptionText(text)
            case .modelTable(let rows):
                modelTable(rows: rows)
            }
        }
    }

    @ViewBuilder
    private func plainDescriptionText(_ text: String) -> some View {
        let spans = InformationPaneLayoutBuilder.referenceSpans(from: text)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                if span.isReferenceLink {
                    Button {
                        let optionHeld = NSEvent.modifierFlags.contains(.option)
                        onReferenceLevel(optionHeld)
                    } label: {
                        InformationPaneHoverUnderlineLabel(
                            text: span.text,
                            font: monospaceFont(bodyFontSize),
                            color: Self.referenceLinkColor
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                } else if !span.text.isEmpty {
                    referencePlainTextBlock(span.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func referencePlainTextBlock(_ text: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            if let attributed = boldMarkedLine(line), !attributed.characters.isEmpty {
                Text(attributed)
                    .font(monospaceFont(bodyFontSize))
                    .foregroundStyle(colors.sidebarText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !line.isEmpty {
                Text(line)
                    .font(monospaceFont(bodyFontSize))
                    .foregroundStyle(colors.sidebarText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func boldMarkedLine(_ line: String) -> AttributedString? {
        guard line.contains("**") else {
            let plain = AttributedString(line)
            return plain.characters.isEmpty ? nil : plain
        }
        var result = AttributedString()
        var remaining = line
        while let open = remaining.range(of: "**") {
            let before = String(remaining[..<open.lowerBound])
            if !before.isEmpty {
                result.append(AttributedString(before))
            }
            remaining = String(remaining[open.upperBound...])
            guard let close = remaining.range(of: "**") else {
                result.append(AttributedString("**" + remaining))
                break
            }
            let boldText = String(remaining[..<close.lowerBound])
            var bold = AttributedString(boldText)
            bold.inlinePresentationIntent = .stronglyEmphasized
            result.append(bold)
            remaining = String(remaining[close.upperBound...])
        }
        if !remaining.isEmpty {
            result.append(AttributedString(remaining))
        }
        return result.characters.isEmpty ? nil : result
    }

    @ViewBuilder
    private func fieldTable(rows: [InformationFieldRow], bordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: bordered ? 0 : 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if bordered {
                    HStack(alignment: .top, spacing: 0) {
                        Text("\(row.label):")
                            .font(monospaceFont(bodyFontSize))
                            .foregroundStyle(colors.sidebarText)
                            .frame(minWidth: 72, alignment: .trailing)
                            .padding(.vertical, 4)
                            .padding(.leading, 2)
                            .padding(.trailing, 4)
                            .overlay(Rectangle().stroke(colors.sidebarMutedText, lineWidth: 1))
                        fieldValueView(label: row.label, value: row.value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .overlay(Rectangle().stroke(colors.sidebarMutedText, lineWidth: 1))
                    }
                } else {
                    HStack(alignment: .top, spacing: 4) {
                        Text("\(row.label):")
                            .font(monospaceFont(bodyFontSize))
                            .foregroundStyle(colors.sidebarText)
                            .fixedSize(horizontal: true, vertical: false)
                        fieldValueView(label: row.label, value: row.value)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modelTable(rows: [InformationModelTableRow]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if row.fullWidth {
                    Text(modelValueText(row.value))
                        .font(monospaceFont(bodyFontSize))
                        .foregroundStyle(modelValueForeground(row.value, fullWidth: true))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if row.label.isEmpty, row.elideValue {
                    Text(modelValueText(row.value))
                        .font(monospaceFont(bodyFontSize))
                        .foregroundStyle(colors.sidebarEmphasizedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(alignment: .top, spacing: 4) {
                        Text(row.label)
                            .font(monospaceFont(bodyFontSize))
                            .foregroundStyle(colors.sidebarText)
                            .fixedSize(horizontal: true, vertical: false)
                        modelValueView(
                            row.value,
                            emphasizedPlain: row.label.lowercased().hasPrefix("lora:")
                        )
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func modelValueView(_ value: InformationModelValue, emphasizedPlain: Bool = false) -> some View {
        switch value {
        case .copySeed(let seed):
            Button {
                onCopySeed(seed)
            } label: {
                InformationPaneHoverUnderlineLabel(
                    text: seed,
                    font: monospaceFont(bodyFontSize),
                    color: colors.sidebarEmphasizedText
                )
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        case .bold(let text):
            Text(text)
                .font(monospaceFont(bodyFontSize).weight(.bold))
                .foregroundStyle(colors.sidebarEmphasizedText)
        case .plain(let text):
            Text(text)
                .font(monospaceFont(bodyFontSize))
                .foregroundStyle(emphasizedPlain ? colors.sidebarEmphasizedText : colors.sidebarText)
        }
    }

    private func modelValueText(_ value: InformationModelValue) -> String {
        switch value {
        case .plain(let s), .copySeed(let s): return s
        case .bold(let s): return s
        }
    }

    private func collapsibleHeader(
        sectionKey: String,
        title: String,
        expanded: Bool,
        fontSize: CGFloat,
        headingColor: Color,
        bottomSpacing: CGFloat
    ) -> some View {
        let indicator = expanded ? "▼" : "▶"
        return Button {
            let expandAll = NSEvent.modifierFlags.contains(.option)
            onToggleSection(sectionKey, expandAll)
        } label: {
            HStack(spacing: 4) {
                Text("\(indicator) \(title)")
                    .font(monospaceFont(fontSize).weight(.bold))
                    .foregroundStyle(headingColor)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, bottomSpacing)
    }

    private func monospaceFont(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }

    @ViewBuilder
    private func fieldValueView(label: String, value: String) -> some View {
        if label == "Image Size" {
            if let newline = value.firstIndex(of: "\n") {
                let dimensions = String(value[..<newline])
                let area = String(value[value.index(after: newline)...])
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    Text(dimensions)
                        .font(monospaceFont(bodyFontSize))
                        .foregroundStyle(colors.sidebarEmphasizedText)
                    if !area.isEmpty {
                        Text(area)
                            .font(monospaceFont(bodyFontSize))
                            .foregroundStyle(colors.sidebarText)
                    }
                }
            } else {
                Text(value)
                    .font(monospaceFont(bodyFontSize))
                    .foregroundStyle(colors.sidebarEmphasizedText)
            }
        } else {
            Text(value)
                .font(monospaceFont(bodyFontSize))
                .foregroundStyle(colors.sidebarText)
        }
    }

    private func modelValueForeground(_ value: InformationModelValue, fullWidth: Bool) -> Color {
        if fullWidth, case .plain = value {
            return colors.sidebarEmphasizedText
        }
        return colors.sidebarText
    }
}

/// Underline on hover (Python information pane seed / reference link hover).
private struct InformationPaneHoverUnderlineLabel: View {
    let text: String
    let font: Font
    let color: Color
    @State private var hovered = false

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .underline(hovered)
            .onHover { hovered = $0 }
    }
}
