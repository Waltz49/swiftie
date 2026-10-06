import AppKit
import SwiftUI

/// Renders the subset of markdown used by help dialogs (headings, tables, emphasis).
enum HelpMarkdownHTML {
    static func themedPage(markdown: String, colors: ThemeColors) -> String {
        let textHex = NSColor(colors.dialogText).hexString
        let bgHex = NSColor(colors.dialogBackground).hexString
        let borderHex = NSColor(colors.defaultBorder).hexString
        let body = renderBody(markdown)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8"/>
        <style>
        body { font-family: "Helvetica Neue", "Helvetica", "Arial", sans-serif; font-size: 13px; line-height: 1.45; color: \(textHex); background: \(bgHex); margin: 0; padding: 2px 4px; }
        h1 { font-size: 17px; margin: 0 0 0.6em 0; }
        h2 { font-size: 15px; margin: 1.1em 0 0.45em 0; }
        h3 { font-size: 13px; margin: 0.9em 0 0.35em 0; font-weight: bold; }
        p { margin: 0.45em 0; }
        hr { border: none; border-top: 1px solid \(borderHex); margin: 1em 0; }
        table { width: 100%; border-collapse: collapse; margin: 0.5em 0 0.85em 0; }
        th, td { border: 1px solid \(borderHex); padding: 6px 8px; vertical-align: top; text-align: left; }
        th { background-color: \(bgHex); font-weight: bold; }
        code { font-family: Menlo, Monaco, monospace; font-size: 12px; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func renderBody(_ markdown: String) -> String {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var html: [String] = []
        var index = 0
        var paragraph: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: " ")
            html.append("<p>\(inlineHTML(joined))</p>")
            paragraph.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if trimmed == "#" {
                flushParagraph()
                html.append("<hr/>")
                index += 1
                continue
            }

            if trimmed.hasPrefix("### ") {
                flushParagraph()
                html.append("<h3>\(inlineHTML(String(trimmed.dropFirst(4))))</h3>")
                index += 1
                continue
            }

            if trimmed.hasPrefix("## ") {
                flushParagraph()
                html.append("<h2>\(inlineHTML(String(trimmed.dropFirst(3))))</h2>")
                index += 1
                continue
            }

            if trimmed.hasPrefix("# ") {
                flushParagraph()
                html.append("<h1>\(inlineHTML(String(trimmed.dropFirst(2))))</h1>")
                index += 1
                continue
            }

            if trimmed.hasPrefix("|") {
                flushParagraph()
                let tableLines: [String] = {
                    var collected: [String] = []
                    while index < lines.count {
                        let row = lines[index].trimmingCharacters(in: .whitespaces)
                        guard row.hasPrefix("|") else { break }
                        collected.append(row)
                        index += 1
                    }
                    return collected
                }()
                if let tableHTML = renderTable(tableLines) {
                    html.append(tableHTML)
                }
                continue
            }

            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        return html.joined(separator: "\n")
    }

    private static func renderTable(_ lines: [String]) -> String? {
        guard !lines.isEmpty else { return nil }
        let rows = lines.map(parseTableRow)
        guard !rows.isEmpty else { return nil }

        var bodyRows = rows
        var header: [String]?
        if rows.count >= 2, isSeparatorRow(rows[1]) {
            header = rows[0]
            bodyRows = Array(rows.dropFirst(2))
        }

        var out = "<table>"
        if let header {
            out += "<thead><tr>"
            for cell in header {
                out += "<th>\(inlineHTML(cell))</th>"
            }
            out += "</tr></thead>"
        }
        out += "<tbody>"
        for row in bodyRows {
            out += "<tr>"
            for cell in row {
                out += "<td>\(inlineHTML(cell))</td>"
            }
            out += "</tr>"
        }
        out += "</tbody></table>"
        return out
    }

    private static func parseTableRow(_ line: String) -> [String] {
        line
            .split(separator: "|", omittingEmptySubsequences: false)
            .dropFirst()
            .dropLast()
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparatorRow(_ cells: [String]) -> Bool {
        cells.allSatisfy { cell in
            let stripped = cell.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
            return stripped.isEmpty
        }
    }

    private static func inlineHTML(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "`" {
                let after = text.index(after: index)
                if let end = text[after...].firstIndex(of: "`") {
                    let code = String(text[after..<end])
                    result += "<code>\(escapeHTML(code))</code>"
                    index = text.index(after: end)
                    continue
                }
            }
            if text[index] == "*", index < text.endIndex {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "*" {
                    let after = text.index(after: next)
                    if let end = text[after...].range(of: "**")?.lowerBound {
                        let inner = String(text[after..<end])
                        result += "<strong>\(escapeHTML(inner))</strong>"
                        index = text.index(end, offsetBy: 2)
                        continue
                    }
                }
                if let end = text[next...].firstIndex(of: "*") {
                    let inner = String(text[next..<end])
                    result += "<em>\(escapeHTML(inner))</em>"
                    index = text.index(after: end)
                    continue
                }
            }
            if text[index] == "&" {
                result += "&amp;"
                index = text.index(after: index)
                continue
            }
            if text[index] == "<" {
                result += "&lt;"
                index = text.index(after: index)
                continue
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}
