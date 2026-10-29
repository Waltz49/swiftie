import Foundation

/// Port of Python ``CHAT_REJECTED_RESPONSE_PHRASES`` / ``chat_response_contains_rejected_phrase``.
enum ChatRejectedResponsePhrasesStore {
    static let settingsEnableKey = "chat_use_rejected_response_phrases"
    static let maxRetries = 5

    private static let fileName = "chat_rejected_response_phrases.json"

    /// Default list from ``thumbnail_constants.CHAT_REJECTED_RESPONSE_PHRASES``.
    static let defaultPhrases: [String] = [
        "an AI",
        "I'm sorry",
        "I apologize",
        "I'm unable",
        "I am unable",
        "i cannot",
        "I can not",
        "I cannot",
        "I won't",
        "I can't",
        "I will not",
        "not comply",
        "harmful",
        "ethical",
        "guidelines",
        "norms",
        "standards",
    ]

    static func fileURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(fileName)
    }

    static func load(dataDirectory: URL) -> [String] {
        let url = fileURL(dataDirectory: dataDirectory)
        if FileManager.default.fileExists(atPath: url.path),
           let phrases = parsePhrases(from: url) {
            return phrases
        }
        let legacy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".prowser/data/\(fileName)")
        if legacy.path != url.path, FileManager.default.fileExists(atPath: legacy.path),
           let phrases = parsePhrases(from: legacy) {
            return phrases
        }
        return defaultPhrases
    }

    private static func parsePhrases(from url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["phrases"] as? [String] else {
            return nil
        }
        return normalizePhrases(raw)
    }

    static func save(phrases: [String], dataDirectory: URL) {
        let url = fileURL(dataDirectory: dataDirectory)
        let normalized = normalizePhrases(phrases)
        let config: [String: Any] = ["phrases": normalized]
        guard JSONSerialization.isValidJSONObject(config),
              let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func normalizePhrases(_ phrases: [String]) -> [String] {
        phrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Case-insensitive substring match (port of ``chat_response_contains_rejected_phrase``).
    @MainActor
    static func firstMatchingPhrase(in text: String, config: AppConfig) -> String? {
        guard config.bool(forKey: settingsEnableKey, default: true) else { return nil }
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        let phrases = load(dataDirectory: config.dataDirectory)
        for phrase in phrases {
            if phrase.lowercased().isEmpty { continue }
            if lower.contains(phrase.lowercased()) {
                return phrase
            }
        }
        return nil
    }
}

// MARK: - Chat stream retry (port of ``chat_worker._ChatLmStudioWorker.run_stream``)

enum ChatRejectedPhraseStreamRetry {
    struct Outcome {
        var accumulated: String
        /// When true, matched a phrase on the final attempt (suppress auto image-gen in chat).
        var suppressAutoImageGen: Bool
    }

    /// Runs ``streamOnce`` up to ``ChatRejectedResponsePhrasesStore.maxRetries`` times when a rejected phrase appears mid-stream.
    /// ``streamOnce`` should stop reading from the model when ``emit`` returns `false`.
    @MainActor
    static func runWithRejectionRetry(
        config: AppConfig,
        onChunk: @escaping @MainActor (String) -> Void,
        onRestarted: (@MainActor () -> Void)? = nil,
        streamOnce: @escaping @MainActor (
            _ emit: @escaping @MainActor (String) -> Bool
        ) async throws -> Void
    ) async throws -> Outcome {
        let maxAttempts = ChatRejectedResponsePhrasesStore.maxRetries
        for attempt in 1...maxAttempts {
            var accumulated = ""
            var retryStream = false
            var suppressAutoImageGen = false

            try await streamOnce { piece in
                accumulated += piece
                if let matched = ChatRejectedResponsePhrasesStore.firstMatchingPhrase(in: accumulated, config: config) {
                    if attempt < maxAttempts {
                        print(
                            "[chat] rejected phrase \(matched.debugDescription) in "
                                + "attempt \(attempt)/\(maxAttempts), restarting"
                        )
                        onRestarted?()
                        retryStream = true
                        return false
                    }
                    suppressAutoImageGen = true
                }
                onChunk(piece)
                return true
            }

            if retryStream {
                continue
            }
            return Outcome(accumulated: accumulated, suppressAutoImageGen: suppressAutoImageGen)
        }
        return Outcome(accumulated: "", suppressAutoImageGen: false)
    }
}
