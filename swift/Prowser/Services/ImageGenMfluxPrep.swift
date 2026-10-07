import Foundation

/// Prepares registry payloads before MFLUX CLI invocation.
enum ImageGenMfluxPrep {
    /// MFLUX CLI target (temp); final ``output_path`` is copied here after success (Python ``mflux_output_path``).
    static func mfluxTempOutputPath(for finalOutputPath: String) -> String {
        let ext = (finalOutputPath as NSString).pathExtension
        let suffix = ext.isEmpty ? ".png" : ".\(ext)"
        let dir = ProwserTempFiles.imageGenProgressDirectory()
        return (dir as NSString).appendingPathComponent("imagegen-mflux-\(UUID().uuidString)\(suffix)")
    }

    static func promoteMfluxOutput(cliPath: String, finalPath: String) throws {
        guard cliPath != finalPath else { return }
        guard FileManager.default.fileExists(atPath: cliPath) else {
            throw MfluxCLIError.processFailed("MFLUX temp output missing at \(cliPath)")
        }
        let dstURL = URL(fileURLWithPath: finalPath)
        try FileManager.default.createDirectory(
            at: dstURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tmp = dstURL.deletingLastPathComponent()
            .appendingPathComponent(".imagegen-out-\(UUID().uuidString).partial")
        if FileManager.default.fileExists(atPath: tmp.path) {
            try? FileManager.default.removeItem(at: tmp)
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: cliPath), to: tmp)
        if FileManager.default.fileExists(atPath: finalPath) {
            try FileManager.default.removeItem(at: dstURL)
        }
        try FileManager.default.moveItem(at: tmp, to: dstURL)
        try? FileManager.default.removeItem(atPath: cliPath)
    }

    static func apply(to payload: [String: Any]) async throws -> [String: Any] {
        var run = payload

        let pipelineID = run["pipeline_id"] as? String ?? ""
        let steps = intValue(run["steps"], default: 4)
        let outputPath = run["output_path"] as? String ?? ""
        let (stepwiseDir, progressivePath) = stepwisePaths(steps: steps, outputPath: outputPath)
        run["stepwise_image_output_dir"] = stepwiseDir
        run["progressive_output_path"] = progressivePath

        if boolValue(run["random_seed"], default: true) {
            let seed = Int.random(in: 0...(2_147_483_647))
            run["resolved_seed"] = seed
            run["seed"] = seed
            run["random_seed"] = false
        } else {
            run["resolved_seed"] = intValue(run["seed"], default: 0)
        }

        switch pipelineID {
        case "mflux_fill_expand":
            try applyFillExpand(&run)
        case "mflux_fill_infill":
            try validateInfill(&run)
        case "mflux_flux2_klein_expand":
            try applyKleinExpand(&run)
        case "mflux_flux2_klein_edit":
            try applyKleinEdit(&run)
        case "mflux_flux2_klein_create":
            try applyKleinCreate(&run)
        default:
            break
        }
        return run
    }

    static func finalizeKleinExpandIfNeeded(payload: [String: Any], cliOutputPath: String) throws -> String {
        guard payload["pipeline_id"] as? String == "mflux_flux2_klein_expand",
              let meta = payload["_klein_expand_post"] as? [String: String],
              let finalPath = meta["final_output"],
              let bgPath = meta["background"],
              let maskPath = meta["mask"] else {
            return cliOutputPath
        }
        guard let generated = ImageGenOutpaintMask.loadCGImage(path: cliOutputPath),
              let background = ImageGenOutpaintMask.loadCGImage(path: bgPath),
              let mask = ImageGenOutpaintMask.loadCGImage(path: maskPath) else {
            return cliOutputPath
        }
        let final = ImageGenOutpaintMask.applyExpandKeepMask(
            generated: generated,
            background: background,
            mask: mask
        )
        _ = ImageGenOutpaintMask.savePNG(final, path: finalPath)
        try? FileManager.default.removeItem(atPath: cliOutputPath)
        return finalPath
    }

    private static func applyFillExpand(_ run: inout [String: Any]) throws {
        let source = run["source_image_path"] as? String
            ?? (run["source_image_paths"] as? [String])?.first
        guard let source, FileManager.default.isReadableFile(atPath: source),
              let cg = ImageGenOutpaintMask.loadCGImage(path: source) else {
            throw MfluxCLIError.missingField("source_image_path")
        }
        let maxSide = intValue(run["max_generation_dimension"], default: 1024)
        let (w, h) = ImageGenOutpaintMask.clampOutpaintDims(
            width: intValue(run["width"], default: 1024),
            height: intValue(run["height"], default: 1024),
            maxSide: maxSide
        )
        run["width"] = w
        run["height"] = h
        let px = intValue(run["placement_x"], default: 0)
        let py = intValue(run["placement_y"], default: 0)
        let pw = intValue(run["placement_w"], default: w)
        let ph = intValue(run["placement_h"], default: h)
        let overlap = max(0, min(20, intValue(run["overlap_percentage"], default: 2)))
        let (background, mask) = ImageGenOutpaintMask.prepareImageAndMaskAtRect(
            source: cg,
            canvasW: w,
            canvasH: h,
            x: px,
            y: py,
            w: pw,
            h: ph,
            overlapPercentage: overlap
        )
        let basePath = tempPNG(prefix: "imagegen-expand-base-")
        _ = ImageGenOutpaintMask.savePNG(background, path: basePath)
        let maskPath = tempPNG(prefix: "imagegen-expand-mask-")
        _ = ImageGenOutpaintMask.savePNG(mask, path: maskPath)
        run["source_image_path"] = basePath
        run["source_image_paths"] = [basePath]
        run["mask_image_path"] = maskPath
    }

    private static func validateInfill(_ run: inout [String: Any]) throws {
        let base = run["infill_base_image_path"] as? String ?? run["source_image_path"] as? String
        let mask = run["infill_mask_image_path"] as? String ?? run["mask_image_path"] as? String
        guard let base, FileManager.default.isReadableFile(atPath: base) else {
            throw MfluxCLIError.missingField("infill_base_image_path")
        }
        guard let mask, FileManager.default.isReadableFile(atPath: mask) else {
            throw MfluxCLIError.missingField("infill_mask_image_path")
        }
        run["source_image_path"] = base
        run["mask_image_path"] = mask
    }

    private static func applyKleinExpand(_ run: inout [String: Any]) throws {
        let source = run["source_image_path"] as? String ?? ""
        guard let cg = ImageGenOutpaintMask.loadCGImage(path: source) else {
            throw MfluxCLIError.missingField("source_image_path")
        }
        // let maxSide = intValue(run["max_generation_dimension"], default: 2048)
        let w = intValue(run["width"], default: 1024)
        let h = intValue(run["height"], default: 1024)
        let px = intValue(run["placement_x"], default: 0)
        let py = intValue(run["placement_y"], default: 0)
        let pw = intValue(run["placement_w"], default: w)
        let ph = intValue(run["placement_h"], default: h)
        let overlap = max(0, min(20, intValue(run["overlap_percentage"], default: 2)))
        let (background, mask) = ImageGenOutpaintMask.prepareImageAndMaskAtRect(
            source: cg,
            canvasW: w,
            canvasH: h,
            x: px,
            y: py,
            w: pw,
            h: ph,
            overlapPercentage: overlap
        )
        let bgPath = tempPNG(prefix: "imagegen-klein-expand-bg-")
        let maskPath = tempPNG(prefix: "imagegen-klein-expand-mask-")
        _ = ImageGenOutpaintMask.savePNG(background, path: bgPath)
        _ = ImageGenOutpaintMask.savePNG(mask, path: maskPath)
        let composite = ImageGenOutpaintMask.compositeMaskedRegionsForKleinEdit(background: background, mask: mask)
        let compositePath = tempPNG(prefix: "imagegen-klein-expand-composite-")
        _ = ImageGenOutpaintMask.savePNG(composite, path: compositePath)
        let kleinOut = tempPNG(prefix: "imagegen-klein-expand-out-")
        let finalOutput = run["output_path"] as? String ?? kleinOut
        run["source_image_path"] = compositePath
        run["source_image_paths"] = [compositePath]
        run["output_path"] = kleinOut
        run["_klein_expand_post"] = [
            "final_output": finalOutput,
            "background": bgPath,
            "mask": maskPath,
        ]
    }

    private static func applyKleinEdit(_ run: inout [String: Any]) throws {
        if let paths = run["_aspect_pad_temp_paths"] as? [String] {
            for path in paths where FileManager.default.isReadableFile(atPath: path) {
                run["source_image_path"] = path
                run["source_image_paths"] = [path]
                break
            }
        }
        guard let source = run["source_image_path"] as? String,
              FileManager.default.isReadableFile(atPath: source) else {
            throw MfluxCLIError.missingField("source_image_path")
        }
        if run["width"] == nil || run["height"] == nil,
           let cg = ImageGenOutpaintMask.loadCGImage(path: source) {
            run["width"] = cg.width
            run["height"] = cg.height
        }
    }

    private static func applyKleinCreate(_ run: inout [String: Any]) throws {
        let maxSide = intValue(run["max_generation_dimension"], default: 2048)
        let w = intValue(run["width"], default: 1024)
        let h = intValue(run["height"], default: 1024)
        let aligned = ImageGenDimMath.alignDimsForPipeline(
            pipelineID: "mflux_flux2_klein_create",
            width: w,
            height: h,
            effectiveMaxSide: maxSide
        )
        run["width"] = aligned.width
        run["height"] = aligned.height
        let steps = max(MfluxKleinCLI.minSteps, min(50, intValue(run["steps"], default: 4)))
        run["steps"] = steps
        if let sources = run["source_image_paths"] as? [String], !sources.isEmpty {
            run["pipeline_id"] = "mflux_flux2_klein_edit"
            try applyKleinEdit(&run)
        }
    }

    private static func stepwisePaths(steps: Int, outputPath: String) -> (String, String) {
        let dir = StepwisePaths.makeStepwiseDir(steps: steps)
        let progressive = outputPath.isEmpty ? "" : outputPath
        return (dir, progressive)
    }

    private static func tempPNG(prefix: String) -> String {
        let dir = ProwserTempFiles.imageGenProgressDirectory()
        return (dir as NSString).appendingPathComponent("\(prefix)\(UUID().uuidString).png")
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
