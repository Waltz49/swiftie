import Foundation

/// Creates the profile imagegen venv and installs `requirements-imagegen.txt`.
@MainActor
enum ImageGenVenvInstaller {
    struct InstallResult {
        var success: Bool
        var message: String
    }

    static func install(
        config: AppConfig,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> InstallResult {
        let emit: @Sendable (String) -> Void = { chunk in
            onOutput?(chunk)
        }
        let venv = config.imagegenVenvURL()
        let python = locateSystemPython()
        guard let python else {
            return InstallResult(success: false, message: "No system python3 found (install Python 3.11+).")
        }
        guard let requirements = ImageGenVenvPaths.bundledRequirementsURL() else {
            return InstallResult(success: false, message: "Missing requirements-imagegen.txt in app bundle.")
        }
        do {
            try FileManager.default.createDirectory(at: venv.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: config.imagegenVenvPythonPath()) {
                let created = try await run(
                    python,
                    arguments: ["-m", "venv", venv.path],
                    onOutput: emit
                )
                if created.exitCode != 0 {
                    return InstallResult(success: false, message: failureMessage(from: created))
                }
            }
            let venvPython = config.imagegenVenvPythonPath()
            let pip = try await run(
                venvPython,
                arguments: ["-m", "pip", "install", "--upgrade", "pip"],
                onOutput: emit
            )
            if pip.exitCode != 0 {
                return InstallResult(success: false, message: failureMessage(from: pip))
            }
            let install = try await run(
                venvPython,
                arguments: ["-m", "pip", "install", "-r", requirements.path],
                onOutput: emit
            )
            if install.exitCode != 0 {
                return InstallResult(success: false, message: failureMessage(from: install))
            }
            let verify = try await run(
                venvPython,
                arguments: [
                    "-c",
                    "import mflux, diffusers, torch, peft, sdnq; print('ok')",
                ],
                onOutput: emit
            )
            if verify.exitCode != 0 {
                return InstallResult(
                    success: false,
                    message: "Packages installed but import check failed:\n\(failureMessage(from: verify))"
                )
            }
            return InstallResult(
                success: true,
                message:
                    "Imagegen venv ready at \(venv.path). "
                    + "Optimized generation uses this environment (mflux, diffusers, peft, sdnq). "
                    + "Download model weights from Image → Manage models… when needed."
            )
        } catch {
            return InstallResult(success: false, message: error.localizedDescription)
        }
    }

    private static func failureMessage(from result: CommandResult) -> String {
        let combined = result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if combined.isEmpty {
            return "Command failed (exit \(result.exitCode))."
        }
        return combined
    }

    private static func locateSystemPython() -> String? {
        for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private struct CommandResult {
        var exitCode: Int32
        var combinedOutput: String
    }

    private static func commandBanner(executable: String, arguments: [String]) -> String {
        let quotedArgs = arguments.map { arg in
            arg.contains(" ") || arg.contains("\"") ? "\"\(arg.replacingOccurrences(of: "\"", with: "\\\""))\"" : arg
        }
        let line = ([executable] + quotedArgs).joined(separator: " ")
        return "\n=== \(line) ===\n"
    }

    private final class StreamAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var captured = ""
        private let onOutput: @Sendable (String) -> Void

        init(onOutput: @escaping @Sendable (String) -> Void) {
            self.onOutput = onOutput
        }

        func append(_ text: String) {
            guard !text.isEmpty else { return }
            lock.lock()
            captured += text
            lock.unlock()
            onOutput(text)
        }

        var combined: String {
            lock.lock()
            defer { lock.unlock() }
            return captured
        }
    }

    private static func run(
        _ executable: String,
        arguments: [String],
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> CommandResult {
        onOutput(commandBanner(executable: executable, arguments: arguments))
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let accumulator = StreamAccumulator(onOutput: onOutput)

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            stdoutHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let chunk = String(data: data, encoding: .utf8) ?? ""
                accumulator.append(chunk)
            }
            stderrHandle.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let chunk = String(data: data, encoding: .utf8) ?? ""
                accumulator.append(chunk)
            }

            try process.run()
            process.waitUntilExit()

            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil

            let trailingStdout = stdoutHandle.readDataToEndOfFile()
            let trailingStderr = stderrHandle.readDataToEndOfFile()
            if let tail = String(data: trailingStdout, encoding: .utf8) {
                accumulator.append(tail)
            }
            if let tail = String(data: trailingStderr, encoding: .utf8) {
                accumulator.append(tail)
            }

            return CommandResult(exitCode: process.terminationStatus, combinedOutput: accumulator.combined)
        }.value
    }
}
