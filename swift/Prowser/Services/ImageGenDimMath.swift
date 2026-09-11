import Foundation

/// Port of `imagegen_plugins/image_gen_dialog.py` dimension math and
/// `imagegen_plugins/image_gen_pipeline_modes.py` alignment helpers.
enum ImageGenDimMath {
    struct Bounds {
        let min: Int
        let max: Int
    }

    // MARK: - Snapping

    static func snapDimFloor(_ value: Int, step: Int) -> Int {
        let s = max(1, step)
        return (value / s) * s
    }

    // MARK: - Aspect pairs

    static func aspectPairFromWidth(
        width: Int,
        ratio: Double,
        wBounds: Bounds,
        hBounds: Bounds,
        step: Int
    ) -> (width: Int, height: Int) {
        let r = ratio > 0 ? ratio : 1.0
        var w = snapDimFloor(width, step: step)
        w = max(wBounds.min, min(wBounds.max, w))
        var h = snapDimFloor(Int(round(Double(w) / r)), step: step)
        h = max(hBounds.min, min(hBounds.max, h))
        w = snapDimFloor(Int(round(Double(h) * r)), step: step)
        w = max(wBounds.min, min(wBounds.max, w))
        h = snapDimFloor(Int(round(Double(w) / r)), step: step)
        h = max(hBounds.min, min(hBounds.max, h))
        return (w, h)
    }

    static func aspectPairFromHeight(
        height: Int,
        ratio: Double,
        wBounds: Bounds,
        hBounds: Bounds,
        step: Int
    ) -> (width: Int, height: Int) {
        let r = ratio > 0 ? ratio : 1.0
        var h = snapDimFloor(height, step: step)
        h = max(hBounds.min, min(hBounds.max, h))
        var w = snapDimFloor(Int(round(Double(h) * r)), step: step)
        w = max(wBounds.min, min(wBounds.max, w))
        h = snapDimFloor(Int(round(Double(w) / r)), step: step)
        h = max(hBounds.min, min(hBounds.max, h))
        w = snapDimFloor(Int(round(Double(h) * r)), step: step)
        w = max(wBounds.min, min(wBounds.max, w))
        return (w, h)
    }

    static func nextAspectLockedDims(
        changed: String,
        direction: Int,
        currentW: Int,
        currentH: Int,
        ratio: Double,
        wBounds: Bounds,
        hBounds: Bounds,
        step: Int
    ) -> (width: Int, height: Int) {
        guard direction == -1 || direction == 1 else {
            return (currentW, currentH)
        }
        let s = max(1, step)
        if changed == "width" {
            var probe = currentW + direction * s
            while probe >= wBounds.min && probe <= wBounds.max {
                let pair = aspectPairFromWidth(
                    width: probe,
                    ratio: ratio,
                    wBounds: wBounds,
                    hBounds: hBounds,
                    step: s
                )
                if pair.width != currentW || pair.height != currentH {
                    return pair
                }
                probe += direction * s
            }
            return (currentW, currentH)
        }
        var probe = currentH + direction * s
        while probe >= hBounds.min && probe <= hBounds.max {
            let pair = aspectPairFromHeight(
                height: probe,
                ratio: ratio,
                wBounds: wBounds,
                hBounds: hBounds,
                step: s
            )
            if pair.width != currentW || pair.height != currentH {
                return pair
            }
            probe += direction * s
        }
        return (currentW, currentH)
    }

    // MARK: - Max-side scaling

    static func scaleDimsToMaxSide(
        width: Int,
        height: Int,
        effectiveMaxSide: Int
    ) -> (width: Int, height: Int) {
        let w = width
        let h = height
        let maxSide = effectiveMaxSide
        if w <= 0 || h <= 0 || maxSide <= 0 {
            return (w, h)
        }
        let scale = min(1.0, Double(maxSide) / Double(w), Double(maxSide) / Double(h))
        if scale >= 1.0 {
            return (w, h)
        }
        return (Int(Double(w) * scale), Int(Double(h) * scale))
    }

    // MARK: - Pipeline alignment

    private static func alignFluxDims(w: Int, h: Int, maxSide: Int) -> (Int, Int) {
        let width = max(256, min(maxSide, (w / 8) * 8))
        let height = max(256, min(maxSide, (h / 8) * 8))
        return (width, height)
    }

    private static func alignMfluxDims(w: Int, h: Int, maxSide: Int) -> (Int, Int) {
        let (aw, ah) = alignFluxDims(w: w, h: h, maxSide: maxSide)
        let width = max(256, min(maxSide, (aw / 16) * 16))
        let height = max(256, min(maxSide, (ah / 16) * 16))
        return (width, height)
    }

    private static func alignMfluxFlux2KleinDims(w: Int, h: Int, maxSide: Int) -> (Int, Int) {
        var width = w
        var height = h
        if width > 0 && height > 0 && maxSide > 0 {
            let scale = min(1.0, Double(maxSide) / Double(width), Double(maxSide) / Double(height))
            width = Int(Double(width) * scale)
            height = Int(Double(height) * scale)
        }
        width = max(256, min(maxSide, (width / 16) * 16))
        height = max(256, min(maxSide, (height / 16) * 16))
        return (width, height)
    }

    private static func alignSd15Dims(w: Int, h: Int, maxSide: Int) -> (Int, Int) {
        let width = max(256, min(maxSide, (w / 8) * 8))
        let height = max(256, min(maxSide, (h / 8) * 8))
        return (width, height)
    }

    private static func alignSdxlDims(w: Int, h: Int, maxSide: Int) -> (Int, Int) {
        let width = max(256, min(maxSide, (w / 8) * 8))
        let height = max(256, min(maxSide, (h / 8) * 8))
        return (width, height)
    }

    private static func alignZImageDims(w: Int, h: Int, maxSide: Int) -> (Int, Int) {
        let width = max(256, min(maxSide, (w / 16) * 16))
        let height = max(256, min(maxSide, (h / 16) * 16))
        return (width, height)
    }

    static func alignDimsForPipeline(
        pipelineID: String,
        width: Int,
        height: Int,
        effectiveMaxSide: Int,
        dimStep: Int = 16,
        widthMin: Int = 256,
        heightMin: Int = 256
    ) -> (width: Int, height: Int) {
        let maxSide = effectiveMaxSide
        var (w, h) = scaleDimsToMaxSide(width: width, height: height, effectiveMaxSide: maxSide)

        switch pipelineID {
        case "flux_schnell_mflux_play":
            return alignMfluxDims(w: w, h: h, maxSide: maxSide)
        case "mflux_flux2_klein_create", "mflux_flux2_klein_expand":
            return alignMfluxFlux2KleinDims(w: w, h: h, maxSide: maxSide)
        case "sd15_diffusers":
            return alignSd15Dims(w: w, h: h, maxSide: maxSide)
        case "sdxl_diffusers":
            return alignSdxlDims(w: w, h: h, maxSide: maxSide)
        case "z_image_turbo_sdnq", "mflux_z_image_turbo":
            return alignZImageDims(w: w, h: h, maxSide: maxSide)
        default:
            let step = max(1, dimStep)
            w = max(widthMin, w - (w % step))
            h = max(heightMin, h - (h % step))
            return (w, h)
        }
    }

    // MARK: - Area scaling

    static func scaleDimsForAreaMultiplier(
        width: Int,
        height: Int,
        multiplier: Double,
        pipelineID: String,
        effectiveMaxSide: Int,
        wBounds: Bounds,
        hBounds: Bounds,
        step: Int,
        ratio: Double,
        widthMin: Int = 256,
        heightMin: Int = 256
    ) -> (width: Int, height: Int) {
        let w = width
        let h = height
        if w <= 0 || h <= 0 || multiplier <= 0 {
            return (w, h)
        }
        let r = ratio > 0 ? ratio : (h > 0 ? Double(w) / Double(h) : 1.0)
        let targetArea = Double(w * h) * multiplier
        let idealW = sqrt(targetArea * r)
        let s = max(1, step)

        func candidate(probeW: Int) -> (Int, Int) {
            let (cw, ch) = aspectPairFromWidth(
                width: probeW,
                ratio: r,
                wBounds: wBounds,
                hBounds: hBounds,
                step: s
            )
            let (aw, _) = alignDimsForPipeline(
                pipelineID: pipelineID,
                width: cw,
                height: ch,
                effectiveMaxSide: effectiveMaxSide,
                dimStep: s,
                widthMin: widthMin,
                heightMin: heightMin
            )
            return aspectPairFromWidth(
                width: aw,
                ratio: r,
                wBounds: wBounds,
                hBounds: hBounds,
                step: s
            )
        }

        var bestW = w
        var bestH = h
        var bestErr = abs(Double(w * h) - targetArea)
        let baseW = snapDimFloor(Int(round(idealW)), step: s)
        let probeSpan = s * 5
        let start = max(wBounds.min, baseW - probeSpan)
        let end = min(wBounds.max, baseW + probeSpan)
        var probe = start
        while probe <= end {
            let (cw, ch) = candidate(probeW: probe)
            let err = abs(Double(cw * ch) - targetArea)
            if err < bestErr {
                bestErr = err
                bestW = cw
                bestH = ch
            }
            probe += s
        }
        return (bestW, bestH)
    }

    /// Re-read app max and clamp current dims (port of `_apply_effective_max_to_dim_sliders`).
    static func applyEffectiveMax(
        width: Int,
        height: Int,
        effectiveMaxSide: Int
    ) -> (width: Int, height: Int, scaledDown: Bool) {
        let (w, h) = scaleDimsToMaxSide(
            width: width,
            height: height,
            effectiveMaxSide: effectiveMaxSide
        )
        let scaledDown = w < width || h < height
        return (w, h, scaledDown)
    }

    static func pageStep(minValue: Int, maxValue: Int, dimStep: Int) -> Int {
        let range = max(0, maxValue - minValue)
        let raw = max(dimStep, range / 10)
        return max(dimStep, (raw / max(1, dimStep)) * dimStep)
    }
}
