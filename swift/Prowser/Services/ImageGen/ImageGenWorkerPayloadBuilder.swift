import Foundation

/// Port of ``image_gen_pipeline_modes.build_worker_payload``.
@MainActor
enum ImageGenWorkerPayloadBuilder {
    static func build(
        plugin: ImageGenPluginDescriptor,
        values: [String: Any],
        outputPath: String,
        config: AppConfig,
        applyImageExit: Bool
    ) throws -> [String: Any] {
        var runValues = values
        ImageGenPromptSentenceCase.flushPromptValues(&runValues)
        runValues.removeValue(forKey: JobStepQueue.fluxPromptAIJobKey)
        var pipelineID = plugin.pipelineID
        let effectiveMax = ImageGenDimLimits.effectiveMaxGenerationDimension(
            pluginMax: ImageGenPluginMetadata.maxGenerationDimension(pluginID: plugin.pluginID),
            settings: config.rawSettings()
        )
        var merged = ImageGenPipelineModes.finalizeRunValues(
            pipelineID: pipelineID,
            values: runValues,
            config: config
        )
        merged["pipeline_id"] = pipelineID
        merged["output_path"] = outputPath
        merged["hf_model_id"] = plugin.hfModelID
        merged["max_generation_dimension"] = effectiveMax
        merged["debug_mode"] = config.bool(forKey: "debug_mode", default: false)
        merged["prowser_profile"] = config.prowserHome.path

        let mode = ImageGenPipelineModes.mode(pipelineID: pipelineID)
        if mode?.includesOutputDimensions == true {
            let uiW = intValue(merged["width"]) ?? 1024
            let uiH = intValue(merged["height"]) ?? 1024
            let aligned = ImageGenDimMath.alignDimsForPipeline(
                pipelineID: pipelineID,
                width: uiW,
                height: uiH,
                effectiveMaxSide: effectiveMax
            )
            if pipelineID == "mflux_flux2_klein_expand" || pipelineID == "mflux_fill_expand" {
                ExpandPlacementMath.remapPlacementAfterCanvasResize(
                    values: &merged,
                    fromCanvasW: uiW,
                    fromCanvasH: uiH,
                    toCanvasW: aligned.width,
                    toCanvasH: aligned.height
                )
            }
            merged["width"] = aligned.width
            merged["height"] = aligned.height
        }

        if ["flux_schnell_mflux_play", "mflux_fill_expand", "mflux_fill_infill", "mflux_z_image_turbo"].contains(pipelineID) {
            merged.removeValue(forKey: "copies")
            applyMfluxLoraStub(&merged)
        }
        if pipelineID == "mflux_flux2_klein_create" {
            applyMfluxLoraStub(&merged)
            let sources = ImageGenExifReferences.resolveSourceImagePaths(merged)
            if !sources.isEmpty {
                pipelineID = "mflux_flux2_klein_edit"
                merged["pipeline_id"] = pipelineID
            }
        }
        if pipelineID == "sd15_diffusers" || pipelineID == "sdxl_diffusers" {
            merged.removeValue(forKey: "copies")
        }
        if pipelineID == "mflux_flux2_klein_expand" {
            applyMfluxLoraStub(&merged)
            attachSourcePaths(&merged, canonical: true)
            merged["prompt"] = ImageGenPipelineModes.kleinExpandPrompt(merged["prompt"] as? String ?? "")
        }
        if pipelineID == "mflux_flux2_klein_edit" {
            applyMfluxLoraStub(&merged)
            var sourcePaths = ImageGenExifReferences.resolveSourceImagePaths(merged)
            if !sourcePaths.isEmpty {
                merged["_canonical_source_image_paths"] = sourcePaths
                merged["source_image_paths"] = sourcePaths
                merged["source_image_path"] = sourcePaths[0]
                var padTemps: [String] = []
                if ImageGenPipelineModes.boolFromSettingsValue(merged["use_custom_size"]) {
                    let targetW = intValue(merged["width"]) ?? 0
                    let targetH = intValue(merged["height"]) ?? 0
                    if targetW > 0, targetH > 0 {
                        let expanded = ImageGenEditAspectPad.generatorPathsWithScreenSizeExpansion(
                            sourcePaths: sourcePaths,
                            targetWidth: targetW,
                            targetHeight: targetH,
                            tempRoot: config.temporaryFilesDirectory
                        )
                        sourcePaths = expanded.generatorPaths
                        padTemps.append(contentsOf: expanded.tempPaths)
                    }
                }
                if ImageGenPipelineModes.boolFromSettingsValue(merged["aspect_ratio_test"]) {
                    let padded = ImageGenEditAspectPad.generatorPathsWithAspectPadding(
                        sourcePaths: sourcePaths,
                        tempRoot: config.temporaryFilesDirectory
                    )
                    sourcePaths = padded.generatorPaths
                    padTemps.append(contentsOf: padded.tempPaths)
                }
                merged["source_image_paths"] = sourcePaths
                merged["source_image_path"] = sourcePaths[0]
                if !padTemps.isEmpty {
                    merged["_aspect_pad_temp_paths"] = padTemps
                }
            }
            merged.removeValue(forKey: "width")
            merged.removeValue(forKey: "height")
        }
        if pipelineID == "mflux_fill_expand" {
            attachSourcePaths(&merged, canonical: true)
        }
        if pipelineID == "mflux_fill_infill" {
            let missing = InfillExportService.missingInfillExportPaths(merged)
            if !missing.isEmpty {
                let preview = missing.prefix(3).joined(separator: ", ")
                throw ImageGenRegistryError.payload(
                    "Infill base image or mask is not available on disk (\(preview)). "
                        + "Re-run infill from the paint or Pixelmator dialog."
                )
            }
            attachInfillCanonicalSourcePaths(
                &merged,
                tempRoot: config.temporaryFilesDirectory.path
            )
        }

        merged.removeValue(forKey: "aspect_ratio_lock")
        merged.removeValue(forKey: "_pixelmator_batch_dir")
        merged.removeValue(forKey: "series_refinement")
        merged.removeValue(forKey: "series_prompt_refinement")
        merged.removeValue(forKey: "aspect_ratio_test")
        merged.removeValue(forKey: "use_custom_size")
        merged.removeValue(forKey: "pass_image_to_ai_with_prompt")

        if applyImageExit {
            merged = ImageGenMfluxPayloadBuilder.applyImagePromptRules(values: merged, config: config)
        }
        return merged
    }

    private static func attachSourcePaths(_ merged: inout [String: Any], canonical: Bool = false) {
        let sources = ImageGenExifReferences.resolveSourceImagePaths(merged)
        guard !sources.isEmpty else { return }
        if canonical {
            merged["_canonical_source_image_paths"] = sources
        }
        merged["source_image_paths"] = sources
        merged["source_image_path"] = sources[0]
    }

    private static func attachInfillCanonicalSourcePaths(_ merged: inout [String: Any], tempRoot: String) {
        guard let canonical = infillCanonicalSourcePath(from: merged, tempRoot: tempRoot) else { return }
        merged["_canonical_source_image_paths"] = [canonical]
    }

    private static func infillCanonicalSourcePath(from values: [String: Any], tempRoot: String) -> String? {
        for raw in ImageGenExifReferences.resolveSourceImagePaths(values) {
            let ap = URL(fileURLWithPath: raw).standardizedFileURL.path
            if FileManager.default.isReadableFile(atPath: ap),
               !ImageGenInfillPathSemantics.isWorkingTempPath(ap, tempRoot: tempRoot) {
                return ap
            }
        }
        let doc = (values["pixelmator_doc_path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !doc.isEmpty {
            let ap = URL(fileURLWithPath: doc).standardizedFileURL.path
            if FileManager.default.isReadableFile(atPath: ap),
               !ImageGenInfillPathSemantics.isWorkingTempPath(ap, tempRoot: tempRoot) {
                return ap
            }
        }
        return nil
    }

    private static func applyMfluxLoraStub(_ merged: inout [String: Any]) {
        if merged["mflux_lora_stack"] == nil {
            merged["mflux_lora_stack"] = []
        }
        merged.removeValue(forKey: "mflux_lora")
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
