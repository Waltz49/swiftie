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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: trimmed)
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

/// Port of `speech_utils.speak_or_stop` for information / EXIF actions.
@MainActor
enum SpeechReader {
    private static let helper = AVSpeechHelper()

    static var isSpeaking: Bool { helper.isSpeaking }

    static func speakOrStop(_ text: String, onStateChange: (() -> Void)? = nil) {
        if helper.isSpeaking {
            helper.stop()
            onStateChange?()
            return
        }
        helper.onFinish = { onStateChange?() }
        helper.speak(text)
        onStateChange?()
    }
}
