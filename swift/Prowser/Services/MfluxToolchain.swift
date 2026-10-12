import Foundation

/// Resolves MFLUX CLI binaries from settings or common install locations.
@MainActor
final class MfluxToolchain {
    static let shared = MfluxToolchain()

    private weak var config: AppConfig?
    private(set) var binDirectory: URL?
    private(set) var lastProbeError = ""

    func bind(config: AppConfig) {
        self.config = config
        binDirectory = resolveBinDirectory(config: config)
    }

    var isAvailable: Bool {
        guard let binDirectory else { return false }
        return executableURL(named: "mflux-generate", binDirectory: binDirectory) != nil
    }

    func executableURL(forPipeline pipelineID: String) -> URL? {
        guard let binDirectory else { return nil }
        guard let name = MfluxCLIPipeline.executableName(for: pipelineID) else { return nil }
        return executableURL(named: name, binDirectory: binDirectory)
    }

    func isPipelineInstalled(_ pipelineID: String) -> Bool {
        executableURL(forPipeline: pipelineID) != nil
    }

    func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let binDirectory {
            let binPath = binDirectory.path
            if let existing = env["PATH"], !existing.isEmpty {
                env["PATH"] = "\(binPath):\(existing)"
            } else {
                env["PATH"] = binPath
            }
            let venvRoot = binDirectory.deletingLastPathComponent()
            if venvRoot.lastPathComponent == "bin" {
                env["VIRTUAL_ENV"] = venvRoot.deletingLastPathComponent().path
            }
        }
        return env
    }

    private func resolveBinDirectory(config: AppConfig) -> URL? {
        let settings = config.rawSettings()
        if let raw = settings["mflux_bin_directory"] as? String, !raw.isEmpty {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
            if url.lastPathComponent == "bin", FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            let bin = url.appendingPathComponent("bin", isDirectory: true)
            if FileManager.default.fileExists(atPath: bin.path) { return bin }
        }
        if let raw = settings["mflux_venv_path"] as? String, !raw.isEmpty {
            let venv = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL
            let bin = venv.appendingPathComponent("bin", isDirectory: true)
            if FileManager.default.fileExists(atPath: bin.path) { return bin }
        }
        let imagegenBin = config.imagegenVenvURL().appendingPathComponent("bin", isDirectory: true)
        if FileManager.default.fileExists(atPath: imagegenBin.path) {
            return imagegenBin
        }
        let fallbacks = [
            "/Library/Frameworks/Python.framework/Versions/3.12/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        for path in fallbacks {
            let url = URL(fileURLWithPath: path)
            if executableURL(named: "mflux-generate", binDirectory: url) != nil {
                return url
            }
        }
        lastProbeError = "No mflux-generate found. Set MFLUX venv in Settings → Image Generation."
        return nil
    }

    private func executableURL(named: String, binDirectory: URL) -> URL? {
        let url = binDirectory.appendingPathComponent(named)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}

enum MfluxCLIPipeline {
    static func executableName(for pipelineID: String) -> String? {
        switch pipelineID {
        case "flux_schnell_mflux_play":
            return "mflux-generate"
        case "mflux_z_image_turbo":
            return "mflux-generate-z-image-turbo"
        case "mflux_fill_expand", "mflux_fill_infill":
            return "mflux-generate-fill"
        case "mflux_flux2_klein_create":
            return "mflux-generate-flux2"
        case "mflux_flux2_klein_edit", "mflux_flux2_klein_expand":
            return "mflux-generate-flux2-edit"
        default:
            return nil
        }
    }

    static func isSupported(pipelineID: String) -> Bool {
        executableName(for: pipelineID) != nil
    }

    static func buildArguments(payload: [String: Any]) throws -> [String] {
        var payload = payload
        payload.removeValue(forKey: "mflux_lora_stack")
        payload.removeValue(forKey: "mflux_lora")

        let pipelineID = payload["pipeline_id"] as? String ?? ""
        switch pipelineID {
        case "flux_schnell_mflux_play":
            return try buildFluxSchnellArgs(payload: payload)
        case "mflux_z_image_turbo":
            return try buildZImageTurboArgs(payload: payload)
        case "mflux_fill_expand", "mflux_fill_infill":
            return try buildFillArgs(payload: payload)
        case "mflux_flux2_klein_create":
            return try buildKleinCreateArgs(payload: payload)
        case "mflux_flux2_klein_edit", "mflux_flux2_klein_expand":
            return try buildKleinEditArgs(payload: payload)
        default:
            throw MfluxCLIError.unsupportedPipeline(pipelineID)
        }
    }

    private static func buildFluxSchnellArgs(payload: [String: Any], includeModel: Bool = true) throws -> [String] {
        let prompt = (payload["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw MfluxCLIError.missingField("prompt") }
        let output = payload["output_path"] as? String ?? ""
        guard !output.isEmpty else { throw MfluxCLIError.missingField("output_path") }
        let model = payload["hf_model_id"] as? String ?? payload["model"] as? String ?? "black-forest-labs/FLUX.1-schnell"
        let quantize = intValue(payload["mflux_quantize"], default: 4)
        let steps = intValue(payload["steps"], default: 4)
        let width = intValue(payload["width"], default: 1024)
        let height = intValue(payload["height"], default: 1024)
        let seed = resolvedSeed(payload)
        let guidance = doubleValue(payload["guidance_scale"], default: 3.5)
        var args: [String] = []
        if includeModel {
            args += ["--model", model]
        }
        args += [
            "-q", "\(quantize)",
            "--steps", "\(steps)",
            "--width", "\(width)",
            "--height", "\(height)",
            "--seed", "\(seed)",
            "--guidance", "\(guidance)",
            "--output", output,
            "--prompt", prompt,
        ]
        if boolValue(payload["low_ram"], default: true) {
            args.append("--low-ram")
        }
        appendMfluxProgressAndLoraFlags(to: &args, payload: payload)
        return args
    }

    static func appendMfluxProgressAndLoraFlags(to args: inout [String], payload: [String: Any]) {
        if let dir = payload["stepwise_image_output_dir"] as? String, !dir.isEmpty {
            args += ["--stepwise-image-output-dir", dir]
        }
        appendLoraCLIArgs(to: &args, payload: payload)
    }

    static func appendLoraCLIArgs(to args: inout [String], payload: [String: Any]) {
        let paths = payload["mflux_lora_paths"] as? [String] ?? []
        guard !paths.isEmpty else { return }
        args.append("--lora-paths")
        args += paths
        if let scales = payload["mflux_lora_scales"] as? [Double], !scales.isEmpty {
            args.append("--lora-scales")
            args += scales.map { String($0) }
        } else if let scales = payload["mflux_lora_scales"] as? [NSNumber], !scales.isEmpty {
            args.append("--lora-scales")
            args += scales.map { $0.stringValue }
        }
    }

    private static let zImageTurboQuantChoices: Set<Int> = [3, 4, 5, 6, 8]

    private static func buildZImageTurboArgs(payload: [String: Any]) throws -> [String] {
        var copy = payload
        let quantize = intValue(copy["mflux_quantize"], default: 4)
        guard zImageTurboQuantChoices.contains(quantize) else {
            throw MfluxCLIError.processFailed(
                "mflux_quantize must be one of \(zImageTurboQuantChoices.sorted())"
            )
        }
        copy["mflux_quantize"] = quantize
        // mflux-generate-z-image-turbo already targets Z-Image Turbo; do not pass --model.
        return try buildFluxSchnellArgs(payload: copy, includeModel: false)
    }

    private static func buildFillArgs(payload: [String: Any]) throws -> [String] {
        let prompt = (payload["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let output = payload["output_path"] as? String ?? ""
        guard !output.isEmpty else { throw MfluxCLIError.missingField("output_path") }
        let source = payload["source_image_path"] as? String
            ?? (payload["source_image_paths"] as? [String])?.first
        guard let source, !source.isEmpty else { throw MfluxCLIError.missingField("source_image_path") }
        let model = payload["hf_model_id"] as? String ?? "black-forest-labs/FLUX.1-Fill-dev"
        let quantize = intValue(payload["mflux_quantize"], default: 4)
        let steps = intValue(payload["steps"], default: 20)
        let width = intValue(payload["width"], default: 1024)
        let height = intValue(payload["height"], default: 1024)
        let seed = resolvedSeed(payload)
        let guidance = doubleValue(payload["guidance_scale"], default: 30)
        var args = [
            "--model", model,
            "-q", "\(quantize)",
            "--steps", "\(steps)",
            "--width", "\(width)",
            "--height", "\(height)",
            "--seed", "\(seed)",
            "--guidance", "\(guidance)",
            "--image-path", source,
            "--output", output,
        ]
        if !prompt.isEmpty {
            args += ["--prompt", prompt]
        }
        if let mask = payload["mask_image_path"] as? String, !mask.isEmpty {
            args += ["--masked-image-path", mask]
        }
        if boolValue(payload["low_ram"], default: true) {
            args.append("--low-ram")
        }
        appendMfluxProgressAndLoraFlags(to: &args, payload: payload)
        return args
    }

    private static func buildKleinCreateArgs(payload: [String: Any]) throws -> [String] {
        let prompt = (payload["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw MfluxCLIError.missingField("prompt") }
        let output = payload["output_path"] as? String ?? ""
        let params = try MfluxKleinCLI.resolve(payload: payload)
        var args: [String] = []
        MfluxKleinCLI.appendCommonArgs(
            to: &args,
            params: params,
            payload: payload,
            output: output,
            prompt: prompt,
            includeSize: true
        )
        return args
    }

    private static func buildKleinEditArgs(payload: [String: Any]) throws -> [String] {
        let prompt = (payload["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw MfluxCLIError.missingField("prompt") }
        let output = payload["output_path"] as? String ?? ""
        let source = payload["source_image_path"] as? String
            ?? (payload["source_image_paths"] as? [String])?.first
        guard let source, !source.isEmpty else { throw MfluxCLIError.missingField("source_image_path") }
        let params = try MfluxKleinCLI.resolve(payload: payload)
        var args: [String] = []
        MfluxKleinCLI.appendCommonArgs(
            to: &args,
            params: params,
            payload: payload,
            output: output,
            prompt: prompt,
            includeSize: false
        )
        args += ["--image-path", source]
        if let w = payload["width"] as? Int, w > 0, let h = payload["height"] as? Int, h > 0 {
            args += ["--width", "\(w)", "--height", "\(h)"]
        }
        return args
    }

    private static func resolvedSeed(_ payload: [String: Any]) -> Int {
        if let seed = payload["resolved_seed"] as? Int {
            return seed % 2_147_483_648
        }
        if let seed = payload["resolved_seed"] as? NSNumber {
            return seed.intValue % 2_147_483_648
        }
        if boolValue(payload["random_seed"], default: true) {
            return Int.random(in: 0...(2_147_483_647))
        }
        return intValue(payload["seed"], default: 0) % 2_147_483_648
    }

    private static func intValue(_ value: Any?, default defaultValue: Int) -> Int {
        if let v = value as? Int { return v }
        if let v = value as? NSNumber { return v.intValue }
        if let v = value as? String, let i = Int(v) { return i }
        return defaultValue
    }

    private static func doubleValue(_ value: Any?, default defaultValue: Double) -> Double {
        if let v = value as? Double { return v }
        if let v = value as? NSNumber { return v.doubleValue }
        if let v = value as? String, let d = Double(v) { return d }
        return defaultValue
    }

    private static func boolValue(_ value: Any?, default defaultValue: Bool) -> Bool {
        if let v = value as? Bool { return v }
        if let v = value as? NSNumber { return v.boolValue }
        return defaultValue
    }
}

enum MfluxCLIError: LocalizedError {
    case unsupportedPipeline(String)
    case missingField(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPipeline(let id):
            return "No MFLUX CLI mapping for pipeline \(id)."
        case .missingField(let field):
            return "Missing required field: \(field)"
        case .processFailed(let message):
            return message
        }
    }
}
