import Foundation

/// Runs bundled ``snapshot_job_values.py`` to resolve LoRA paths at submit time.
enum LoRAJobValuesSnapshot {
    static func snapshot(pluginID: String, values: [String: Any], config: AppConfig) async throws -> [String: Any] {
        let environment = await MainActor.run {
            PythonLocator.resolve(profilePath: nil, config: config)
        }
        guard let environment else {
            throw BridgeError.pythonUnavailable
        }
        let input: [String: Any] = ["plugin_id": pluginID, "values": values]
        let inputData = try JSONSerialization.data(withJSONObject: input)

        return try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: environment.executable)
            proc.arguments = PythonLocator.moduleArguments("imagegen_plugins.swift_job_values_snapshot_cli")
            proc.currentDirectoryURL = environment.bundleRoot
            proc.environment = PythonLocator.processEnvironment(for: environment)

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            proc.standardInput = stdinPipe
            proc.standardOutput = stdoutPipe
            proc.standardError = stderrPipe
            try proc.run()
            stdinPipe.fileHandleForWriting.write(inputData)
            try stdinPipe.fileHandleForWriting.close()
            proc.waitUntilExit()

            let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            guard proc.terminationStatus == 0,
                  let doc = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
                let detail = errText.trimmingCharacters(in: .whitespacesAndNewlines)
                throw BridgeError.workerMessage(detail.isEmpty ? "LoRA snapshot failed." : detail)
            }
            if let error = doc["error"] as? String {
                throw BridgeError.workerMessage(error)
            }
            return doc
        }.value
    }
}
