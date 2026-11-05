import Foundation

/// UTF-8 / UTF-16 helpers for image-gen prompt fields (AppKit `NSRange` + job/EXIF I/O).
enum ImageGenPromptTextEncoding {
    /// Length in UTF-16 code units (required for `NSTextView` / `NSRange`).
    static func utf16Length(of text: String) -> Int {
        (text as NSString).length
    }

    /// `NSRange` covering the full string for AppKit text APIs.
    static func fullUTF16Range(of text: String) -> NSRange {
        NSRange(location: 0, length: utf16Length(of: text))
    }

    /// End insertion point in UTF-16 (append streaming tokens, emoji-safe).
    static func utf16EndInsertionRange(in text: String) -> NSRange {
        NSRange(location: utf16Length(of: text), length: 0)
    }

    /// Suffix after a verified Unicode prefix (character-grapheme safe; not byte offset).
    static func suffix(afterPrefix prefix: String, in full: String) -> String? {
        guard full.hasPrefix(prefix) else { return nil }
        return String(full[prefix.endIndex...])
    }

    /// Decode prompt bytes from workers, EXIF, or pasteboard.
    static func stringFromUTF8(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
    }

    /// Encode for JSON payloads, files, and explicit UTF-8 pasteboard types.
    static func utf8Data(from text: String) -> Data? {
        text.data(using: .utf8)
    }

    /// Lossless UTF-8 round-trip check (storage / bridge boundaries).
    static func preservesUTF8RoundTrip(_ text: String) -> Bool {
        guard let data = utf8Data(from: text) else { return text.isEmpty }
        return stringFromUTF8(data) == text
    }

    /// Reverses UTF-8 bytes mis-read as ISO Latin-1 and stored as UTF-8 again (common exit-script / pipe mojibake).
    static func repairUTF8BytesMisinterpretedAsLatin1(_ text: String, maxPasses: Int = 3) -> String {
        var current = text
        for _ in 0..<max(1, maxPasses) {
            guard let latin1 = current.data(using: .isoLatin1),
                  let repaired = stringFromUTF8(latin1),
                  repaired != current else { break }
            current = repaired
        }
        return current
    }

    static func repairPromptDictionaryFields(
        _ values: inout [String: Any],
        keys: [String] = ["prompt", "negative_prompt"]
    ) {
        for key in keys {
            guard let text = values[key] as? String else { continue }
            let repaired = repairUTF8BytesMisinterpretedAsLatin1(text)
            if repaired != text {
                values[key] = repaired
            }
        }
    }
}
