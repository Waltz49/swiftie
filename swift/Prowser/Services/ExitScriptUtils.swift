import Foundation

/// Port of `exit_scripts.py` validation helpers for settings UI.
enum ExitScriptUtils {
    static let settingTextAIExit = "text_ai_exit"
    static let settingImageAIExit = "image_ai_exit"
    static let settingSayExit = "say_exit"
    static let useReadAloudExitKey = "use_read_aloud_exit"
    static let envSayExit = "PROWSER_SAY_EXIT"
    static let envSayVoice = "PROWSER_SAY_VOICE"
    static let envTmpDir = "PROWSER_TMP_DIR"

    private static let exitInvocationScratchPrefix = "exit-"

    static let exitScriptPrefixes = ["python", "python3", "pypy"]

    struct ParsedExitScript {
        var prefix: String
        var path: String
        /// Tokens after the script path (`-v Joe`, `--rate 1.2`, etc.).
        var extraArgs: [String]
        var raw: String
    }

    static func parseExitScriptCommand(_ raw: String) -> ParsedExitScript {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return ParsedExitScript(prefix: "", path: "", extraArgs: [], raw: "")
        }
        let parts = splitCommand(text)
        if parts.isEmpty {
            return ParsedExitScript(prefix: "", path: "", extraArgs: [], raw: text)
        }
        if let matched = prefixToken(parts[0]) {
            let path = parts.count > 1 ? parts[1] : ""
            let extra = parts.count > 2 ? Array(parts.dropFirst(2)) : []
            return ParsedExitScript(prefix: matched, path: path, extraArgs: extra, raw: text)
        }
        let extra = parts.count > 1 ? Array(parts.dropFirst(1)) : []
        return ParsedExitScript(prefix: "", path: parts[0], extraArgs: extra, raw: text)
    }

    static func formatExitScriptCommand(prefix: String, path: String, extraArgs: [String] = []) -> String {
        let scriptPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if scriptPath.isEmpty { return "" }
        let interpreter = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        var tokens: [String]
        if interpreter.isEmpty {
            tokens = [scriptPath]
        } else {
            tokens = [interpreter, scriptPath]
        }
        if !extraArgs.isEmpty {
            tokens.append(contentsOf: extraArgs)
        }
        return tokens.joined(separator: " ")
    }

    static func validateExitScriptCommand(_ raw: String) -> (valid: Bool, message: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return (true, "") }
        let parsed = parseExitScriptCommand(text)
        if parsed.path.isEmpty {
            return (false, "Missing script path")
        }
        let fullPath = normalizeExitScriptPath(parsed.path)
        var isDir: ObjCBool = false
        let fm = FileManager.default
        if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
            return (false, "Path is a directory, not a file:\n\(fullPath)")
        }
        if !fm.fileExists(atPath: fullPath) {
            return (false, "File does not exist:\n\(fullPath)")
        }
        if exitScriptPathUsable(fullPath) {
            let issues = exitScriptPathIssues(fullPath)
            if !issues.isEmpty {
                return (true, "Valid script file (\(issues.joined(separator: "; "))):\n\(fullPath)")
            }
            return (true, "Valid script file:\n\(fullPath)")
        }
        let issues = exitScriptPathIssues(fullPath)
        let detail = issues.isEmpty ? "" : " (\(issues.joined(separator: "; ")))"
        return (false, "File is not usable\(detail):\n\(fullPath)")
    }

    static func normalizeExitScriptPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func buildExitScriptArgv(raw: String, promptText: String) -> [String] {
        var argv = resolveExitScriptArgv(raw: raw)
        guard !argv.isEmpty else { return [] }
        argv.append(contentsOf: ["-p", promptText])
        return argv
    }

    /// Settings value for say exit, else `PROWSER_SAY_EXIT` (port of `get_exit_script_setting`).
    @MainActor
    static func resolvedSayExitCommandRaw(config: AppConfig) -> String {
        let value = config.string(forKey: settingSayExit).trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }
        let legacy = ProcessInfo.processInfo.environment[envSayExit]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return legacy
    }

    /// Port of ``speech_exit.say_exit_argv``.
    static func buildSayExitArgv(raw: String, promptText: String) -> [String] {
        var argv = resolveExitScriptArgv(raw: raw)
        guard !argv.isEmpty else { return [] }
        let voice = ProcessInfo.processInfo.environment[envSayVoice]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !voice.isEmpty, !argv.contains("-v"), !argv.contains("--voice") {
            argv.append(contentsOf: ["-v", voice])
        }
        argv.append(contentsOf: ["-p", promptText])
        return argv
    }

    @MainActor
    static func buildSayExitArgv(config: AppConfig, promptText: String) -> [String] {
        let raw = resolvedSayExitCommandRaw(config: config)
        guard !raw.isEmpty else { return [] }
        return buildSayExitArgv(raw: raw, promptText: promptText)
    }

    /// Port of `speech_utils.text_for_speech`.
    static func textForSpeech(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "*", with: "")
    }

    static func formatArgvForDebugLog(_ argv: [String]) -> String {
        argv.map { part in
            if part.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
                || part.contains("\"") || part.contains("'") {
                let escaped = part.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(escaped)\""
            }
            return part
        }.joined(separator: " ")
    }

    static func resolveExitScriptArgv(raw: String) -> [String] {
        let parts = splitCommand(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !parts.isEmpty else { return [] }

        if let matched = prefixToken(parts[0]) {
            guard parts.count >= 2 else { return [] }
            let scriptPath = normalizeExitScriptPath(parts[1])
            guard exitScriptPathUsable(scriptPath) else { return [] }
            let interpreter: String
            if matched == "python" || matched == "python3" {
                interpreter = resolvePythonInterpreter()
            } else {
                interpreter = matched
            }
            return [interpreter, scriptPath] + Array(parts.dropFirst(2))
        }

        let scriptPath = normalizeExitScriptPath(parts[0])
        guard FileManager.default.fileExists(atPath: scriptPath) else { return [] }
        guard exitScriptPathUsable(scriptPath) else { return [] }
        if scriptPath.hasSuffix(".py"),
           !FileManager.default.isExecutableFile(atPath: scriptPath) {
            return [resolvePythonInterpreter(), scriptPath] + Array(parts.dropFirst(1))
        }
        return [scriptPath] + Array(parts.dropFirst(1))
    }

    /// Per-invocation scratch directory under the profile work-temp root (``temporaryFilesDirectory``).
    static func makeExitInvocationScratchDirectory(tempRoot: URL) -> String? {
        let base = tempRoot.standardizedFileURL
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let path = base
            .appendingPathComponent("\(exitInvocationScratchPrefix)\(UUID().uuidString)", isDirectory: true)
            .path
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        } catch {
            return nil
        }
    }

    static func removeExitInvocationScratchDirectory(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Environment for exit-script subprocesses (venv bin on PATH for pocket-tts etc.).
    static func exitScriptProcessEnvironment(scriptPath: String, tmpDir: String? = nil) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var pathPrefixes: [String] = []
        if let shebangBin = shebangInterpreterBinDirectory(scriptPath) {
            pathPrefixes.append(shebangBin)
        }
        if let envRoot = ProcessInfo.processInfo.environment["PROWSER_PYTHON_ROOT"], !envRoot.isEmpty {
            let venvBin = URL(fileURLWithPath: envRoot).appendingPathComponent("venv_image_browser/bin").path
            if FileManager.default.isExecutableFile(atPath: venvBin + "/python") {
                pathPrefixes.append(venvBin)
            }
        }
        if !pathPrefixes.isEmpty {
            let existing = env["PATH"] ?? ""
            env["PATH"] = pathPrefixes.joined(separator: ":") + (existing.isEmpty ? "" : ":" + existing)
        }
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["LC_ALL"] = env["LC_ALL"] ?? "en_US.UTF-8"
        env["PYTHONUTF8"] = "1"
        env["PYTHONIOENCODING"] = "utf-8:utf-8"
        if let tmpDir, !tmpDir.isEmpty {
            env[envTmpDir] = tmpDir
        }
        return env
    }

    private static func resolvePythonInterpreter() -> String {
        "/usr/bin/python3"
    }

    private static func shebangInterpreterBinDirectory(_ scriptPath: String) -> String? {
        guard let data = try? String(contentsOfFile: scriptPath, encoding: .utf8),
              let firstLine = data.split(separator: "\n", maxSplits: 1).first,
              firstLine.hasPrefix("#!") else {
            return nil
        }
        let interpreter = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !interpreter.isEmpty else { return nil }
        return (interpreter as NSString).deletingLastPathComponent
    }

    private static func exitScriptPathUsable(_ path: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path), fm.isReadableFile(atPath: path) else { return false }
        if path.hasSuffix(".py") { return true }
        return fm.isExecutableFile(atPath: path)
    }

    private static func exitScriptPathIssues(_ path: String) -> [String] {
        var issues: [String] = []
        let fm = FileManager.default
        if !fm.isReadableFile(atPath: path) {
            issues.append("not readable")
        }
        if path.hasSuffix(".py") {
            if !fm.isExecutableFile(atPath: path) {
                issues.append("not executable (will run with python)")
            }
        } else if !fm.isExecutableFile(atPath: path) {
            issues.append("not executable")
        }
        return issues
    }

    private static func prefixToken(_ token: String) -> String? {
        let lowered = token.lowercased()
        for prefix in exitScriptPrefixes.sorted(by: { $0.count > $1.count }) {
            if lowered == prefix { return prefix }
        }
        return nil
    }

    private static func splitCommand(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escape = false
        for char in text {
            if escape {
                current.append(char)
                escape = false
                continue
            }
            if char == "\\" {
                escape = true
                continue
            }
            if char == "'" && !inDouble {
                inSingle.toggle()
                continue
            }
            if char == "\"" && !inSingle {
                inDouble.toggle()
                continue
            }
            if char.isWhitespace && !inSingle && !inDouble {
                if !current.isEmpty {
                    parts.append(current)
                    current = ""
                }
                continue
            }
            current.append(char)
        }
        if !current.isEmpty {
            parts.append(current)
        }
        return parts
    }
}
