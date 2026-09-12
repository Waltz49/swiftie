import AppKit
import CoreGraphics

/// Draws reference-graph dependency edges on the thumbnail canvas.
/// Port of ``ThumbnailCanvas._paint_reference_graph_edges`` in ``thumbnail_canvas.py``.
enum ReferenceGraphEdgeRenderer {
    static func paint(
        routes: [GraphEdgeRoute],
        in dirtyRect: NSRect,
        context: CGContext,
        pathsOnly: Bool,
        arrowheadsOnly: Bool
    ) {
        let cornerRadius: CGFloat = 10
        let arrowLen: CGFloat = 14
        let arrowHalf: CGFloat = 9
        let tailHalf = arrowHalf - 1
        let tailTipLen: CGFloat = 8

        for route in routes {
            let points = route.points
            guard points.count >= 2 else { continue }

            let xs = points.map(\.x)
            let ys = points.map(\.y)
            let bbox = NSRect(
                x: CGFloat(xs.min() ?? 0) - 6,
                y: CGFloat(ys.min() ?? 0) - 6,
                width: CGFloat((xs.max() ?? 0) - (xs.min() ?? 0)) + 12,
                height: CGFloat((ys.max() ?? 0) - (ys.min() ?? 0)) + 12
            )
            guard bbox.intersects(dirtyRect) else { continue }

            let color = NSColor(hex: route.color) ?? NSColor.systemBlue
            let incoming = arrowIncoming(at: points)
            let outgoing = arrowOutgoing(from: points)

            var lineEnd = points[points.count - 1]
            if let incoming {
                let segLen = incoming.length
                guard segLen > 0 else { continue }
                let ux = incoming.dx / segLen
                let uy = incoming.dy / segLen
                let shorten = min(arrowLen, max(2, segLen * 0.4))
                lineEnd = CGPoint(
                    x: incoming.tip.x - ux * shorten,
                    y: incoming.tip.y - uy * shorten
                )
            }

            if !arrowheadsOnly {
                context.saveGState()
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(3)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                let path = roundedEdgePath(points: points, cornerRadius: cornerRadius, terminal: lineEnd)
                context.addPath(path)
                context.strokePath()
                context.restoreGState()
            }

            if !pathsOnly {
                if let incoming {
                    let segLen = incoming.length
                    guard segLen > 0 else { continue }
                    let ux = incoming.dx / segLen
                    let uy = incoming.dy / segLen
                    let base = lineEnd
                    let left = CGPoint(x: base.x - uy * arrowHalf, y: base.y + ux * arrowHalf)
                    let right = CGPoint(x: base.x + uy * arrowHalf, y: base.y - ux * arrowHalf)
                    fillTriangle(tip: incoming.tip, left: left, right: right, color: color, context: context)
                }
                if let outgoing {
                    let segLen = outgoing.length
                    guard segLen > 0 else { continue }
                    let ux = outgoing.dx / segLen
                    let uy = outgoing.dy / segLen
                    drawOutwardTail(
                        at: outgoing.origin,
                        ux: ux,
                        uy: uy,
                        halfWidth: tailHalf,
                        tipLen: tailTipLen,
                        color: color,
                        context: context
                    )
                }
            }
        }
    }

    private struct ArrowSegment {
        let origin: CGPoint
        let tip: CGPoint
        let dx: CGFloat
        let dy: CGFloat
        var length: CGFloat { hypot(dx, dy) }
    }

    private static func arrowIncoming(at points: [CGPoint], minSegLen: CGFloat = 6) -> ArrowSegment? {
        guard points.count >= 2 else { return nil }
        let tip = points[points.count - 1]
        for index in stride(from: points.count - 2, through: 0, by: -1) {
            let prev = points[index]
            let dx = tip.x - prev.x
            let dy = tip.y - prev.y
            let segLen = hypot(dx, dy)
            if segLen >= minSegLen {
                return ArrowSegment(origin: prev, tip: tip, dx: dx, dy: dy)
            }
        }
        let prev = points[points.count - 2]
        let dx = tip.x - prev.x
        let dy = tip.y - prev.y
        let segLen = hypot(dx, dy)
        guard segLen >= 0.5 else { return nil }
        return ArrowSegment(origin: prev, tip: tip, dx: dx, dy: dy)
    }

    private static func arrowOutgoing(from points: [CGPoint], minSegLen: CGFloat = 6) -> ArrowSegment? {
        guard points.count >= 2 else { return nil }
        let origin = points[0]
        for index in 1..<points.count {
            let next = points[index]
            let dx = next.x - origin.x
            let dy = next.y - origin.y
            let segLen = hypot(dx, dy)
            if segLen >= minSegLen {
                return ArrowSegment(origin: origin, tip: next, dx: dx, dy: dy)
            }
        }
        let next = points[1]
        let dx = next.x - origin.x
        let dy = next.y - origin.y
        let segLen = hypot(dx, dy)
        guard segLen >= 0.5 else { return nil }
        return ArrowSegment(origin: origin, tip: next, dx: dx, dy: dy)
    }

    private static func roundedEdgePath(
        points: [CGPoint],
        cornerRadius: CGFloat,
        terminal: CGPoint
    ) -> CGPath {
        let path = CGMutablePath()
        guard !points.isEmpty else { return path }
        path.move(to: points[0])
        guard points.count >= 2 else {
            path.addLine(to: terminal)
            return path
        }
        if points.count == 2 {
            path.addLine(to: terminal)
            return path
        }

        for index in 1..<(points.count - 1) {
            let before = points[index - 1]
            let corner = points[index]
            let after = index + 1 < points.count ? points[index + 1] : terminal

            let vInX = corner.x - before.x
            let vInY = corner.y - before.y
            let vOutX = after.x - corner.x
            let vOutY = after.y - corner.y
            let lenIn = hypot(vInX, vInY)
            let lenOut = hypot(vOutX, vOutY)
            if lenIn < 0.5 || lenOut < 0.5 {
                path.addLine(to: corner)
                continue
            }

            let radius = min(cornerRadius, lenIn / 2, lenOut / 2)
            if radius < 1 {
                path.addLine(to: corner)
                continue
            }

            let entry = CGPoint(
                x: corner.x - vInX / lenIn * radius,
                y: corner.y - vInY / lenIn * radius
            )
            let exit = CGPoint(
                x: corner.x + vOutX / lenOut * radius,
                y: corner.y + vOutY / lenOut * radius
            )
            path.addLine(to: entry)
            path.addQuadCurve(to: exit, control: corner)
        }
        path.addLine(to: terminal)
        return path
    }

    private static func fillTriangle(
        tip: CGPoint,
        left: CGPoint,
        right: CGPoint,
        color: NSColor,
        context: CGContext
    ) {
        context.saveGState()
        context.setFillColor(color.cgColor)
        context.move(to: tip)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }

    private static func drawOutwardTail(
        at attach: CGPoint,
        ux: CGFloat,
        uy: CGFloat,
        halfWidth: CGFloat,
        tipLen: CGFloat,
        color: NSColor,
        context: CGContext
    ) {
        let tip = CGPoint(x: attach.x + ux * tipLen, y: attach.y + uy * tipLen)
        let left = CGPoint(x: attach.x - uy * halfWidth, y: attach.y + ux * halfWidth)
        let right = CGPoint(x: attach.x + uy * halfWidth, y: attach.y - ux * halfWidth)
        fillTriangle(tip: tip, left: left, right: right, color: color, context: context)
    }
}
