import Foundation
import SwiftUI

/// Builds structured layout for the native information pane. Port of `InformationPaneHTMLBuilder` / `information_sidebar.py`.
@MainActor
enum InformationPaneLayoutBuilder {
    static let referenceLinkColorHex = "#3399FF"

    private static let basicInfoFields: Set<String> = [
        "Directory", "Image Size", "File Size", "File Date", "Scale",
    ]

    private static let imageModelSectionTitle = "Image model"
    private static let elapsedInModelPattern = try? NSRegularExpression(
        pattern: "(?i)Elapsed:\\s*(\\d+(?::\\d{2}(?::\\d{2})?)?)(?:\\s*\\(\\d+:\\d{2}:\\d{2}/iter\\))?",
        options: []
    )
    private static let elapsedPerIterSuffixPattern = try? NSRegularExpression(
        pattern: "\\s*\\(\\d+:\\d{2}:\\d{2}/iter\\)",
        options: [.caseInsensitive]
    )
    private static let modelParamLinePattern = try? NSRegularExpression(
        pattern: "^(Seed|Steps|Quantization|Guidance|LoRA|Elapsed)\\s*:\\s*(.*)$",
        options: [.caseInsensitive]
    )
    private static let modelLoraContPattern = try? NSRegularExpression(pattern: "^\\u{00a0}{6}(.+)$", options: [])

    static func buildContent(
        data: InformationOverlayData,
        sectionState: InformationSectionState,
        contentWidth: Int
    ) -> InformationPaneContent {
        let hasExifFields = data.fieldValuePairs.contains { !basicInfoFields.contains($0.0) }
        let filenameSection = InformationFilenameSection(
            title: data.filename,
            sectionKey: "filename",
            expanded: sectionState.sectionExpanded("filename"),
            fieldRows: data.fieldValuePairs.map { InformationFieldRow(label: $0.0, value: $0.1) },
            borderedTable: hasExifFields
        )

        let descriptionSection: InformationDescriptionSection
        if let speakable = data.speakablePlainText, !speakable.isEmpty {
            let blocks = parseDescriptionBlocks(
                text: speakable,
                imageDirectory: data.imageDirectory,
                imagePath: data.imagePath,
                sectionState: sectionState,
                contentWidth: contentWidth
            )
            descriptionSection = InformationDescriptionSection(body: .blocks(blocks))
        } else {
            descriptionSection = InformationDescriptionSection(body: .addUserComment)
        }

        return InformationPaneContent(
            filenameSection: filenameSection,
            descriptionSection: descriptionSection
        )
    }

    // MARK: - Description parsing

    private static func parseDescriptionBlocks(
        text: String,
        imageDirectory: String,
        imagePath: String,
        sectionState: InformationSectionState,
        contentWidth: Int
    ) -> [InformationDescriptionBlock] {
        var normalized = normalizeDescriptionMarkers(text)
        normalized = highlightImageModelElapsed(normalized)
        normalized = applyReferencesMarkup(
            normalized,
            imageDirectory: imageDirectory,
            imagePath: imagePath
        )
        normalized = formatImageModelSectionAsTable(normalized, contentWidth: contentWidth)

        return splitIntoCollapsibleBlocks(normalized, sectionState: sectionState)
    }

    private static func normalizeDescriptionMarkers(_ text: String) -> String {
        var disp = text
        disp = disp.replacingOccurrences(of: "Image Model:\n", with: "##\(imageModelSectionTitle)##\n")
        disp = disp.replacingOccurrences(of: "Prompt:\n", with: "##Prompt##\n")
        disp = disp.replacingOccurrences(of: "Title:\n", with: "##Title##\n")
        disp = disp.replacingOccurrences(of: "Description:\n", with: "##Description##\n")
        disp = disp.replacingOccurrences(of: "References:\n", with: "##References##\n")
        if let regex = try? NSRegularExpression(pattern: "(?i)Negative [Pp]rompt:\\s*\\n", options: []) {
            let range = NSRange(disp.startIndex..., in: disp)
            disp = regex.stringByReplacingMatches(in: disp, range: range, withTemplate: "##Negative prompt##\n")
        }
        return disp
    }

    private static func highlightImageModelElapsed(_ disp: String) -> String {
        let marker = "##\(imageModelSectionTitle)##\n"
        guard let range = disp.range(of: marker) else { return disp }
        let bodyStart = range.upperBound
        let tail = disp[bodyStart...]
        let nextRange = tail.range(of: "\n##", options: [])
        let end = nextRange?.lowerBound ?? disp.endIndex
        let middle = String(disp[bodyStart..<end])
        guard let regex = elapsedInModelPattern else { return disp }
        let nsRange = NSRange(middle.startIndex..., in: middle)
        var replaced = middle
        let matches = regex.matches(in: middle, range: nsRange).reversed()
        for match in matches {
            guard let fullRange = Range(match.range, in: middle),
                  let tokenRange = Range(match.range(at: 1), in: middle) else { continue }
            let token = String(middle[tokenRange])
            let replacement = "Elapsed: **\(InformationFormatting.compactElapsedDisplay(token))**"
            replaced.replaceSubrange(fullRange, with: replacement)
        }
        return String(disp[..<bodyStart]) + replaced + String(disp[end...])
    }

    private static func formatImageModelSectionAsTable(_ disp: String, contentWidth: Int) -> String {
        let marker = "##\(imageModelSectionTitle)##\n"
        guard let range = disp.range(of: marker) else { return disp }
        let bodyStart = range.upperBound
        let tail = disp[bodyStart...]
        let nextRange = tail.range(of: "\n##", options: [])
        let end = nextRange?.lowerBound ?? disp.endIndex
        let middle = String(disp[bodyStart..<end])
        guard !middle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return disp }

        var rows: [InformationModelTableRow] = []
        for line in middle.components(separatedBy: "\n") {
            let seg = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seg.isEmpty else { continue }
            if let match = modelLoraContPattern?.firstMatch(in: seg, range: NSRange(seg.startIndex..., in: seg)),
               let contRange = Range(match.range(at: 1), in: seg) {
                let cont = String(seg[contRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                rows.append(InformationModelTableRow(
                    label: "",
                    value: .plain(cont),
                    elideValue: true,
                    fullWidth: false
                ))
                continue
            }
            if let param = splitImageModelParamLine(seg) {
                rows.append(InformationModelTableRow(
                    label: param.label,
                    value: param.value,
                    elideValue: param.label.lowercased().hasPrefix("lora:"),
                    fullWidth: false
                ))
                continue
            }
            rows.append(InformationModelTableRow(
                label: "",
                value: .plain(seg),
                elideValue: false,
                fullWidth: true
            ))
        }
        guard !rows.isEmpty else { return disp }

        let tableMarker = encodeModelTable(rows, contentWidth: contentWidth)
        return String(disp[..<bodyStart]) + tableMarker + String(disp[end...])
    }

    private static func encodeModelTable(_ rows: [InformationModelTableRow], contentWidth: Int) -> String {
        var lines: [String] = ["@@MODEL_TABLE@@"]
        for row in rows {
            let valueStr = modelValueString(row.value, elide: row.elideValue, contentWidth: contentWidth)
            lines.append("@@ROW@@\(row.label)@@\(valueStr)@@\(row.elideValue)@@\(row.fullWidth)")
        }
        lines.append("@@MODEL_TABLE_END@@")
        return lines.joined(separator: "\n")
    }

    private static func modelValueString(_ value: InformationModelValue, elide: Bool, contentWidth: Int) -> String {
        switch value {
        case .plain(let s):
            let text = elide
                ? InformationFormatting.elideValue(s, maxLen: max(40, contentWidth / 8))
                : s
            return text
        case .bold(let s):
            return "**\(s)**"
        case .copySeed(let s):
            return "@@SEED@@\(s)"
        }
    }

    private static func splitImageModelParamLine(_ segment: String) -> (label: String, value: InformationModelValue)? {
        let plain = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = modelParamLinePattern?.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)),
              let labelRange = Range(match.range(at: 1), in: plain),
              let valueRange = Range(match.range(at: 2), in: plain) else { return nil }
        let label = String(plain[labelRange])
        var valuePlain = String(plain[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        if label.lowercased() == "elapsed" {
            if let suffix = elapsedPerIterSuffixPattern {
                let range = NSRange(valuePlain.startIndex..., in: valuePlain)
                valuePlain = suffix.stringByReplacingMatches(in: valuePlain, range: range, withTemplate: "")
            }
            valuePlain = valuePlain.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let compact = InformationFormatting.compactElapsedDisplay(valuePlain)
            let wasBold = segment.contains("**")
            return ("\(label):", wasBold ? .bold(compact) : .plain(compact))
        }
        if label.lowercased() == "seed" {
            let seedPlain = valuePlain.replacingOccurrences(of: "**", with: "")
            return ("\(label):", .copySeed(seedPlain))
        }
        return ("\(label):", .plain(valuePlain))
    }

    private static func applyReferencesMarkup(_ disp: String, imageDirectory: String, imagePath: String) -> String {
        let key = "##References##\n"
        guard let pos = disp.range(of: key) else { return disp }
        let bodyStart = pos.upperBound
        let tail = disp[bodyStart...]
        let nextRange = tail.range(of: "\n##", options: [])
        let end = nextRange?.lowerBound ?? disp.endIndex
        let middle = String(disp[bodyStart..<end])
        let entries = ReferenceGraphService.parseReferenceEntries(from: "References:\n\(middle)")
        guard !entries.isEmpty else { return disp }
        let (levelPaths, _, _) = ReferenceGraphService.resolveExifReferencePaths(
            imageDir: imageDirectory,
            currentPath: imagePath,
            entries: entries
        )
        let referenceLinksEnabled = levelPaths.count > 1
        let segments = middle.components(separatedBy: "\n")
        var newLines: [String] = []
        var index = 0
        while index < segments.count {
            let segment = segments[index]
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                newLines.append(segment)
                index += 1
                continue
            }
            if index + 1 < segments.count {
                let next = segments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if ReferenceGraphService.isReferenceFileDateLine(next) {
                    let fnameRaw = trimmed
                    let showLink = referenceLinksEnabled
                        && ReferenceGraphService.resolveReferencePath(
                            imageDir: imageDirectory,
                            label: fnameRaw,
                            expectedMtime: nil
                        ) != nil
                    if showLink {
                        newLines.append("@@REF@@\(trimmed)")
                    } else {
                        newLines.append(segment)
                    }
                    index += 2
                    continue
                }
            }
            let fnameRaw = trimmed
            let showLink = referenceLinksEnabled
                && ReferenceGraphService.resolveReferencePath(
                    imageDir: imageDirectory,
                    label: fnameRaw,
                    expectedMtime: nil
                ) != nil
            if showLink {
                newLines.append("@@REF@@\(trimmed)")
            } else {
                newLines.append(segment)
            }
            index += 1
        }
        return String(disp[..<bodyStart]) + newLines.joined(separator: "\n") + String(disp[end...])
    }

    private static func splitIntoCollapsibleBlocks(
        _ disp: String,
        sectionState: InformationSectionState
    ) -> [InformationDescriptionBlock] {
        let h4Pattern = try? NSRegularExpression(pattern: "##([^#]+)##\\n", options: [.caseInsensitive])
        let nsRange = NSRange(disp.startIndex..., in: disp)
        let matches = h4Pattern?.matches(in: disp, range: nsRange) ?? []
        guard !matches.isEmpty else {
            let trimmed = disp.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [staticBlock(title: "", parts: [.plainText(disp)])]
        }

        var blocks: [InformationDescriptionBlock] = []
        var cursor = disp.startIndex
        for match in matches {
            guard let fullRange = Range(match.range, in: disp),
                  let titleRange = Range(match.range(at: 1), in: disp) else { continue }
            if fullRange.lowerBound > cursor {
                let preamble = String(disp[cursor..<fullRange.lowerBound])
                if !preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(staticBlock(title: "", parts: [.plainText(preamble)]))
                }
            }
            let title = String(disp[titleRange])
            let bodyStart = fullRange.upperBound
            let nextMatchIndex = matches.firstIndex(where: { $0.range.lowerBound > match.range.lowerBound })
            let bodyEnd = nextMatchIndex.flatMap { Range(matches[$0].range, in: disp)?.lowerBound } ?? disp.endIndex
            let body = String(disp[bodyStart..<bodyEnd])
            let sectionKey = InformationSectionState.sectionKey(fromH4Title: title)
            if let sectionKey {
                let expanded = sectionState.sectionExpanded(sectionKey)
                blocks.append(InformationDescriptionBlock(
                    sectionKey: sectionKey,
                    title: title,
                    expanded: expanded,
                    parts: expanded ? decodeBodyParts(body) : []
                ))
            } else {
                blocks.append(InformationDescriptionBlock(
                    sectionKey: nil,
                    title: title,
                    expanded: true,
                    parts: decodeBodyParts(body)
                ))
            }
            cursor = bodyEnd
        }
        if cursor < disp.endIndex {
            let tail = String(disp[cursor...])
            if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(staticBlock(title: "", parts: [.plainText(tail)]))
            }
        }
        return blocks
    }

    private static func staticBlock(title: String, parts: [InformationDescriptionPart]) -> InformationDescriptionBlock {
        InformationDescriptionBlock(sectionKey: nil, title: title, expanded: true, parts: parts)
    }

    private static func decodeBodyParts(_ body: String) -> [InformationDescriptionPart] {
        var parts: [InformationDescriptionPart] = []
        var remaining = body
        while let tableStart = remaining.range(of: "@@MODEL_TABLE@@") {
            let before = String(remaining[..<tableStart.lowerBound])
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(.plainText(before))
            }
            guard let tableEnd = remaining.range(of: "@@MODEL_TABLE_END@@", range: tableStart.upperBound..<remaining.endIndex) else {
                parts.append(.plainText(remaining))
                return parts
            }
            let tableBody = String(remaining[tableStart.upperBound..<tableEnd.lowerBound])
            parts.append(.modelTable(decodeModelTable(tableBody)))
            remaining = String(remaining[tableEnd.upperBound...])
        }
        if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(.plainText(remaining))
        }
        return parts
    }

    private static func decodeModelTable(_ tableBody: String) -> [InformationModelTableRow] {
        var rows: [InformationModelTableRow] = []
        for line in tableBody.components(separatedBy: "\n") {
            guard line.hasPrefix("@@ROW@@") else { continue }
            let payload = String(line.dropFirst("@@ROW@@".count))
            guard let fullWidthSep = payload.range(of: "@@", options: .backwards),
                  let elideSep = payload[..<fullWidthSep.lowerBound].range(of: "@@", options: .backwards),
                  let labelSep = payload[..<elideSep.lowerBound].range(of: "@@") else { continue }
            let label = String(payload[..<labelSep.lowerBound])
            let valueStr = String(payload[labelSep.upperBound..<elideSep.lowerBound])
            let elide = String(payload[elideSep.upperBound..<fullWidthSep.lowerBound]) == "true"
            let fullWidth = String(payload[fullWidthSep.upperBound...]) == "true"
            let value: InformationModelValue
            if valueStr.hasPrefix("@@SEED@@") {
                value = .copySeed(String(valueStr.dropFirst("@@SEED@@".count)))
            } else if valueStr.hasPrefix("**"), valueStr.hasSuffix("**"), valueStr.count > 4 {
                value = .bold(String(valueStr.dropFirst(2).dropLast(2)))
            } else {
                value = .plain(valueStr)
            }
            rows.append(InformationModelTableRow(
                label: label,
                value: value,
                elideValue: elide,
                fullWidth: fullWidth
            ))
        }
        return rows
    }

    /// Parse reference / plain spans from a text chunk for rendering.
    static func referenceSpans(from text: String) -> [InformationReferenceSpan] {
        var spans: [InformationReferenceSpan] = []
        var remaining = text
        while let refRange = remaining.range(of: "@@REF@@") {
            let before = String(remaining[..<refRange.lowerBound])
            if !before.isEmpty {
                spans.append(InformationReferenceSpan(text: before, isReferenceLink: false))
            }
            let afterRef = remaining[refRange.upperBound...]
            if let lineEnd = afterRef.firstIndex(of: "\n") {
                let linkText = String(afterRef[..<lineEnd])
                spans.append(InformationReferenceSpan(text: linkText, isReferenceLink: true))
                remaining = String(afterRef[lineEnd...])
                if remaining.hasPrefix("\n") {
                    remaining = String(remaining.dropFirst())
                }
            } else {
                spans.append(InformationReferenceSpan(text: String(afterRef), isReferenceLink: true))
                remaining = ""
            }
        }
        if !remaining.isEmpty {
            spans.append(InformationReferenceSpan(text: remaining, isReferenceLink: false))
        }
        return spans.isEmpty ? [InformationReferenceSpan(text: text, isReferenceLink: false)] : spans
    }
}
