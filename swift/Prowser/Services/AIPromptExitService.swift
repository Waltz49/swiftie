import Foundation

/// Port of `imagegen_plugins/ai_prompt_exit.py` (`apply_text_ai_exit`).
@MainActor
enum AIPromptExitService {
    private static let exitTimeoutSeconds: TimeInterval = 30

    static func applyTextAIExit(_ text: String, config: AppConfig) -> String {
        guard promptFilterExitsEnabled(config: config) else { return text }
        let raw = config.string(forKey: ExitScriptUtils.settingTextAIExit)
        guard !raw.isEmpty else { return text }
        return invokeExitScript(raw: raw, text: text)
    }

    private static func promptFilterExitsEnabled(config: AppConfig) -> Bool {
        if config.bool(forKey: "use_prompt_filter_exits", default: false) { return true }
        if !config.string(forKey: ExitScriptUtils.settingTextAIExit).isEmpty { return true }
        if !config.string(forKey: ExitScriptUtils.settingImageAIExit).isEmpty { return true }
        if !(ProcessInfo.processInfo.environment["PROWSER_TEXT_AI_EXIT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if !(ProcessInfo.processInfo.environment["PROWSER_IMAGE_AI_EXIT"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    private static func invokeExitScript(raw: String, text: String) -> String {
        let argv = ExitScriptUtils.buildExitScriptArgv(raw: raw, promptText: text)
        guard !argv.isEmpty else { return text }
        let scriptPath = argv.count > 1 ? argv[1] : argv[0]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = ExitScriptUtils.exitScriptProcessEnvironment(scriptPath: scriptPath)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return text
        }
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }
        let finished = group.wait(timeout: .now() + exitTimeoutSeconds)
        if finished == .timedOut {
            process.terminate()
            return text
        }
        guard process.terminationStatus == 0 else { return text }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return text }
        return output.trimmingCharacters(in: CharacterSet.newlines)
    }
}
