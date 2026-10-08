import Foundation

/// Resolves LoRA stack → path/scale keys via Python ``build_worker_payload`` (Swift builder stub).
enum ImageGenLoraWorkerPayloadEnrich {
    static let mergeKeys: [String] = [
        "mflux_lora_paths",
        "mflux_lora_scales",
        "sd15_lora_paths",
        "sd15_lora_scales",
        "sdxl_lora_paths",
        "sdxl_lora_scales",
        "mflux_lora_scales_by_id",
        "mflux_lora_trigger_words",
        "steps",
    ]

    static func payloadHasResolvedLoraPaths(_ values: [String: Any]) -> Bool {
        for key in ["mflux_lora_paths", "sd15_lora_paths", "sdxl_lora_paths"] {
            if let paths = values[key] as? [Any], !paths.isEmpty {
                return true
            }
        }
        return false
    }

    static func mergeLoraFields(from source: [String: Any], into values: inout [String: Any]) {
        let pathScaleKeys = Set(mergeKeys.filter { $0.hasSuffix("_paths") || $0.hasSuffix("_scales") })
        for key in mergeKeys {
            if let value = source[key] {
                values[key] = value
            } else if pathScaleKeys.contains(key) {
                values.removeValue(forKey: key)
            }
        }
    }

    static func enrichPayload(
        pluginID: String,
        payload: [String: Any],
        outputPath: String,
        applyImageExit: Bool,
        config: AppConfig
    ) async throws -> [String: Any] {
        guard let plugin = ImageGenPluginCatalog.plugin(pluginID: pluginID),
              plugin.loraHostID != nil else {
            return payload
        }
        let pythonReady = await MainActor.run {
            PythonLocator.resolve(profilePath: nil, config: config) != nil
        }
        guard pythonReady else {
            return payload
        }
        if payload["_job_values_snapshotted"] as? Bool == true,
           payloadHasResolvedLoraPaths(payload) {
            return payload
        }
        do {
            let enriched = try await runEnrichCLI(
                pluginID: pluginID,
                values: payload,
                outputPath: outputPath,
                applyImageExit: applyImageExit,
                config: config
            )
            var out = payload
            mergeLoraFields(from: enriched, into: &out)
            return out
        } catch {
            return payload
        }
    }

    private static func runEnrichCLI(
        pluginID: String,
        values: [String: Any],
        outputPath: String,
        applyImageExit: Bool,
        config: AppConfig
    ) async throws -> [String: Any] {
        let environment = await MainActor.run {
            PythonLocator.resolve(profilePath: nil, config: config)
        }
        guard let environment else {
            throw BridgeError.pythonUnavailable
        }
        let input: [String: Any] = [
            "plugin_id": pluginID,
            "values": values,
            "output_path": outputPath,
            "apply_image_exit": applyImageExit,
        ]
        let inputData = try JSONSerialization.data(withJSONObject: input)

        return try await Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: environment.executable)
            proc.arguments = PythonLocator.moduleArguments(
                "imagegen_plugins.swift_apply_lora_worker_payload_cli"
            )
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
                throw BridgeError.workerMessage(
                    detail.isEmpty ? "LoRA worker payload enrich failed." : detail
                )
            }
            if let error = doc["error"] as? String {
                throw BridgeError.workerMessage(error)
            }
            return doc
        }.value
    }
}
