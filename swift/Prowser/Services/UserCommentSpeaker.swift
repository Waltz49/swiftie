import AppKit

/// AVSpeechSynthesizer wrapper for reading user comments aloud. Port of `speech_utils.py`.
@MainActor
@Observable
final class UserCommentSpeaker {
    private var speechHelper: AVSpeechHelper?
    private var speechProcess: Process?
    private var speechStopRequested = false
    private(set) var isSpeaking = false

    func speakOrStop(_ text: String, settings: [String: Any] = [:]) {
        guard BundleCapabilities.voiceInputUIEnabled else { return }
        if isSpeaking {
            stop()
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let spoken = trimmed.replacingOccurrences(of: "*", with: "")
        guard !spoken.isEmpty else { return }

        if let argv = ExitScriptUtils.sayExitArgv(text: spoken, settings: settings), !argv.isEmpty {
            runSpeechProcess(argv: argv)
            return
        }

        let helper = AVSpeechHelper()
        helper.onFinish = { [weak self] in
            self?.speechHelper = nil
            self?.isSpeaking = false
        }
        speechHelper = helper
        helper.speak(spoken)
        isSpeaking = true
    }

    func stop() {
        speechStopRequested = true
        if let speechProcess, speechProcess.isRunning {
            speechProcess.terminate()
        }
        speechProcess = nil
        speechHelper?.stop()
        speechHelper = nil
        isSpeaking = false
    }

    private func runSpeechProcess(argv: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        if argv.count > 1 {
            process.arguments = Array(argv.dropFirst())
        }
        let stderrPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = stderrPipe
        let scriptPath = argv.first { $0.hasSuffix(".py") } ?? argv[0]
        process.environment = ExitScriptUtils.exitScriptProcessEnvironment(scriptPath: scriptPath)
        process.terminationHandler = { proc in
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor [weak self] in
                guard let speaker = self else { return }
                let userStopped = speaker.speechStopRequested
                speaker.speechStopRequested = false
                if speaker.speechProcess === proc {
                    speaker.speechProcess = nil
                    speaker.isSpeaking = false
                }
                guard !userStopped, proc.terminationStatus != 0 else { return }
                let status = proc.terminationStatus
                // SIGTERM/SIGINT from stop_speech or toggle-off (128 + signal).
                if status == 143 || status == 130 { return }
                if let stderr = String(data: stderrData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !stderr.isEmpty {
                    print("DEBUG UserCommentSpeaker: say exit failed (\(status)): \(stderr)")
                }
            }
        }
        do {
            speechStopRequested = false
            try process.run()
            speechProcess = process
            isSpeaking = true
        } catch {
            print("DEBUG UserCommentSpeaker: failed to launch say exit: \(error)")
            speechProcess = nil
            isSpeaking = false
        }
    }
}
