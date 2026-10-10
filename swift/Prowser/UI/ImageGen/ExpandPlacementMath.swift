import Foundation

/// Pure placement math ported from Python ``expand_placement_canvas``.
enum ExpandPlacementMath {
    static let minPlacementEdge = 128

    struct RelativePlacement: Equatable {
        var centerXFraction: Double
        var centerYFraction: Double
        var widthFraction: Double
        var placementAspect: Double
    }

    static func clampSizeInCanvas(w: Int, h: Int, maxW: Int, maxH: Int) -> (Int, Int) {
        let mw = max(minPlacementEdge, maxW)
        let mh = max(minPlacementEdge, maxH)
        let cw = max(minPlacementEdge, min(w, mw))
        let ch = max(minPlacementEdge, min(h, mh))
        return (cw, ch)
    }

    static func clampAspectSize(
        w: Int,
        h: Int,
        aspect: Double,
        maxW: Int,
        maxH: Int
    ) -> (Int, Int) {
        let aspectClamped = max(0.01, aspect)
        let maxWClamped = max(minPlacementEdge, maxW)
        let maxHClamped = max(minPlacementEdge, maxH)

        var wf = Double(max(1, w))
        var hf = wf / aspectClamped

        func fitMax() {
            let scale = min(1.0, Double(maxWClamped) / wf, Double(maxHClamped) / hf)
            wf *= scale
            hf = wf / aspectClamped
        }

        func fitMin() {
            let scale = max(
                1.0,
                Double(minPlacementEdge) / wf,
                Double(minPlacementEdge) / hf
            )
            wf *= scale
            hf = wf / aspectClamped
        }

        fitMax()
        fitMin()
        fitMax()

        var wi = Int(round(wf))
        var hi = Int(round(Double(wi) / aspectClamped))
        if hi > maxHClamped {
            hi = maxHClamped
            wi = Int(round(Double(hi) * aspectClamped))
        }
        if wi > maxWClamped {
            wi = maxWClamped
            hi = Int(round(Double(wi) / aspectClamped))
        }
        if wi < minPlacementEdge {
            wi = minPlacementEdge
            hi = Int(round(Double(wi) / aspectClamped))
        }
        if hi < minPlacementEdge {
            hi = minPlacementEdge
            wi = Int(round(Double(hi) * aspectClamped))
            wi = min(wi, maxWClamped)
            hi = Int(round(Double(wi) / aspectClamped))
        }

        wi = max(minPlacementEdge, min(wi, maxWClamped))
        hi = max(minPlacementEdge, min(Int(round(Double(wi) / aspectClamped)), maxHClamped))
        if Int(round(Double(wi) / aspectClamped)) != hi, hi == maxHClamped {
            wi = max(minPlacementEdge, min(Int(round(Double(hi) * aspectClamped)), maxWClamped))
            hi = Int(round(Double(wi) / aspectClamped))
        }
        return (wi, hi)
    }

    static func topCenteredFit(
        canvasW: Int,
        canvasH: Int,
        sourceAspect: Double
    ) -> (x: Int, y: Int, w: Int, h: Int) {
        let aspect = max(0.01, sourceAspect)
        let cw = canvasW
        let ch = canvasH
        var pw = cw
        var ph = Int(round(Double(pw) / aspect))
        if ph > ch {
            ph = ch
            pw = Int(round(Double(ph) * aspect))
        }
        let clamped = clampAspectSize(w: pw, h: ph, aspect: aspect, maxW: cw, maxH: ch)
        pw = clamped.0
        ph = clamped.1
        let px = (cw - pw) / 2
        let py = 0
        return (px, py, pw, ph)
    }

    /// Default expand placement: max size that fits, centered in the target canvas.
    static func centeredFit(
        canvasW: Int,
        canvasH: Int,
        sourceAspect: Double
    ) -> (x: Int, y: Int, w: Int, h: Int) {
        let fit = topCenteredFit(canvasW: canvasW, canvasH: canvasH, sourceAspect: sourceAspect)
        let py = max(0, (canvasH - fit.h) / 2)
        return (fit.x, py, fit.w, fit.h)
    }

    static func storeRelative(
        placementX: Int,
        placementY: Int,
        placementW: Int,
        placementH: Int,
        canvasW: Int,
        canvasH: Int
    ) -> RelativePlacement {
        let cx = Double(placementX) + Double(placementW) / 2.0
        let cy = Double(placementY) + Double(placementH) / 2.0
        let aspect = Double(placementW) / max(1.0, Double(placementH))
        return RelativePlacement(
            centerXFraction: cx / max(1.0, Double(canvasW)),
            centerYFraction: cy / max(1.0, Double(canvasH)),
            widthFraction: Double(placementW) / max(1.0, Double(canvasW)),
            placementAspect: aspect
        )
    }

    static func applyRelative(
        _ rel: RelativePlacement,
        canvasW: Int,
        canvasH: Int
    ) -> (x: Int, y: Int, w: Int, h: Int) {
        let aspect = max(0.01, rel.placementAspect)
        let maxW = canvasW
        let maxH = canvasH
        var pw = max(minPlacementEdge, Int(rel.widthFraction * Double(canvasW)))
        var ph = max(minPlacementEdge, Int(round(Double(pw) / aspect)))
        let clamped = clampAspectSize(w: pw, h: ph, aspect: aspect, maxW: maxW, maxH: maxH)
        pw = clamped.0
        ph = clamped.1
        let cx = rel.centerXFraction * Double(canvasW)
        let cy = rel.centerYFraction * Double(canvasH)
        let px = Int(cx - Double(pw) / 2.0)
        let py = Int(cy - Double(ph) / 2.0)
        let clampedPos = clampPosition(x: px, y: py, w: pw, h: ph, canvasW: canvasW, canvasH: canvasH)
        return (clampedPos.0, clampedPos.1, pw, ph)
    }

    static func clampPosition(
        x: Int,
        y: Int,
        w: Int,
        h: Int,
        canvasW: Int,
        canvasH: Int
    ) -> (Int, Int) {
        let px = max(0, min(x, canvasW - w))
        let py = max(0, min(y, canvasH - h))
        return (px, py)
    }

    static func applyResizeDrag(
        px: Int,
        py: Int,
        pw: Int,
        ph: Int,
        cdx: Int,
        cdy: Int,
        sourceAspect: Double,
        canvasW: Int,
        canvasH: Int,
        freeAspect: Bool
    ) -> (w: Int, h: Int) {
        let maxW = canvasW - px
        let maxH = canvasH - py
        if freeAspect {
            let sized = clampSizeInCanvas(w: pw + cdx, h: ph + cdy, maxW: maxW, maxH: maxH)
            return (sized.0, sized.1)
        }
        let aspect = max(0.01, sourceAspect)
        let wFromWidth = Double(pw + cdx)
        let hFromWidth = wFromWidth / aspect
        let wFromHeight = Double(ph + cdy) * aspect
        let hFromHeight = Double(ph + cdy)
        let newW: Double
        let newH: Double
        if abs(Double(cdx)) >= abs(Double(cdy)) * aspect {
            newW = wFromWidth
            newH = hFromWidth
        } else {
            newW = wFromHeight
            newH = hFromHeight
        }
        let clamped = clampAspectSize(
            w: Int(round(newW)),
            h: Int(round(newH)),
            aspect: aspect,
            maxW: maxW,
            maxH: maxH
        )
        return (clamped.0, clamped.1)
    }
}
