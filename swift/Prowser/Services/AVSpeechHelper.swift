import AVFoundation

/// AVSpeechSynthesizer wrapper replacing deprecated NSSpeechSynthesizer (macOS 14+).
@MainActor
final class AVSpeechHelper: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking = false
    var onFinish: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        synthesizer.speak(utterance)
        isSpeaking = true
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            isSpeaking = false
            onFinish?()
        }
    }
}

enum SpeechSynthesis {
    /// Fire-and-forget single utterance (no stop/toggle tracking).
    @MainActor
    static func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AVSpeechSynthesizer().speak(AVSpeechUtterance(string: trimmed))
    }
}
