import AVFoundation
import Foundation

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

@MainActor
private enum SayExitLog {
    static func log(_ config: AppConfig, _ message: String) {
        config.debugLog("[say_exit] \(message)")
    }
}

/// Port of `speech_utils.speak_or_stop` for information / EXIF actions.
@MainActor
enum SpeechReader {
    private static let helper = AVSpeechHelper()
    private static let sayExitTimeoutSeconds: TimeInterval = 300

    private static weak var boundConfig: AppConfig?
    private static var exitProcess: Process?
    private static var exitSpeaking = false
    private static var exitProcessGeneration: UInt = 0
    private static var exitStartMonotonic: UInt64 = 0
    private static var exitInvocationScratchByGeneration: [UInt: String] = [:]

    static var isSpeaking: Bool { helper.isSpeaking || exitSpeaking }

    static func bind(config: AppConfig) {
        boundConfig = config
    }

    static func speakOrStop(_ text: String, onStateChange: (() -> Void)? = nil) {
        if isSpeaking {
            stopAll()
            onStateChange?()
            return
        }
        let prepared = ExitScriptUtils.textForSpeech(text)
        guard !prepared.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        guard let config = boundConfig else {
            startAVSpeech(prepared, onStateChange: onStateChange)
            return
        }

        let useExit = config.bool(forKey: ExitScriptUtils.useReadAloudExitKey, default: false)
        if useExit {
            let argv = ExitScriptUtils.buildSayExitArgv(config: config, promptText: prepared)
            if !argv.isEmpty {
                startSayExit(argv: argv, text: prepared, config: config, onStateChange: onStateChange)
                return
            }
        }

        startAVSpeech(prepared, onStateChange: onStateChange)
    }

    private static let readAloudTestPhrase = "This is a read aloud exit test."

    /// Runs the draft exit command from settings UI (ignores ``useReadAloudExitKey``). Returns user-visible error text.
    static func testReadAloudExit(rawCommand: String, config: AppConfig) -> String? {
        if isSpeaking {
            stopAll()
        }
        let stored = SettingsPathValidation.normalizedStoredExitScriptCommand(rawCommand)
        guard !stored.isEmpty else {
            return "Enter a script command to test."
        }
        let validation = ExitScriptUtils.validateExitScriptCommand(stored)
        if !validation.valid {
            return "Fix the script path before testing."
        }
        let prepared = ExitScriptUtils.textForSpeech(readAloudTestPhrase)
        let argv = ExitScriptUtils.buildSayExitArgv(raw: stored, promptText: prepared)
        guard !argv.isEmpty else {
            return "Could not run script with this command."
        }
        startSayExit(argv: argv, text: prepared, config: config, onStateChange: nil)
        return nil
    }

    private static func startAVSpeech(_ text: String, onStateChange: (() -> Void)?) {
        helper.onFinish = { onStateChange?() }
        helper.speak(text)
        onStateChange?()
    }

    private static func cleanupExitScratch(generation: UInt) {
        if let path = exitInvocationScratchByGeneration.removeValue(forKey: generation) {
            ExitScriptUtils.removeExitInvocationScratchDirectory(path)
        }
    }

    private static func stopAll() {
        helper.stop()
        if let proc = exitProcess, proc.isRunning {
            proc.terminate()
        }
        let generation = exitProcessGeneration
        cleanupExitScratch(generation: generation)
        exitProcess = nil
        exitSpeaking = false
        exitProcessGeneration &+= 1
    }

    private static func startSayExit(
        argv: [String],
        text: String,
        config: AppConfig,
        onStateChange: (() -> Void)?
    ) {
        exitProcessGeneration &+= 1
        let generation = exitProcessGeneration
        exitSpeaking = true
        exitStartMonotonic = DispatchTime.now().uptimeNanoseconds
        onStateChange?()

        let scriptPath = argv.count > 1 ? argv[1] : argv[0]
        let stdinSay = usesSayStdin(argv: argv)
        let argvSummary = ExitScriptUtils.formatArgvForDebugLog(argv)

        SayExitLog.log(config, "before argv=\(argvSummary) chars=\(text.count)")

        let scratch = ExitScriptUtils.makeExitInvocationScratchDirectory(tempRoot: config.temporaryFilesDirectory)
        if let scratch {
            exitInvocationScratchByGeneration[generation] = scratch
        }
        let env = ExitScriptUtils.exitScriptProcessEnvironment(scriptPath: scriptPath, tmpDir: scratch)

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: argv[0])
            process.arguments = Array(argv.dropFirst())
            process.environment = env
            let stderr = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderr

            process.terminationHandler = { proc in
                Task { @MainActor in
                    finishSayExit(
                        process: proc,
                        generation: generation,
                        config: config,
                        timedOut: false,
                        onStateChange: onStateChange
                    )
                }
            }

            do {
                if stdinSay {
                    let input = Pipe()
                    process.standardInput = input
                    try process.run()
                    let data = Data(text.utf8)
                    input.fileHandleForWriting.write(data)
                    try input.fileHandleForWriting.close()
                } else {
                    try process.run()
                }
            } catch {
                Task { @MainActor in
                    SayExitLog.log(config, "after start_failed error=\(error.localizedDescription) duration_ms=0")
                    if generation == exitProcessGeneration {
                        cleanupExitScratch(generation: generation)
                        exitProcess = nil
                        exitSpeaking = false
                        onStateChange?()
                    }
                }
                return
            }

            Task { @MainActor in
                guard generation == exitProcessGeneration else { return }
                exitProcess = process
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(sayExitTimeoutSeconds * 1_000_000_000))
                guard generation == exitProcessGeneration, exitSpeaking else { return }
                guard let proc = exitProcess, proc.isRunning else { return }
                SayExitLog.log(config, "after timeout terminating duration_ms=\(elapsedSinceStartMs())")
                proc.terminate()
                finishSayExit(
                    process: proc,
                    generation: generation,
                    config: config,
                    timedOut: true,
                    onStateChange: onStateChange
                )
            }
        }
    }

    private static func finishSayExit(
        process: Process,
        generation: UInt,
        config: AppConfig,
        timedOut: Bool,
        onStateChange: (() -> Void)?
    ) {
        guard generation == exitProcessGeneration, exitSpeaking else { return }
        let code = process.terminationStatus
        let suffix = timedOut ? " timed_out=true" : ""
        SayExitLog.log(config, "after exitCode=\(code) duration_ms=\(elapsedSinceStartMs())\(suffix)")
        cleanupExitScratch(generation: generation)
        exitProcess = nil
        exitSpeaking = false
        onStateChange?()
    }

    private static func elapsedSinceStartMs() -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard exitStartMonotonic > 0, now >= exitStartMonotonic else { return 0 }
        return (now - exitStartMonotonic) / 1_000_000
    }

    private static func usesSayStdin(argv: [String]) -> Bool {
        guard argv.first == "say" else { return false }
        return argv.contains("-f") && argv.contains("-")
    }
}
