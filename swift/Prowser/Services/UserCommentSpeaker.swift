import AppKit

/// NSSpeechSynthesizer wrapper for reading user comments aloud. Port of `speech_utils.py`.
@MainActor
@Observable
final class UserCommentSpeaker: NSObject, NSSpeechSynthesizerDelegate {
    private var synthesizer: NSSpeechSynthesizer?
    private(set) var isSpeaking = false

    func speakOrStop(_ text: String) {
        guard BundleCapabilities.voiceInputUIEnabled else { return }
        if isSpeaking {
            stop()
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let synth = NSSpeechSynthesizer()
        synth.delegate = self
        synthesizer = synth
        synth.startSpeaking(trimmed)
        isSpeaking = true
    }

    func stop() {
        synthesizer?.stopSpeaking()
        synthesizer = nil
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        Task { @MainActor in
            isSpeaking = false
            synthesizer = nil
        }
    }
}
