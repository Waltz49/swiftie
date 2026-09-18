import Foundation

/// CLIP BPE tokenizer (loads `clip_vocab.json` + `clip_merges.txt` from the text model install dir).
struct CLIPTokenizer: Sendable {
    private let encoder: [String: Int]
    private let decoder: [Int: String]
    private let bpeRanks: [String: Int]
    private let startToken = 49406
    private let endToken = 49407
    let contextLength = 77

    init?(modelInstallDirectory: URL) {
        let vocabURL = modelInstallDirectory.appendingPathComponent("clip_vocab.json")
        let mergesURL = modelInstallDirectory.appendingPathComponent("clip_merges.txt")
        guard let vocabData = try? Data(contentsOf: vocabURL),
              let vocab = try? JSONDecoder().decode([String: Int].self, from: vocabData),
              let mergesText = try? String(contentsOf: mergesURL, encoding: .utf8) else {
            return nil
        }
        encoder = vocab
        var dec: [Int: String] = [:]
        for (k, v) in vocab { dec[v] = k }
        decoder = dec
        var ranks: [String: Int] = [:]
        let lines = mergesText.split(separator: "\n").dropFirst()
        for (i, line) in lines.enumerated() {
            ranks[String(line)] = i
        }
        bpeRanks = ranks
    }

    func encode(text: String) -> [Int] {
        let cleaned = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = tokenize(cleaned)
        var ids = [startToken]
        for token in tokens {
            if let id = encoder[token] {
                ids.append(id)
            }
        }
        ids.append(endToken)
        if ids.count > contextLength {
            ids = Array(ids.prefix(contextLength - 1)) + [endToken]
        }
        while ids.count < contextLength {
            ids.append(0)
        }
        return ids
    }

    private func tokenize(_ text: String) -> [String] {
        let pattern = #"[A-Za-z0-9']+|[^\sA-Za-z0-9']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        var pieces: [String] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            let piece = String(text[r])
            let utf8 = piece.utf8.map { byte -> String in
                if byte < 128 {
                    return String(UnicodeScalar(byte))
                }
                return String(format: "<%02x>", byte)
            }.joined()
            for word in bpe(utf8) {
                pieces.append(word + "</w>")
            }
        }
        return pieces
    }

    private func bpe(_ token: String) -> [String] {
        var word = token.map { String($0) }
        if word.isEmpty { return [] }
        while word.count > 1 {
            var pairs: [(String, String)] = []
            for i in 0 ..< word.count - 1 {
                pairs.append((word[i], word[i + 1]))
            }
            let ranked = pairs.compactMap { pair -> (Int, String, String)? in
                let key = pair.0 + " " + pair.1
                guard let rank = bpeRanks[key] else { return nil }
                return (rank, pair.0, pair.1)
            }
            guard let best = ranked.min(by: { $0.0 < $1.0 }) else { break }
            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == best.1, word[i + 1] == best.2 {
                    newWord.append(best.1 + best.2)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord
        }
        return word
    }
}
