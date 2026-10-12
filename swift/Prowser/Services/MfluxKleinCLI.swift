import Foundation

struct MfluxKleinCLIParams {
    let baseModel: String
    let modelArgument: String
    let quantize: Int?
}

enum MfluxKleinCLI {
    private static let allowedQuant: Set<Int> = [3, 4, 5, 6, 8]
    static let minSteps = 2

    static func resolve(payload: [String: Any]) throws -> MfluxKleinCLIParams {
        let hfModel = (payload["hf_model_id"] as? String ?? payload["model"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hfModel.isEmpty else { throw MfluxCLIError.missingField("hf_model_id") }

        if ImageGenSceneWorksKlein.isSceneWorksRepo(hfModel) {
            let tier = ImageGenSceneWorksKlein.normalizeMLXTier(payload["mlx_tier"])
            guard let path = ImageGenSceneWorksKlein.resolveTierModelPath(repoID: hfModel, tier: tier) else {
                throw MfluxCLIError.processFailed(
                    "\(hfModel) (\(tier.uppercased()) tier) is not installed. "
                    + "Download it from Tools > Manage models, then try again."
                )
            }
            return MfluxKleinCLIParams(
                baseModel: "flux2-klein-9b-kv",
                modelArgument: path,
                quantize: nil
            )
        }

        let quantize = intValue(payload["mflux_quantize"], default: 4)
        guard allowedQuant.contains(quantize) else {
            throw MfluxCLIError.processFailed("mflux_quantize must be one of \(allowedQuant.sorted())")
        }
        return MfluxKleinCLIParams(
            baseModel: baseModel(forHFModelID: hfModel),
            modelArgument: hfModel,
            quantize: quantize
        )
    }

    static func appendCommonArgs(
        to args: inout [String],
        params: MfluxKleinCLIParams,
        payload: [String: Any],
        output: String,
        prompt: String,
        includeSize: Bool
    ) {
        args += ["--base-model", params.baseModel, "--model", params.modelArgument]
        if let quantize = params.quantize {
            args += ["--quantize", "\(quantize)"]
        }
        let steps = intValue(payload["steps"], default: 4)
        let seed = resolvedSeed(payload)
        args += [
            "--steps", "\(steps)",
            "--seed", "\(seed)",
            "--guidance", "1",
            "--output", output,
            "--prompt", prompt,
        ]
        if includeSize {
            let width = intValue(payload["width"], default: 1024)
            let height = intValue(payload["height"], default: 1024)
            args += ["--width", "\(width)", "--height", "\(height)"]
        }
        if boolValue(payload["low_ram"], default: true) {
            args.append("--low-ram")
        }
        if let dir = payload["stepwise_image_output_dir"] as? String, !dir.isEmpty {
            args += ["--stepwise-image-output-dir", dir]
        }
        MfluxCLIPipeline.appendLoraCLIArgs(to: &args, payload: payload)
    }

    private static func baseModel(forHFModelID hf: String) -> String {
        let lower = hf.lowercased()
        if lower.contains("klein-4b") || lower.contains("klein_4b") {
            return "flux2-klein-4b"
        }
        if lower.contains("9b-kv") || lower.contains("9b_kv") {
            return "flux2-klein-9b-kv"
        }
        if lower.contains("klein-9b") || lower.contains("klein_9b") {
            return "flux2-klein-9b"
        }
        return "flux2-klein-4b"
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

    private static func boolValue(_ value: Any?, default defaultValue: Bool) -> Bool {
        if let v = value as? Bool { return v }
        if let v = value as? NSNumber { return v.boolValue }
        return defaultValue
    }
}
