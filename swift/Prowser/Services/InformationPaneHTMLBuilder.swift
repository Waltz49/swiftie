import AppKit
import Foundation
import SwiftUI

struct InformationOverlayData {
    var filename: String
    var fieldValuePairs: [(String, String)]
    var speakablePlainText: String?
    var imageDirectory: String = ""
    var imagePath: String = ""
}

/// Builds HTML for the information pane. Port of `information_sidebar.py` `_build_info_overlay_html`.
@MainActor
enum InformationPaneHTMLBuilder {
    /// Slightly smaller than Python Qt (12pt) for the narrow sidebar pane.
    private static let bodyFontSize = "9pt"
    private static let filenameHeaderFontSize = "10pt"
    private static let sectionHeaderFontSize = "9pt"
    private static let fontFamily = "'Courier New', Monaco, Menlo, monospace"

    private static var bodyFontCSS: String {
        "font-size: \(bodyFontSize); font-family: \(fontFamily);"
    }

    private static func globalStyles(textHex: String, backgroundHex: String) -> String {
        """
        html { -webkit-text-size-adjust: none; text-size-adjust: none; }
        body { margin: 0; padding: 15px 18px; color: \(textHex); background-color: \(backgroundHex); \(bodyFontCSS) line-height: 1.4; }
        table, td, th, tr, div, p, span, a, b { \(bodyFontCSS) -webkit-text-size-adjust: none; }
        h4 { \(bodyFontCSS) font-weight: bold; margin: 0 0 4px 0; font-size: \(sectionHeaderFontSize); }
        a { cursor: pointer; color: inherit; }
        """
    }

    private static let basicInfoFields: Set<String> = [
        "Directory", "Image Size", "File Size", "File Date", "Scale",
    ]
    private static let priorityExifFields = ["Camera", "Orientation", "Lens", "Location"]
    private static let imageModelH4 = "<h4>Image model</h4>"
    private static let h4Pattern = try? NSRegularExpression(pattern: "<h4>([^<]+)</h4>", options: [.caseInsensitive])
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

    static func buildOverlayData(
        from record: ExifRecord,
        imageDirectory: String,
        imagePath: String
    ) -> InformationOverlayData {
        var pairs: [(String, String)] = []

        let directory = InformationFormatting.normalizePathForDisplay(record.directory)
        if !directory.isEmpty {
            let escaped = InformationFormatting.escapeHTML(InformationFormatting.elideValue(directory))
            pairs.append(("Directory", escaped))
        }

        if !record.imageSize.isEmpty {
            pairs.append(("Image Size", InformationFormatting.escapeHTML(record.imageSize)))
        }

        if !record.fileSize.isEmpty, !InformationFormatting.isZeroValue(record.fileSize) {
            pairs.append(("File Size", InformationFormatting.escapeHTML(record.fileSize)))
        }

        if !record.fileDate.isEmpty {
            pairs.append(("File Date", InformationFormatting.escapeHTML(record.fileDate)))
        }

        if let exifDate = record.exifDate, !exifDate.isEmpty {
            pairs.append(("EXIF Date", InformationFormatting.escapeHTML(exifDate)))
        }

        for field in priorityExifFields {
            let value = priorityValue(field, record: record)
            if let value, !InformationFormatting.isZeroValue(value) {
                pairs.append((field, InformationFormatting.escapeHTML(InformationFormatting.elideValue(value))))
            }
        }

        var speakablePlainText: String?
        if let description = record.description?.replacingOccurrences(of: "\u{0000}", with: ""),
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("b'"),
           !description.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("b\"") {
            speakablePlainText = description.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let remaining = remainingFieldPairs(from: record)
        pairs.append(contentsOf: remaining)

        return InformationOverlayData(
            filename: record.fileName,
            fieldValuePairs: pairs,
            speakablePlainText: speakablePlainText,
            imageDirectory: imageDirectory,
            imagePath: imagePath
        )
    }

    static func buildHTML(
        data: InformationOverlayData,
        colors: ThemeColors,
        sectionState: InformationSectionState,
        activeJobHeading: String?,
        contentWidth: Int = 250,
        hoveredAnchor: String? = nil
    ) -> String {
        let textHex = colorHex(colors.sidebarText)
        let borderHex = colorHex(colors.sidebarMutedText)
        let backgroundHex = colorHex(colors.sidebarBackground)
        let accentHex = colorHex(colors.sidebarHeaderText)
        var parts: [String] = [
            "<html><head><meta charset=\"utf-8\"><style>",
            globalStyles(textHex: textHex, backgroundHex: backgroundHex),
            "</style></head><body>",
            "<div style=\"color: \(textHex); \(bodyFontCSS) line-height: 1.4;\">",
        ]

        let filenameExpanded = sectionState.sectionExpanded("filename")
        parts.append(collapsibleHeader(
            sectionKey: "filename",
            title: InformationFormatting.escapeHTML(data.filename),
            expanded: filenameExpanded,
            fontSize: filenameHeaderFontSize,
            headingHex: colorHex(colors.sidebarHeaderText),
            marginBottom: nil
        ))

        if filenameExpanded, !data.fieldValuePairs.isEmpty {
            let hasExifFields = data.fieldValuePairs.contains { !basicInfoFields.contains($0.0) }
            parts.append(buildFieldTable(
                pairs: data.fieldValuePairs,
                textHex: textHex,
                borderHex: borderHex,
                bordered: hasExifFields
            ))
        }

        var descriptionVisible = true
        if let activeJobHeading {
            let activeBorder = colorHex(colors.currentImageBorder)
            let activeBorderWidth = max(1, colors.currentImageBorderWidth)
            let sectionKey = activeJobHeading == "Output of Active Job" ? "output_of_active_job" : "input_to_active_job"
            let jobExpanded = sectionState.sectionExpanded(sectionKey)
            descriptionVisible = jobExpanded
            parts.append(
                "<div style=\"margin-top: 12px; padding-top: 10px; padding-bottom: 4px; "
                + "border-top: \(activeBorderWidth)px solid \(activeBorder);\">"
            )
            parts.append(collapsibleHeader(
                sectionKey: sectionKey,
                title: activeJobHeading,
                expanded: jobExpanded,
                fontSize: sectionHeaderFontSize,
                headingHex: activeBorder,
                marginBottom: jobExpanded ? "6px" : "2px"
            ))
            parts.append("</div>")
        }

        if descriptionVisible {
            parts.append(
                "<div style=\"padding-top: 10px; padding-bottom: 6px; margin-top: 10px; "
                + "border-top: 1px solid \(borderHex); color: \(textHex); font-size: \(bodyFontSize);\">"
            )
            if let speakable = data.speakablePlainText,
               !speakable.isEmpty,
               let descriptionHTML = descriptionHTML(
                from: speakable,
                imageDirectory: data.imageDirectory,
                imagePath: data.imagePath,
                accentHex: accentHex,
                textHex: textHex,
                contentWidth: contentWidth
               ) {
                let wrapped = wrapDescriptionWithCollapsibleSections(
                    descriptionHTML,
                    sectionState: sectionState,
                    headingHex: colorHex(colors.sidebarHeaderText)
                )
                parts.append(wrapped)
            } else {
                parts.append("Add user comment")
            }
            parts.append("</div>")
        }

        parts.append("</div></body></html>")
        return parts.joined()
    }

    // MARK: - Field pairs

    private static func priorityValue(_ field: String, record: ExifRecord) -> String? {
        switch field {
        case "Camera": return record.camera
        case "Orientation": return record.orientation
        case "Lens": return record.lens
        case "Location": return record.location
        default: return nil
        }
    }

    private static func remainingFieldPairs(from record: ExifRecord) -> [(String, String)] {
        var extras: [(String, String)] = []
        let named: [(String, String?)] = [
            ("Exposure", record.exposure),
            ("Aperture", record.aperture),
            ("ISO", record.iso),
            ("Focal Length", record.focalLength),
            ("Software", record.software),
            ("Artist", record.artist),
        ]
        for (field, value) in named {
            guard let value, !InformationFormatting.isZeroValue(value) else { continue }
            extras.append((field, InformationFormatting.escapeHTML(InformationFormatting.elideValue(value))))
        }
        for (field, value) in record.extraFields.sorted(by: { $0.0 < $1.0 }) {
            guard !InformationFormatting.isZeroValue(value) else { continue }
            extras.append((field, InformationFormatting.escapeHTML(InformationFormatting.elideValue(value))))
        }
        return extras
    }

    // MARK: - Description markup

    private static func descriptionHTML(
        from text: String,
        imageDirectory: String,
        imagePath: String,
        accentHex: String,
        textHex: String,
        contentWidth: Int
    ) -> String? {
        var disp = InformationFormatting.escapeHTML(text)
        disp = disp.replacingOccurrences(of: "\n", with: "<br>")
        disp = disp.replacingOccurrences(of: "Image Model:<br>", with: imageModelH4)
        disp = disp.replacingOccurrences(of: "Prompt:<br>", with: "<h4>Prompt</h4>")
        disp = disp.replacingOccurrences(of: "Title:<br>", with: "<h4>Title</h4>")
        disp = disp.replacingOccurrences(of: "Description:<br>", with: "<h4>Description</h4>")
        if let regex = try? NSRegularExpression(pattern: "(?i)(^|<br>)References:\\s*<br>", options: []) {
            let range = NSRange(disp.startIndex..., in: disp)
            disp = regex.stringByReplacingMatches(in: disp, range: range, withTemplate: "$1<h4>References</h4>")
        }
        if let regex = try? NSRegularExpression(pattern: "(?i)(^|<br>)Negative [Pp]rompt:\\s*<br>", options: []) {
            let range = NSRange(disp.startIndex..., in: disp)
            disp = regex.stringByReplacingMatches(in: disp, range: range, withTemplate: "$1<h4>Negative prompt</h4>")
        }
        disp = highlightImageModelElapsedHTML(disp)
        disp = applyReferencesMarkup(disp, imageDirectory: imageDirectory, imagePath: imagePath, accentHex: accentHex)
        disp = formatImageModelSectionAsTable(disp, textHex: textHex, contentWidth: contentWidth, hoveredAnchor: nil)
        return disp
    }

    private static func highlightImageModelElapsedHTML(_ disp: String) -> String {
        guard let range = disp.range(of: imageModelH4) else { return disp }
        let bodyStart = range.upperBound
        let tail = disp[bodyStart...]
        let nextRange = tail.range(of: "<h4>", options: .caseInsensitive)
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
            let replacement = "Elapsed: <b>\(InformationFormatting.compactElapsedDisplay(token))</b>"
            replaced.replaceSubrange(fullRange, with: replacement)
        }
        return String(disp[..<bodyStart]) + replaced + String(disp[end...])
    }

    private static func formatImageModelSectionAsTable(
        _ disp: String,
        textHex: String,
        contentWidth: Int,
        hoveredAnchor: String?
    ) -> String {
        guard let range = disp.range(of: imageModelH4) else { return disp }
        let bodyStart = range.upperBound
        let tail = disp[bodyStart...]
        let nextRange = tail.range(of: "<h4>", options: .caseInsensitive)
        let end = nextRange?.lowerBound ?? disp.endIndex
        let middle = String(disp[bodyStart..<end])
        guard !middle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return disp }

        var rows: [(String, String, Bool)] = []
        for segment in middle.components(separatedBy: "<br>") {
            let seg = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seg.isEmpty else { continue }
            let plain = unescapeHTML(seg)
            if let match = modelLoraContPattern?.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)),
               let contRange = Range(match.range(at: 1), in: plain) {
                rows.append(("", InformationFormatting.escapeHTML(String(plain[contRange]).trimmingCharacters(in: .whitespacesAndNewlines)), true))
                continue
            }
            if let param = splitImageModelParamLineHTML(seg) {
                var value = param.value
                if param.label.lowercased().hasPrefix("seed:") {
                    value = seedValueCopyLinkHTML(value, textHex: textHex, hoveredAnchor: hoveredAnchor)
                }
                rows.append((param.label, value, param.label.lowercased().hasPrefix("lora:")))
                continue
            }
            rows.append(("", seg, false))
        }
        guard !rows.isEmpty else { return disp }

        let table = buildModelTable(rows: rows, textHex: textHex, contentWidth: contentWidth)
        return String(disp[..<bodyStart]) + table + String(disp[end...])
    }

    private static func splitImageModelParamLineHTML(_ segment: String) -> (label: String, value: String)? {
        let plain = unescapeHTML(segment).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = modelParamLinePattern?.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)),
              let labelRange = Range(match.range(at: 1), in: plain),
              let valueRange = Range(match.range(at: 2), in: plain) else { return nil }
        let label = String(plain[labelRange])
        var valueHTML = String(segment.trimmingCharacters(in: .whitespacesAndNewlines))
        if let prefix = try? NSRegularExpression(pattern: "^\(label)\\s*:\\s*", options: [.caseInsensitive]),
           let prefixMatch = prefix.firstMatch(in: valueHTML, range: NSRange(valueHTML.startIndex..., in: valueHTML)),
           let prefixRange = Range(prefixMatch.range, in: valueHTML) {
            valueHTML = String(valueHTML[prefixRange.upperBound...])
        } else {
            valueHTML = InformationFormatting.escapeHTML(String(plain[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if label.lowercased() == "elapsed" {
            if let suffix = elapsedPerIterSuffixPattern {
                let range = NSRange(valueHTML.startIndex..., in: valueHTML)
                valueHTML = suffix.stringByReplacingMatches(in: valueHTML, range: range, withTemplate: "")
            }
            let plainValue = unescapeHTML(stripHTML(valueHTML)).trimmingCharacters(in: .whitespacesAndNewlines)
            let compact = InformationFormatting.compactElapsedDisplay(plainValue)
            valueHTML = valueHTML.range(of: "<b>", options: .caseInsensitive) != nil
                ? "<b>\(InformationFormatting.escapeHTML(compact))</b>"
                : InformationFormatting.escapeHTML(compact)
        }
        return ("\(label):", valueHTML)
    }

    private static func seedValueCopyLinkHTML(_ valueHTML: String, textHex: String, hoveredAnchor: String?) -> String {
        let plain = unescapeHTML(stripHTML(valueHTML)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return valueHTML }
        let encoded = plain.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? plain
        let href = "copyseed:///\(encoded)"
        let hovered = hoveredAnchor == href
        let style = hovered
            ? "color:\(textHex);text-decoration:underline;font-weight:bold;"
            : "color:\(textHex);text-decoration:none;font-weight:normal;"
        let display = valueHTML.range(of: "<b>", options: .caseInsensitive) != nil ? valueHTML : valueHTML
        return "<a href=\"\(href)\" style=\"\(style)\">\(display)</a>"
    }

    private static func applyReferencesMarkup(_ disp: String, imageDirectory: String, imagePath: String, accentHex: String) -> String {
        let key = "<h4>References</h4>"
        guard let pos = disp.range(of: key) else { return disp }
        let bodyStart = pos.upperBound
        let tail = disp[bodyStart...]
        let nextRange = tail.range(of: "<h4>", options: .caseInsensitive)
        let end = nextRange?.lowerBound ?? disp.endIndex
        let middle = String(disp[bodyStart..<end])
        let segments = middle.components(separatedBy: "<br>")
        let plainMiddle = stripHTML(middle.replacingOccurrences(of: "<br>", with: "\n"))
        let entries = ReferenceGraphService.parseReferenceEntries(from: "References:\n\(plainMiddle)")
        guard !entries.isEmpty else { return disp }
        let (levelPaths, _, _) = ReferenceGraphService.resolveExifReferencePaths(
            imageDir: imageDirectory,
            currentPath: imagePath,
            entries: entries
        )
        guard levelPaths.count > 1 else { return disp }

        var newSegments: [String] = []
        var index = 0
        while index < segments.count {
            let segment = segments[index]
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                newSegments.append(segment)
                index += 1
                continue
            }
            if index + 1 < segments.count {
                let next = segments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if next.range(of: "^\\d+(?:\\.\\d+)?$", options: .regularExpression) != nil {
                    let label = unescapeHTML(trimmed)
                    if ReferenceGraphService.resolveReferencePath(imageDir: imageDirectory, label: label) != nil {
                        newSegments.append(
                            "<a href=\"reflevel://\" style=\"color:\(accentHex);text-decoration:underline;\">\(segment)</a>"
                        )
                    } else {
                        newSegments.append(segment)
                    }
                    index += 2
                    continue
                }
            }
            let label = unescapeHTML(trimmed)
            if ReferenceGraphService.resolveReferencePath(imageDir: imageDirectory, label: label) != nil {
                newSegments.append(
                    "<a href=\"reflevel://\" style=\"color:\(accentHex);text-decoration:underline;\">\(segment)</a>"
                )
            } else {
                newSegments.append(segment)
            }
            index += 1
        }
        return String(disp[..<bodyStart]) + newSegments.joined(separator: "<br>") + String(disp[end...])
    }

    private static func wrapDescriptionWithCollapsibleSections(
        _ descriptionHTML: String,
        sectionState: InformationSectionState,
        headingHex: String
    ) -> String {
        guard let regex = h4Pattern else { return descriptionHTML }
        let nsRange = NSRange(descriptionHTML.startIndex..., in: descriptionHTML)
        let matches = regex.matches(in: descriptionHTML, range: nsRange)
        guard !matches.isEmpty else { return descriptionHTML }

        var output = ""
        var cursor = descriptionHTML.startIndex
        for match in matches {
            guard let titleRange = Range(match.range(at: 1), in: descriptionHTML),
                  let fullRange = Range(match.range, in: descriptionHTML) else { continue }
            output += descriptionHTML[cursor..<fullRange.lowerBound]
            let title = String(descriptionHTML[titleRange])
            let sectionKey = InformationSectionState.sectionKey(fromH4Title: title)
            let bodyStart = fullRange.upperBound
            let nextMatchIndex = matches.firstIndex(where: { $0.range.lowerBound > match.range.lowerBound })
            let bodyEnd = nextMatchIndex.flatMap { Range(matches[$0].range, in: descriptionHTML)?.lowerBound } ?? descriptionHTML.endIndex
            let body = String(descriptionHTML[bodyStart..<bodyEnd])
            if let sectionKey {
                let expanded = sectionState.sectionExpanded(sectionKey)
                output += collapsibleHeader(
                    sectionKey: sectionKey,
                    title: title,
                    expanded: expanded,
                    fontSize: sectionHeaderFontSize,
                    headingHex: headingHex,
                    marginBottom: expanded ? "6px" : "2px"
                )
                if expanded {
                    output += body
                }
            } else {
                output += "<h4 style=\"font-size: \(sectionHeaderFontSize);\">\(title)</h4>\(body)"
            }
            cursor = bodyEnd
        }
        output += descriptionHTML[cursor...]
        return output
    }

    // MARK: - Table builders

    private static func buildFieldTable(
        pairs: [(String, String)],
        textHex: String,
        borderHex: String,
        bordered: Bool
    ) -> String {
        let font = bodyFontCSS
        let tableStyle: String
        let labelStyle: String
        let valueStyle: String
        if bordered {
            tableStyle = "border: 1px solid \(borderHex); border-collapse: collapse; width: 100%; \(font)"
            labelStyle = "border: 1px solid \(borderHex); padding: 4px 4px 4px 2px; text-align: right; color: \(textHex); white-space: nowrap; width: 1%; \(font)"
            valueStyle = "border: 1px solid \(borderHex); padding: 4px 8px; color: \(textHex); \(font)"
        } else {
            tableStyle = "border: none; border-collapse: collapse; width: 100%; line-height: 1.0; \(font)"
            labelStyle = "border: none; text-align: left; color: \(textHex); white-space: nowrap; width: 1%; vertical-align: top; padding: 0px; \(font)"
            valueStyle = "border: none; color: \(textHex); vertical-align: top; padding: 0px 0px 0px 4px; \(font)"
        }
        var rows = ["<table style=\"\(tableStyle)\">"]
        for (field, value) in pairs {
            let displayValue = value.replacingOccurrences(of: "\n", with: "<br>")
            rows.append("<tr><td style=\"\(labelStyle)\">\(field):</td><td style=\"\(valueStyle)\">\(displayValue)</td></tr>")
        }
        rows.append("</table>")
        return rows.joined()
    }

    private static func buildModelTable(rows: [(String, String, Bool)], textHex: String, contentWidth: Int) -> String {
        let font = bodyFontCSS
        let tableStyle = "border: none; border-collapse: collapse; width: 100%; line-height: 1.0; \(font)"
        let labelStyle = "border: none; text-align: left; color: \(textHex); white-space: nowrap; width: 1%; vertical-align: top; padding: 0px; \(font)"
        let valueStyle = "border: none; color: \(textHex); vertical-align: top; padding: 0px 0px 0px 4px; \(font)"
        var parts = ["<table style=\"\(tableStyle)\">"]
        for (label, valueHTML, elideValue) in rows {
            let value = elideValue
                ? InformationFormatting.escapeHTML(InformationFormatting.elideValue(unescapeHTML(stripHTML(valueHTML)), maxLen: max(40, contentWidth / 8)))
                : valueHTML
            parts.append("<tr>")
            if label.isEmpty, !elideValue {
                parts.append("<td colspan=\"2\" style=\"border: none; color: \(textHex); vertical-align: top; padding: 0px; text-align: left; \(font)\">\(value)</td>")
            } else {
                parts.append("<td style=\"\(labelStyle)\">\(label)</td><td style=\"\(valueStyle)\">\(value)</td>")
            }
            parts.append("</tr>")
        }
        parts.append("</table>")
        return parts.joined()
    }

    private static func collapsibleHeader(
        sectionKey: String,
        title: String,
        expanded: Bool,
        fontSize: String,
        headingHex: String,
        marginBottom: String?
    ) -> String {
        let indicator = expanded ? "▼" : "▶"
        let bottom = marginBottom ?? (expanded ? "12px" : "4px")
        return """
        <div style="font-weight: bold; font-size: \(fontSize); margin-bottom: \(bottom);">
        <a href="infocollapse://\(sectionKey)" style="color: \(headingHex); text-decoration: none; cursor: pointer;">\(indicator) \(title)</a>
        </div>
        """
    }

    // MARK: - Helpers

    private static func colorHex(_ color: Color) -> String {
        NSColor(color).hexString
    }

    private static func unescapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
