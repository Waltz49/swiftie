import Foundation

/// Detect /create and /source slash commands in chat user messages.
/// Port of `chat_plugins/chat_image_gen_trigger.py`.
enum ChatImageGenTrigger {
    enum Mode: String, Equatable {
        case create
        case edit
    }

    private static let createPattern = #"(?<!\w)/(?:cr|cre|crea|creat|create)\b"#
    private static let sourcePattern = #"(?<!\w)/(?:so|sou|sour|sourc|source|src)\b"#
    private static let triggerPattern = #"(?<!\w)/(?:cr|cre|crea|creat|create|so|sou|sour|sourc|source|src)\b"#

    static func hasCreateCommand(_ text: String) -> Bool {
        matches(pattern: createPattern, in: text)
    }

    static func hasSourceCommand(_ text: String) -> Bool {
        matches(pattern: sourcePattern, in: text)
    }

    static func classifyMode(text: String, hasUserImages: Bool) -> Mode? {
        guard hasCreateCommand(text) else { return nil }
        return hasUserImages ? .edit : .create
    }

    static func wantsAssistantSources(text: String, hasUserImages: Bool) -> Bool {
        hasUserImages && hasSourceCommand(text)
    }

    static func effectiveMode(
        text: String,
        hasUserImages: Bool,
        automaticCreate: Bool
    ) -> Mode? {
        if automaticCreate {
            return hasUserImages ? .edit : .create
        }
        return classifyMode(text: text, hasUserImages: hasUserImages)
    }

    static func stripCreateCommands(_ text: String) -> String {
        collapseWhitespace(replacing(pattern: createPattern, in: text, with: ""))
    }

    static func stripImageGenCommands(_ text: String) -> String {
        collapseWhitespace(replacing(pattern: triggerPattern, in: text, with: ""))
    }

    static func prepareForStorage(
        text: String,
        imagePaths: [String],
        selectedPaths: [String],
        automaticCreate: Bool,
        keepSelectionTrigger: Bool = false
    ) -> (text: String, imagePaths: [String], mode: Mode?) {
        let (storedText, storedPaths) = ChatSelectionImageTrigger.apply(
            text: text,
            imagePaths: imagePaths,
            selectedPaths: selectedPaths,
            keepTriggerInText: keepSelectionTrigger
        )
        if automaticCreate {
            let cleaned = stripCreateCommands(storedText)
            let mode: Mode = storedPaths.isEmpty ? .create : .edit
            return (cleaned, storedPaths, mode)
        }
        let mode = classifyMode(text: storedText, hasUserImages: !storedPaths.isEmpty)
        return (storedText, storedPaths, mode)
    }

    static func pathsForImageGen(_ message: ChatMessage) -> [String] {
        let sources = message.sourceImagePaths.filter { !$0.isEmpty }
        if !sources.isEmpty { return sources }
        return message.imagePaths.filter { !$0.isEmpty }
    }

    private static func matches(pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func replacing(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
