import CoreGraphics
import Foundation

// MARK: - Public types

struct GraphEdgeRoute {
    var sourcePath: String
    var targetPath: String
    var points: [CGPoint]
    var color: String
}

struct ReferenceGraphLayoutResult {
    var nodeRects: [String: CGRect] = [:]
    var edgeRoutes: [GraphEdgeRoute] = []
    var canvasWidth: Int = 800
    var canvasHeight: Int = 600
    var layers: [String: Int] = [:]
    var overlayHeightsByPath: [String: CGFloat] = [:]
    var wrappedLinesByPath: [String: [String]] = [:]
}

struct ReferenceGraphOverlayLayoutContext: Equatable {
    var showFilename: Bool
    var showImageSize: Bool
    var showExtensions: Bool
    var basenamesNeedingExtensions: Set<String>
}

/// Layered DAG layout and orthogonal edge routing for reference dependency graphs.
/// Port of `search/reference_graph_layout.py`.
enum ReferenceGraphLayout {
    private struct EdgeKey: Hashable, Comparable {
        let source: String
        let target: String

        init(_ source: String, _ target: String) {
            self.source = source
            self.target = target
        }

        static func < (lhs: EdgeKey, rhs: EdgeKey) -> Bool {
            lhs.source < rhs.source || (lhs.source == rhs.source && lhs.target < rhs.target)
        }
    }

    private struct SideKey: Hashable {
        let node: String
        let side: String
    }

    private struct ChannelGroupKey: Hashable {
        let midLayer: Int
        let bucket: Int
    }

    private static let edgeColorsOnDarkBG: [String] = [
        "#4FC3F7", "#E040FB", "#FF7043", "#26C6DA", "#FF5252",
        "#B388FF", "#FFA726", "#EC407A", "#5C6BC0", "#00ACC1",
        "#AB47BC", "#FF6E40", "#448AFF", "#F06292", "#7E57C2",
    ]
    private static let edgeColorsOnLightBG: [String] = [
        "#1565C0", "#E65100", "#2E7D32", "#6A1B9A", "#C62828",
        "#F57F17", "#00838F", "#AD1457", "#283593", "#558B2F",
        "#4E342E", "#0277BD", "#D84315", "#4527A0", "#00695C",
    ]

    private static let gutterLaneSpacing: CGFloat = 20
    private static let minChannelSep: CGFloat = 16
    private static let coordBucket: CGFloat = 10
    private static let deconflictTol: CGFloat = 4
    private static let maxDeconflictPasses = 4
    private static let layerGap: CGFloat = 64

    private static let thumbnailSpacing: CGFloat = 4
    private static let baseMargin: CGFloat = 20
    private static let canvasTotalTopMargin: CGFloat = 14
    private static let canvasTotalBottomMargin: CGFloat = 10

    private static let incomingBand: (CGFloat, CGFloat) = (0.06, 0.42)
    private static let outgoingBand: (CGFloat, CGFloat) = (0.58, 0.94)
    private static let soloBand: (CGFloat, CGFloat) = (0.08, 0.92)

    // MARK: - Public API

    static func edgeColorTheme(isLight: Bool) -> String {
        isLight ? "light" : "dark"
    }

    static func computeDynamicThumbnailSize(
        graph: ReferenceGraph,
        viewportWidth: Int,
        viewportHeight: Int,
        overlayHeight: Int = 0
    ) -> Int {
        if graph.nodes.isEmpty {
            return Int(ThumbnailLayout.minCellSize)
        }

        let (_, byLayer) = assignLayersFromFocus(graph: graph)
        let maxLayerCount = byLayer.values.map(\.count).max() ?? 1
        let numLayers = byLayer.count
        let margin = baseMargin
        let spacing = thumbnailSpacing
        let overlay = CGFloat(max(0, overlayHeight))

        let availableWidth = max(200, CGFloat(viewportWidth) - 2 * margin)
        let availableHeight = CGFloat(viewportHeight) - canvasTotalTopMargin - canvasTotalBottomMargin
        if availableWidth <= 0 || availableHeight <= 0 {
            return Int(ThumbnailLayout.minCellSize)
        }

        var best = Int(ThumbnailLayout.minCellSize)
        let minSize = Int(ThumbnailLayout.minCellSize)
        let maxSize = Int(ThumbnailLayout.maxCellSize)
        for testSize in minSize...maxSize {
            let nodeW = CGFloat(testSize) + ThumbnailLayout.borderSpace
            let cellOuter = nodeW + spacing
            let cellH = CGFloat(testSize) + ThumbnailLayout.borderSpace + overlay
            let rowWidth = CGFloat(maxLayerCount) * cellOuter - spacing
            if rowWidth > availableWidth { continue }
            let totalH = CGFloat(numLayers) * (cellH + spacing + layerGap) - layerGap
            if totalH > availableHeight { continue }
            best = testSize
        }
        return best
    }

    static func computeLayout(
        graph: ReferenceGraph,
        viewportWidth: Int,
        thumbnailSize: Int,
        overlayHeight: Int = 0,
        overlayContext: ReferenceGraphOverlayLayoutContext? = nil,
        fitToViewportWidth: Bool = true,
        edgeColorTheme: String = "dark",
        overlayCache: ThumbnailFilenameOverlayCache = .shared
    ) -> ReferenceGraphLayoutResult {
        if graph.nodes.isEmpty {
            return ReferenceGraphLayoutResult()
        }

        let pathOrder = resolvedPathOrder(for: graph)
        let normToPath = Dictionary(uniqueKeysWithValues: graph.nodes.map { (normPath($0), $0) })
        let (layers, byLayerInitial) = assignLayersFromFocus(graph: graph, pathOrder: pathOrder)
        var byLayer = byLayerInitial

        var outgoing: [String: Set<String>] = [:]
        var incoming: [String: Set<String>] = [:]
        var edgeNorm: [EdgeKey] = []
        for key in normToPath.keys {
            outgoing[key] = []
            incoming[key] = []
        }
        for (source, target) in graph.edges {
            let sn = normPath(source)
            let tn = normPath(target)
            guard normToPath[sn] != nil, normToPath[tn] != nil else { continue }
            outgoing[sn, default: []].insert(tn)
            incoming[tn, default: []].insert(sn)
            edgeNorm.append(EdgeKey(sn, tn))
        }

        barycenterOrder(
            byLayer: &byLayer,
            outgoing: outgoing,
            incoming: incoming,
            pathOrder: pathOrder
        )

        let margin = baseMargin
        let spacing = thumbnailSpacing
        var nodeW = CGFloat(thumbnailSize) + ThumbnailLayout.borderSpace
        var cellOuter = nodeW + spacing
        let uniformOverlay = CGFloat(max(0, overlayHeight))
        let contentWidth = max(200, CGFloat(viewportWidth) - 2 * margin)
        let contentLeft = margin

        let maxLayerCount = byLayer.values.map(\.count).max() ?? 1
        var neededRowWidth = CGFloat(maxLayerCount) * cellOuter - spacing
        if fitToViewportWidth, neededRowWidth > contentWidth, maxLayerCount > 1 {
            nodeW = max(CGFloat(thumbnailSize) + ThumbnailLayout.borderSpace,
                        (contentWidth - spacing) / CGFloat(maxLayerCount))
            cellOuter = nodeW + spacing
            neededRowWidth = CGFloat(maxLayerCount) * cellOuter - spacing
        }

        let layoutContentWidth = fitToViewportWidth
            ? contentWidth
            : max(contentWidth, neededRowWidth)

        var nodeRects: [String: CGRect] = [:]
        var overlayHeightsByPath: [String: CGFloat] = [:]
        var wrappedLinesByPath: [String: [String]] = [:]
        var gutterCenters: [Int: CGFloat] = [:]
        var layerCenters: [String: CGFloat] = [:]
        var y = canvasTotalTopMargin
        let maxLayer = byLayer.keys.max() ?? 0
        let rectSize = CGFloat(thumbnailSize) + ThumbnailLayout.borderSpace

        for layer in 0...maxLayer {
            let layerNodes = byLayer[layer] ?? []
            if layerNodes.isEmpty { continue }

            var layerMaxOverlay: CGFloat = 0
            if let overlayContext {
                for nNorm in layerNodes {
                    guard let path = normToPath[nNorm] else { continue }
                    let overlay = ThumbnailFilenameOverlayService.overlay(
                        for: path,
                        cellWidth: nodeW,
                        showFilename: overlayContext.showFilename,
                        showImageSize: overlayContext.showImageSize,
                        showExtensions: overlayContext.showExtensions,
                        basenamesNeedingExtensions: overlayContext.basenamesNeedingExtensions,
                        displayStyle: .basename,
                        wrapMode: .cellWidth,
                        cache: overlayCache
                    )
                    overlayHeightsByPath[path] = overlay.overlayHeight
                    wrappedLinesByPath[path] = overlay.wrappedLines
                    layerMaxOverlay = max(layerMaxOverlay, overlay.overlayHeight)
                }
            } else {
                layerMaxOverlay = uniformOverlay
            }
            let layerCellH = rectSize + layerMaxOverlay

            let layerOfNode = Dictionary(
                uniqueKeysWithValues: layers.compactMap { norm, layerIndex in
                    normToPath[norm].map { ($0, layerIndex) }
                }
            )
            let ideals = idealCentersForLayer(
                layerNodes: layerNodes,
                incoming: incoming,
                outgoing: outgoing,
                layerCenters: layerCenters,
                layerOfNode: layerOfNode,
                pathOrder: pathOrder,
                contentLeft: contentLeft,
                contentWidth: layoutContentWidth,
                layerIdx: layer
            )
            let leftPositions = scatterPositionsInLayer(
                layerNodes: layerNodes,
                idealCenters: ideals,
                contentLeft: contentLeft,
                contentWidth: layoutContentWidth,
                nodeW: nodeW
            )
            let rowTop = y
            for nNorm in layerNodes {
                guard let path = normToPath[nNorm] else { continue }
                let left = leftPositions[nNorm] ?? contentLeft
                nodeRects[path] = CGRect(
                    x: left,
                    y: rowTop,
                    width: nodeW,
                    height: layerCellH
                )
                if overlayContext == nil {
                    overlayHeightsByPath[path] = uniformOverlay
                }
                layerCenters[nNorm] = left + nodeW / 2
            }
            let rowBottom = rowTop + layerCellH
            gutterCenters[layer] = rowBottom + layerGap / 2
            y = rowBottom + spacing + layerGap
        }

        let canvasH = Int(y - layerGap + canvasTotalBottomMargin)
        let canvasW = max(viewportWidth, Int(margin * 2 + layoutContentWidth))
        let layerOfPath = Dictionary(
            uniqueKeysWithValues: layers.compactMap { norm, layerIndex in
                normToPath[norm].map { ($0, layerIndex) }
            }
        )

        let edgeRoutes = routeEdges(
            edgeList: edgeNorm.map { EdgeKey(normToPath[$0.source]!, normToPath[$0.target]!) },
            nodeRects: nodeRects,
            layerOfPath: layerOfPath,
            gutterCenters: gutterCenters,
            colorTheme: edgeColorTheme,
            contentLeft: contentLeft,
            contentWidth: layoutContentWidth,
            pathOrder: pathOrder
        )

        let layersByPath = Dictionary(
            uniqueKeysWithValues: layers.compactMap { norm, layerIndex in
                normToPath[norm].map { ($0, layerIndex) }
            }
        )

        return ReferenceGraphLayoutResult(
            nodeRects: nodeRects,
            edgeRoutes: edgeRoutes,
            canvasWidth: canvasW,
            canvasHeight: max(canvasH, 200),
            layers: layersByPath,
            overlayHeightsByPath: overlayHeightsByPath,
            wrappedLinesByPath: wrappedLinesByPath
        )
    }

    // MARK: - Path helpers

    private static func normPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func resolvedPathOrder(for graph: ReferenceGraph) -> [String: Int] {
        if !graph.pathOrder.isEmpty {
            return graph.pathOrder
        }
        var order: [String: Int] = [:]
        for (index, path) in graph.nodes.enumerated() {
            order[normPath(path)] = index
        }
        return order
    }

    // MARK: - Layer assignment

    private static func assignLayersFromFocus(
        graph: ReferenceGraph,
        pathOrder: [String: Int]? = nil
    ) -> ([String: Int], [Int: [String]]) {
        let order = pathOrder ?? resolvedPathOrder(for: graph)
        let normNodes = graph.nodes.map(normPath)
        let nodeSet = Set(normNodes)
        var focus = graph.focusPath.map(normPath) ?? ""
        if !nodeSet.contains(focus), let first = normNodes.first {
            focus = first
        }

        var layers: [String: Int] = [focus: 0]
        var queue = [focus]
        var head = 0
        while head < queue.count {
            let n = queue[head]
            head += 1
            let ln = layers[n]!
            for (source, target) in graph.edges {
                let tn = normPath(target)
                let sn = normPath(source)
                if tn == n, nodeSet.contains(sn), layers[sn] == nil {
                    layers[sn] = ln + 1
                    queue.append(sn)
                }
            }
        }

        var maxL = layers.values.max() ?? 0
        for n in normNodes where layers[n] == nil {
            maxL += 1
            layers[n] = maxL
        }

        var byLayer: [Int: [String]] = [:]
        for (n, layer) in layers {
            byLayer[layer, default: []].append(n)
        }
        for key in byLayer.keys {
            byLayer[key]?.sort { order[$0, default: 0] < order[$1, default: 0] }
        }
        return (layers, byLayer)
    }

    private static func barycenterOrder(
        byLayer: inout [Int: [String]],
        outgoing: [String: Set<String>],
        incoming: [String: Set<String>],
        pathOrder: [String: Int],
        iterations: Int = 4
    ) {
        let maxLayer = byLayer.keys.max() ?? 0
        var pos: [String: CGFloat] = [:]

        for _ in 0..<iterations {
            for layer in 0...maxLayer {
                let nodes = byLayer[layer] ?? []
                if nodes.isEmpty { continue }
                var scored: [(CGFloat, String)] = []
                for n in nodes {
                    let bary: CGFloat
                    if layer == 0 {
                        bary = CGFloat(pathOrder[n, default: 0])
                    } else {
                        let parents = incoming[n] ?? []
                        let parentPositions = parents.compactMap { pos[$0] }
                        bary = parentPositions.isEmpty
                            ? CGFloat(pathOrder[n, default: 0])
                            : parentPositions.reduce(0, +) / CGFloat(parentPositions.count)
                    }
                    scored.append((bary, n))
                }
                scored.sort { ($0.0, pathOrder[$0.1, default: 0]) < ($1.0, pathOrder[$1.1, default: 0]) }
                byLayer[layer] = scored.map(\.1)
                for (i, n) in byLayer[layer]!.enumerated() {
                    pos[n] = CGFloat(i)
                }
            }

            for layer in stride(from: maxLayer, through: 0, by: -1) {
                let nodes = byLayer[layer] ?? []
                if nodes.isEmpty { continue }
                var scored: [(CGFloat, String)] = []
                for n in nodes {
                    let children = outgoing[n] ?? []
                    let childPositions = children.compactMap { pos[$0] }
                    let bary = childPositions.isEmpty
                        ? CGFloat(pathOrder[n, default: 0])
                        : childPositions.reduce(0, +) / CGFloat(childPositions.count)
                    scored.append((bary, n))
                }
                scored.sort { ($0.0, pathOrder[$0.1, default: 0]) < ($1.0, pathOrder[$1.1, default: 0]) }
                byLayer[layer] = scored.map(\.1)
                for (i, n) in byLayer[layer]!.enumerated() {
                    pos[n] = CGFloat(i)
                }
            }
        }
    }

    // MARK: - Node positioning

    private static func idealCentersForLayer(
        layerNodes: [String],
        incoming: [String: Set<String>],
        outgoing: [String: Set<String>],
        layerCenters: [String: CGFloat],
        layerOfNode: [String: Int],
        pathOrder: [String: Int],
        contentLeft: CGFloat,
        contentWidth: CGFloat,
        layerIdx: Int
    ) -> [String: CGFloat] {
        var ideals: [String: CGFloat] = [:]
        let n = layerNodes.count
        for (i, node) in layerNodes.enumerated() {
            if layerIdx == 0 {
                ideals[node] = contentLeft + contentWidth / 2
                continue
            }
            let targets = (outgoing[node] ?? []).compactMap { t -> CGFloat? in
                guard let center = layerCenters[t],
                      (layerOfNode[t] ?? 999) < layerIdx else { return nil }
                return center
            }
            if !targets.isEmpty {
                ideals[node] = targets.reduce(0, +) / CGFloat(targets.count)
            } else if n == 1 {
                ideals[node] = contentLeft + contentWidth / 2
            } else {
                let slot = pathOrder[node, default: i]
                ideals[node] = contentLeft + (CGFloat(slot) + 0.5) * contentWidth / CGFloat(max(n, 1))
            }
        }
        return ideals
    }

    private static func scatterPositionsInLayer(
        layerNodes: [String],
        idealCenters: [String: CGFloat],
        contentLeft: CGFloat,
        contentWidth: CGFloat,
        nodeW: CGFloat
    ) -> [String: CGFloat] {
        let n = layerNodes.count
        if n == 0 { return [:] }
        if n == 1 {
            let node = layerNodes[0]
            return [node: contentLeft + contentWidth / 2 - nodeW / 2]
        }
        let ordered = layerNodes.sorted { idealCenters[$0, default: 0] < idealCenters[$1, default: 0] }
        let columnW = contentWidth / CGFloat(n)
        var out: [String: CGFloat] = [:]
        for (i, nd) in ordered.enumerated() {
            let centerX = contentLeft + (CGFloat(i) + 0.5) * columnW
            out[nd] = centerX - nodeW / 2
        }
        return out
    }

    // MARK: - Edge colors

    private static func edgeColorPalette(theme: String) -> [String] {
        theme == "light" ? edgeColorsOnLightBG : edgeColorsOnDarkBG
    }

    private static func assignEdgeColors(
        canonical: [EdgeKey],
        outgoingLanes: [String: [EdgeKey]],
        colorTheme: String,
        pathOrder: [String: Int]?
    ) -> [EdgeKey: String] {
        let palette = edgeColorPalette(theme: colorTheme)
        let n = palette.count
        if n == 0 { return [:] }

        var colorMap: [EdgeKey: String] = [:]
        if let pathOrder {
            for (sp, edges) in outgoingLanes {
                let idx = pathOrder[normPath(sp), default: pathOrder[sp, default: 0]]
                let color = palette[idx % n]
                let canonicalSet = Set(canonical)
                for key in edges where canonicalSet.contains(key) {
                    colorMap[key] = color
                }
            }
        } else {
            let canonicalSet = Set(canonical)
            for (i, sp) in outgoingLanes.keys.sorted().enumerated() {
                let color = palette[i % n]
                for key in outgoingLanes[sp] ?? [] where canonicalSet.contains(key) {
                    colorMap[key] = color
                }
            }
        }
        return colorMap
    }

    // MARK: - Edge attachments

    private static func edgeSides(srcRect: CGRect, tgtRect: CGRect) -> (String, String) {
        let scy = srcRect.midY
        let tcy = tgtRect.midY
        if abs(scy - tcy) < 6 {
            if srcRect.midX <= tgtRect.midX {
                return ("right", "left")
            }
            return ("left", "right")
        }
        if scy < tcy {
            return ("bottom", "top")
        }
        return ("top", "bottom")
    }

    private static func pointOnSide(rect: CGRect, side: String, frac: CGFloat) -> CGPoint {
        let f = max(0.08, min(0.92, frac))
        switch side {
        case "top":
            return CGPoint(x: rect.minX + f * rect.width, y: rect.minY)
        case "bottom":
            return CGPoint(x: rect.minX + f * rect.width, y: rect.maxY)
        case "left":
            return CGPoint(x: rect.minX, y: rect.minY + f * rect.height)
        default:
            return CGPoint(x: rect.maxX, y: rect.minY + f * rect.height)
        }
    }

    private static func slotFrac(index: Int, count: Int) -> CGFloat {
        if count <= 1 { return 0.5 }
        return CGFloat(index + 1) / CGFloat(count + 1)
    }

    private static func bandSlotFrac(index: Int, count: Int, bandLo: CGFloat, bandHi: CGFloat) -> CGFloat {
        if count <= 1 { return (bandLo + bandHi) / 2 }
        let t = slotFrac(index: index, count: count)
        return bandLo + t * (bandHi - bandLo)
    }

    private static func attachmentFracOnSide(
        role: String,
        index: Int,
        count: Int,
        inCount: Int,
        outCount: Int
    ) -> CGFloat {
        let band: (CGFloat, CGFloat)
        if inCount > 0 && outCount > 0 {
            band = role == "in" ? incomingBand : outgoingBand
        } else {
            band = soloBand
        }
        return bandSlotFrac(index: index, count: count, bandLo: band.0, bandHi: band.1)
    }

    private static func sortNeighbors(
        nodeID: String,
        neighborIDs: [String],
        nodeRects: [String: CGRect],
        side: String
    ) -> [String] {
        let uniq = Array(Set(neighborIDs)).sorted()
        return uniq.sorted { a, b in
            let ca = nodeRects[a]!.center
            let cb = nodeRects[b]!.center
            if side == "top" || side == "bottom" {
                return ca.x < cb.x
            }
            return ca.y < cb.y
        }
    }

    private static func computeEdgeAttachments(
        edgeList: [EdgeKey],
        nodeRects: [String: CGRect]
    ) -> [EdgeKey: (CGPoint, CGPoint)] {
        var edgeSidesMap: [EdgeKey: (String, String)] = [:]
        for edge in edgeList {
            guard let sr = nodeRects[edge.source], let tr = nodeRects[edge.target] else { continue }
            edgeSidesMap[edge] = edgeSides(srcRect: sr, tgtRect: tr)
        }

        var outBySide: [SideKey: [String]] = [:]
        var inBySide: [SideKey: [String]] = [:]
        for edge in edgeList {
            guard let sides = edgeSidesMap[edge] else { continue }
            let (srcSide, tgtSide) = sides
            outBySide[SideKey(node: edge.source, side: srcSide), default: []].append(edge.target)
            inBySide[SideKey(node: edge.target, side: tgtSide), default: []].append(edge.source)
        }

        let sideInCount = Dictionary(uniqueKeysWithValues: inBySide.map { ($0.key, Set($0.value).count) })
        let sideOutCount = Dictionary(uniqueKeysWithValues: outBySide.map { ($0.key, Set($0.value).count) })

        var srcFrac: [EdgeKey: CGFloat] = [:]
        var tgtFrac: [EdgeKey: CGFloat] = [:]

        for (sideKey, targets) in outBySide {
            let uniq = sortNeighbors(nodeID: sideKey.node, neighborIDs: targets, nodeRects: nodeRects, side: sideKey.side)
            let nOut = uniq.count
            let nIn = sideInCount[sideKey, default: 0]
            for (i, tp) in uniq.enumerated() {
                srcFrac[EdgeKey(sideKey.node, tp)] = attachmentFracOnSide(
                    role: "out", index: i, count: nOut, inCount: nIn, outCount: nOut
                )
            }
        }

        for (sideKey, sources) in inBySide {
            let uniq = sortNeighbors(nodeID: sideKey.node, neighborIDs: sources, nodeRects: nodeRects, side: sideKey.side)
            let nIn = uniq.count
            let nOut = sideOutCount[sideKey, default: 0]
            for (i, sp) in uniq.enumerated() {
                tgtFrac[EdgeKey(sp, sideKey.node)] = attachmentFracOnSide(
                    role: "in", index: i, count: nIn, inCount: nIn, outCount: nOut
                )
            }
        }

        var attachments: [EdgeKey: (CGPoint, CGPoint)] = [:]
        for edge in edgeList {
            guard let sr = nodeRects[edge.source],
                  let tr = nodeRects[edge.target],
                  let sides = edgeSidesMap[edge] else { continue }
            let (srcSide, tgtSide) = sides
            let sf = srcFrac[edge, default: 0.5]
            let tf = tgtFrac[edge, default: 0.5]
            attachments[edge] = (
                pointOnSide(rect: sr, side: srcSide, frac: sf),
                pointOnSide(rect: tr, side: tgtSide, frac: tf)
            )
        }
        return attachments
    }

    private static func alignTailToHeadOnBorder(
        attachments: inout [EdgeKey: (CGPoint, CGPoint)],
        edgeList: [EdgeKey],
        nodeRects: [String: CGRect]
    ) {
        for edge in edgeList {
            let key = edge
            guard let pair = attachments[key],
                  let sr = nodeRects[edge.source],
                  let tr = nodeRects[edge.target] else { continue }
            let (srcAttach, tgtAttach) = pair
            let (srcSide, tgtSide) = edgeSides(srcRect: sr, tgtRect: tr)

            if (srcSide == "top" || srcSide == "bottom") && (tgtSide == "top" || tgtSide == "bottom") {
                var x = tgtAttach.x
                if x < sr.minX || x > sr.maxX {
                    guard let ol = rectXOverlap(sr, tr) else { continue }
                    x = max(ol.0, min(ol.1, x))
                } else if let ol = rectXOverlap(sr, tr) {
                    x = max(ol.0, min(ol.1, x))
                }
                x = max(sr.minX, min(sr.maxX, x))
                if abs(srcAttach.x - x) < 0.5 { continue }
                attachments[key] = (CGPoint(x: x, y: srcAttach.y), tgtAttach)
                continue
            }

            if (srcSide == "left" || srcSide == "right") && (tgtSide == "left" || tgtSide == "right") {
                var y = tgtAttach.y
                if y < sr.minY || y > sr.maxY {
                    guard let ol = rectYOverlap(sr, tr) else { continue }
                    y = max(ol.0, min(ol.1, y))
                } else if let ol = rectYOverlap(sr, tr) {
                    y = max(ol.0, min(ol.1, y))
                }
                y = max(sr.minY, min(sr.maxY, y))
                if abs(srcAttach.y - y) < 0.5 { continue }
                attachments[key] = (CGPoint(x: srcAttach.x, y: y), tgtAttach)
            }
        }
    }

    // MARK: - Polyline helpers

    private static func rectXOverlap(_ a: CGRect, _ b: CGRect) -> (CGFloat, CGFloat)? {
        let left = max(a.minX, b.minX)
        let right = min(a.maxX, b.maxX)
        if left > right { return nil }
        return (left, right)
    }

    private static func rectYOverlap(_ a: CGRect, _ b: CGRect) -> (CGFloat, CGFloat)? {
        let top = max(a.minY, b.minY)
        let bottom = min(a.maxY, b.maxY)
        if top > bottom { return nil }
        return (top, bottom)
    }

    private static func rectsShareColumn(_ srcRect: CGRect, _ tgtRect: CGRect) -> Bool {
        rectXOverlap(srcRect, tgtRect) != nil
    }

    private static func rectsShareRow(_ srcRect: CGRect, _ tgtRect: CGRect) -> Bool {
        rectYOverlap(srcRect, tgtRect) != nil
    }

    private static func edgeUsesVerticalSpine(
        srcAttach: CGPoint,
        tgtAttach: CGPoint,
        srcRect: CGRect,
        tgtRect: CGRect
    ) -> Bool {
        rectsShareColumn(srcRect, tgtRect) && abs(srcAttach.y - tgtAttach.y) > 1
    }

    private static func edgeUsesHorizontalSpine(
        srcAttach: CGPoint,
        tgtAttach: CGPoint,
        srcRect: CGRect,
        tgtRect: CGRect
    ) -> Bool {
        rectsShareRow(srcRect, tgtRect) && abs(srcAttach.x - tgtAttach.x) > 1
    }

    private static func bestColumnX(
        srcAttach: CGPoint,
        tgtAttach: CGPoint,
        olLeft: CGFloat,
        olRight: CGFloat
    ) -> CGFloat {
        let sx = srcAttach.x
        let tx = tgtAttach.x
        let inS = olLeft <= sx && sx <= olRight
        let inT = olLeft <= tx && tx <= olRight
        if inS && inT { return tx }
        if inS { return sx }
        if inT { return tx }
        return (olLeft + olRight) / 2
    }

    private static func sharedColumnX(
        srcAttach: CGPoint,
        tgtAttach: CGPoint,
        srcRect: CGRect,
        tgtRect: CGRect
    ) -> CGFloat {
        guard let ol = rectXOverlap(srcRect, tgtRect) else {
            return (srcRect.midX + tgtRect.midX) / 2
        }
        return bestColumnX(srcAttach: srcAttach, tgtAttach: tgtAttach, olLeft: ol.0, olRight: ol.1)
    }

    private static func bestRowY(
        srcAttach: CGPoint,
        tgtAttach: CGPoint,
        top: CGFloat,
        bottom: CGFloat
    ) -> CGFloat {
        let sy = srcAttach.y
        let ty = tgtAttach.y
        let inS = top <= sy && sy <= bottom
        let inT = top <= ty && ty <= bottom
        if inS && inT { return ty }
        if inS { return sy }
        if inT { return ty }
        return (top + bottom) / 2
    }

    private static func sharedRowY(
        srcAttach: CGPoint,
        tgtAttach: CGPoint,
        srcRect: CGRect,
        tgtRect: CGRect
    ) -> CGFloat {
        guard let ol = rectYOverlap(srcRect, tgtRect) else {
            return (srcRect.midY + tgtRect.midY) / 2
        }
        return bestRowY(srcAttach: srcAttach, tgtAttach: tgtAttach, top: ol.0, bottom: ol.1)
    }

    private static func appendIfFar(_ pts: inout [CGPoint], _ p: CGPoint) {
        if pts.isEmpty {
            pts.append(p)
            return
        }
        let last = pts[pts.count - 1]
        if abs(last.x - p.x) > 0.5 || abs(last.y - p.y) > 0.5 {
            pts.append(p)
        }
    }

    private static func trimCollinearPoints(_ pts: [CGPoint]) -> [CGPoint] {
        if pts.count <= 2 { return pts }
        var out = [pts[0]]
        for i in 1..<(pts.count - 1) {
            let prev = out[out.count - 1]
            let cur = pts[i]
            let nxt = pts[i + 1]
            let sameH = abs(prev.y - cur.y) < 0.5 && abs(cur.y - nxt.y) < 0.5
            let sameV = abs(prev.x - cur.x) < 0.5 && abs(cur.x - nxt.x) < 0.5
            if sameH || sameV { continue }
            out.append(cur)
        }
        out.append(pts[pts.count - 1])
        return out
    }

    private static func dedupePolylinePoints(_ pts: [CGPoint]) -> [CGPoint] {
        if pts.count <= 2 { return pts }
        var out = [pts[0]]
        for p in pts.dropFirst().dropLast() {
            let prev = out[out.count - 1]
            if abs(p.x - prev.x) > 0.5 || abs(p.y - prev.y) > 0.5 {
                out.append(p)
            }
        }
        let last = pts[pts.count - 1]
        let prev = out[out.count - 1]
        if abs(last.x - prev.x) > 0.5 || abs(last.y - prev.y) > 0.5 {
            out.append(last)
        } else {
            out.append(last)
        }
        return trimCollinearPoints(out)
    }

    private static func enforceOrthogonalPolyline(_ pts: [CGPoint]) -> [CGPoint] {
        if pts.count < 2 { return pts }
        var out = [pts[0]]
        for i in 1..<pts.count {
            let prev = out[out.count - 1]
            let cur = pts[i]
            if abs(cur.x - prev.x) > 0.5 && abs(cur.y - prev.y) > 0.5 {
                appendIfFar(&out, CGPoint(x: cur.x, y: prev.y))
            }
            appendIfFar(&out, cur)
        }
        return dedupePolylinePoints(out)
    }

    private static func polylineIsSingleColumn(_ pts: [CGPoint], tol: CGFloat = 1) -> Bool {
        if pts.count < 2 { return false }
        let xs = pts.map(\.x)
        return (xs.max() ?? 0) - (xs.min() ?? 0) <= tol
    }

    private static func layersBetween(srcLayer: Int, tgtLayer: Int) -> [Int] {
        if srcLayer == tgtLayer { return [] }
        let lo = min(srcLayer, tgtLayer)
        let hi = max(srcLayer, tgtLayer)
        return Array(lo..<hi)
    }

    private static func gutterYsBetween(
        srcRect: CGRect,
        tgtRect: CGRect,
        gutterCenters: [Int: CGFloat],
        srcLayer: Int,
        tgtLayer: Int
    ) -> ([CGFloat], Bool) {
        let downward = srcRect.center.y < tgtRect.center.y
        var ys: [CGFloat] = []
        let lo: Int
        let hi: Int
        let yMin: CGFloat
        let yMax: CGFloat
        if downward {
            lo = srcLayer
            hi = tgtLayer
            yMin = srcRect.maxY
            yMax = tgtRect.minY
        } else {
            lo = tgtLayer
            hi = srcLayer
            yMin = tgtRect.maxY
            yMax = srcRect.minY
        }
        for layer in lo..<hi {
            if let gy = gutterCenters[layer], yMin < gy && gy < yMax {
                ys.append(gy)
            }
        }
        if !downward {
            ys.reverse()
        }
        return (ys, downward)
    }

    private static func routeViaVerticalSpine(
        srcAttach: CGPoint,
        tgtAttach: CGPoint,
        srcRect: CGRect,
        tgtRect: CGRect,
        gutterY: CGFloat? = nil
    ) -> [CGPoint] {
        let sx = srcAttach.x
        let tx = tgtAttach.x
        let xR = abs(sx - tx) < 0.5
            ? sx
            : sharedColumnX(srcAttach: srcAttach, tgtAttach: tgtAttach, srcRect: srcRect, tgtRect: tgtRect)
        var pts = [srcAttach]
        if abs(sx - xR) > 0.5 {
            appendIfFar(&pts, CGPoint(x: xR, y: srcAttach.y))
        }
        if let gutterY, abs(pts[pts.count - 1].y - gutterY) > 0.5 {
            appendIfFar(&pts, CGPoint(x: xR, y: gutterY))
        }
        let last = pts[pts.count - 1]
        if abs(last.y - tgtAttach.y) > 0.5 || abs(last.x - tgtAttach.x) > 0.5 {
            appendIfFar(&pts, tgtAttach)
        }
        return dedupePolylinePoints(pts)
    }

    private static func routeViaHorizontalSpine(
        srcAttach: CGPoint,
        tgtAttach: CGPoint,
        srcRect: CGRect,
        tgtRect: CGRect,
        gutterX: CGFloat? = nil
    ) -> [CGPoint] {
        let sy = srcAttach.y
        let ty = tgtAttach.y
        let yR = abs(sy - ty) < 0.5
            ? sy
            : sharedRowY(srcAttach: srcAttach, tgtAttach: tgtAttach, srcRect: srcRect, tgtRect: tgtRect)
        var pts = [srcAttach]
        if abs(sy - yR) > 0.5 {
            appendIfFar(&pts, CGPoint(x: srcAttach.x, y: yR))
        }
        if let gutterX, abs(pts[pts.count - 1].x - gutterX) > 0.5 {
            appendIfFar(&pts, CGPoint(x: gutterX, y: yR))
        }
        let last = pts[pts.count - 1]
        if abs(last.x - tgtAttach.x) > 0.5 || abs(last.y - ty) > 0.5 {
            appendIfFar(&pts, tgtAttach)
        }
        return dedupePolylinePoints(pts)
    }

    private static func assignGlobalGutterOffsets(
        canonical: [EdgeKey],
        layerOfPath: [String: Int],
        gutterCenters: [Int: CGFloat],
        nodeRects: [String: CGRect],
        attachments: [EdgeKey: (CGPoint, CGPoint)]
    ) -> [EdgeKey: [Int: CGFloat]] {
        var gutterEdges: [Int: [EdgeKey]] = [:]
        for edge in canonical {
            guard let sr = nodeRects[edge.source],
                  let tr = nodeRects[edge.target],
                  let pair = attachments[edge] else { continue }
            if edgeUsesVerticalSpine(srcAttach: pair.0, tgtAttach: pair.1, srcRect: sr, tgtRect: tr) {
                continue
            }
            let sl = layerOfPath[edge.source, default: 0]
            let tl = layerOfPath[edge.target, default: 0]
            for layer in layersBetween(srcLayer: sl, tgtLayer: tl) where gutterCenters[layer] != nil {
                gutterEdges[layer, default: []].append(edge)
            }
        }

        var offsets: [EdgeKey: [Int: CGFloat]] = [:]
        for (layer, edges) in gutterEdges {
            let uniq = Array(Set(edges)).sorted()
            let n = uniq.count
            for (i, key) in uniq.enumerated() {
                let off = (CGFloat(i) - CGFloat(n - 1) / 2) * gutterLaneSpacing
                offsets[key, default: [:]][layer] = off
            }
        }
        return offsets
    }

    private static func primaryGutterOffset(
        gutterYOffsets: [Int: CGFloat],
        srcLayer: Int,
        tgtLayer: Int
    ) -> CGFloat {
        let layers = layersBetween(srcLayer: srcLayer, tgtLayer: tgtLayer)
        if layers.isEmpty || gutterYOffsets.isEmpty { return 0 }
        let mid = layers[layers.count / 2]
        return gutterYOffsets[mid, default: 0]
    }

    private static func assignGlobalVertChannels(
        canonical: [EdgeKey],
        attachments: [EdgeKey: (CGPoint, CGPoint)],
        layerOfPath: [String: Int],
        nodeRects: [String: CGRect],
        contentLeft: CGFloat,
        contentRight: CGFloat
    ) -> [EdgeKey: CGFloat] {
        var groups: [ChannelGroupKey: [EdgeKey]] = [:]
        for edge in canonical {
            guard let pair = attachments[edge],
                  let sr = nodeRects[edge.source],
                  let tr = nodeRects[edge.target] else { continue }
            let sl = layerOfPath[edge.source, default: 0]
            let tl = layerOfPath[edge.target, default: 0]
            if sl == tl { continue }
            if edgeUsesVerticalSpine(srcAttach: pair.0, tgtAttach: pair.1, srcRect: sr, tgtRect: tr)
                || edgeUsesHorizontalSpine(srcAttach: pair.0, tgtAttach: pair.1, srcRect: sr, tgtRect: tr) {
                continue
            }
            let xS = pair.0.x
            let bucket = Int(round(xS / coordBucket))
            let between = layersBetween(srcLayer: sl, tgtLayer: tl)
            let midLayer = between.isEmpty ? sl : between[between.count / 2]
            groups[ChannelGroupKey(midLayer: midLayer, bucket: bucket), default: []].append(edge)
        }

        var channels: [EdgeKey: CGFloat] = [:]
        let margin: CGFloat = 10
        for (_, edges) in groups {
            let uniq = Array(Set(edges)).sorted()
            let n = uniq.count
            for (i, key) in uniq.enumerated() {
                let xS = attachments[key]!.0.x
                let off = (CGFloat(i) - CGFloat(n - 1) / 2) * minChannelSep
                let xCh = max(contentLeft + margin, min(contentRight - margin, xS + off))
                channels[key] = xCh
            }
        }
        return channels
    }

    private static func orthogonalPolyline(
        srcAttach: CGPoint,
        tgtAttach: CGPoint,
        srcRect: CGRect,
        tgtRect: CGRect,
        srcLayer: Int,
        tgtLayer: Int,
        gutterCenters: [Int: CGFloat],
        gutterYOffset: CGFloat = 0,
        vertChannelX: CGFloat? = nil
    ) -> [CGPoint] {
        let xS = srcAttach.x
        let yS = srcAttach.y
        let xT = tgtAttach.x
        let yT = tgtAttach.y

        let (gutters, _) = gutterYsBetween(
            srcRect: srcRect,
            tgtRect: tgtRect,
            gutterCenters: gutterCenters,
            srcLayer: srcLayer,
            tgtLayer: tgtLayer
        )
        var gY: CGFloat?
        if !gutters.isEmpty {
            let gBase = gutters[gutters.count / 2]
            var gy = gBase + gutterYOffset
            let ya = min(yS, yT)
            let yb = max(yS, yT)
            gy = max(ya + 10, min(yb - 10, gy))
            gY = gy
        }

        if edgeUsesVerticalSpine(srcAttach: srcAttach, tgtAttach: tgtAttach, srcRect: srcRect, tgtRect: tgtRect) {
            return enforceOrthogonalPolyline(
                routeViaVerticalSpine(
                    srcAttach: srcAttach,
                    tgtAttach: tgtAttach,
                    srcRect: srcRect,
                    tgtRect: tgtRect,
                    gutterY: gY
                )
            )
        }

        if edgeUsesHorizontalSpine(srcAttach: srcAttach, tgtAttach: tgtAttach, srcRect: srcRect, tgtRect: tgtRect) {
            return enforceOrthogonalPolyline(
                routeViaHorizontalSpine(
                    srcAttach: srcAttach,
                    tgtAttach: tgtAttach,
                    srcRect: srcRect,
                    tgtRect: tgtRect
                )
            )
        }

        let xSpine = vertChannelX ?? xS

        if srcLayer == tgtLayer {
            let midY = (yS + yT) / 2 + gutterYOffset
            if abs(xS - xT) > 0.5 {
                if rectsShareRow(srcRect, tgtRect) {
                    return enforceOrthogonalPolyline(
                        routeViaHorizontalSpine(
                            srcAttach: srcAttach,
                            tgtAttach: tgtAttach,
                            srcRect: srcRect,
                            tgtRect: tgtRect
                        )
                    )
                }
                return enforceOrthogonalPolyline(
                    dedupePolylinePoints([
                        srcAttach,
                        CGPoint(x: xS, y: midY),
                        CGPoint(x: xT, y: midY),
                        tgtAttach,
                    ])
                )
            }
            return enforceOrthogonalPolyline(dedupePolylinePoints([srcAttach, tgtAttach]))
        }

        if gutters.isEmpty {
            if rectsShareColumn(srcRect, tgtRect) {
                return enforceOrthogonalPolyline(
                    routeViaVerticalSpine(
                        srcAttach: srcAttach,
                        tgtAttach: tgtAttach,
                        srcRect: srcRect,
                        tgtRect: tgtRect,
                        gutterY: nil
                    )
                )
            }
            let midY = (yS + yT) / 2 + gutterYOffset
            var pts = [srcAttach]
            if abs(xSpine - xS) > 0.5 {
                pts.append(CGPoint(x: xSpine, y: yS))
            }
            pts.append(CGPoint(x: xSpine, y: midY))
            if abs(xT - xSpine) > 0.5 {
                pts.append(CGPoint(x: xT, y: midY))
            }
            pts.append(tgtAttach)
            return enforceOrthogonalPolyline(dedupePolylinePoints(pts))
        }

        if rectsShareColumn(srcRect, tgtRect), gY != nil {
            return enforceOrthogonalPolyline(
                routeViaVerticalSpine(
                    srcAttach: srcAttach,
                    tgtAttach: tgtAttach,
                    srcRect: srcRect,
                    tgtRect: tgtRect,
                    gutterY: gY
                )
            )
        }

        if rectsShareColumn(srcRect, tgtRect) {
            return enforceOrthogonalPolyline(
                routeViaVerticalSpine(
                    srcAttach: srcAttach,
                    tgtAttach: tgtAttach,
                    srcRect: srcRect,
                    tgtRect: tgtRect,
                    gutterY: gY
                )
            )
        }

        var pts = [srcAttach]
        if abs(xSpine - xS) > 0.5 {
            pts.append(CGPoint(x: xSpine, y: yS))
        }
        if let gY, abs(yS - gY) > 0.5 {
            pts.append(CGPoint(x: xSpine, y: gY))
        }
        if abs(xT - xSpine) > 0.5 {
            pts.append(CGPoint(x: xT, y: gY ?? yT))
        }
        pts.append(tgtAttach)
        return enforceOrthogonalPolyline(dedupePolylinePoints(pts))
    }

    // MARK: - Deconflict

    private static func segAxisAligned(_ p1: CGPoint, _ p2: CGPoint) -> String? {
        if abs(p1.y - p2.y) < 0.5 { return "h" }
        if abs(p1.x - p2.x) < 0.5 { return "v" }
        return nil
    }

    private static func rangesOverlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat, tol: CGFloat) -> Bool {
        a0 < b1 + tol && b0 < a1 + tol
    }

    private static func nudgePointsOnCoord(
        points: inout [CGPoint],
        coord: String,
        value: CGFloat,
        delta: CGFloat,
        tol: CGFloat = 1
    ) {
        for i in points.indices {
            let p = points[i]
            if coord == "y" && abs(p.y - value) < tol {
                points[i] = CGPoint(x: p.x, y: p.y + delta)
            } else if coord == "x" && abs(p.x - value) < tol {
                points[i] = CGPoint(x: p.x + delta, y: p.y)
            }
        }
    }

    private static func deconflictRoutePolylines(routes: inout [GraphEdgeRoute]) {
        for _ in 0..<maxDeconflictPasses {
            typealias HSeg = (CGFloat, CGFloat, CGFloat, Int, Int)
            typealias VSeg = (CGFloat, CGFloat, CGFloat, Int, Int)
            var hSegs: [HSeg] = []
            var vSegs: [VSeg] = []

            for (ri, route) in routes.enumerated() {
                let pts = route.points
                if polylineIsSingleColumn(pts) { continue }
                for pi in 0..<(pts.count - 1) {
                    guard let axis = segAxisAligned(pts[pi], pts[pi + 1]) else { continue }
                    if axis == "h" {
                        let y = (pts[pi].y + pts[pi + 1].y) / 2
                        hSegs.append((
                            y,
                            min(pts[pi].x, pts[pi + 1].x),
                            max(pts[pi].x, pts[pi + 1].x),
                            ri,
                            pi
                        ))
                    } else if axis == "v" {
                        let x = (pts[pi].x + pts[pi + 1].x) / 2
                        vSegs.append((
                            x,
                            min(pts[pi].y, pts[pi + 1].y),
                            max(pts[pi].y, pts[pi + 1].y),
                            ri,
                            pi
                        ))
                    }
                }
            }

            var moved = false
            for i in 0..<hSegs.count {
                for j in (i + 1)..<hSegs.count {
                    let h1 = hSegs[i]
                    let h2 = hSegs[j]
                    if abs(h1.0 - h2.0) >= deconflictTol { continue }
                    if !rangesOverlap(h1.1, h1.2, h2.1, h2.2, tol: 2) { continue }
                    let ri = h2.3
                    let y = h2.0
                    if polylineIsSingleColumn(routes[ri].points) { continue }
                    nudgePointsOnCoord(points: &routes[ri].points, coord: "y", value: y, delta: minChannelSep)
                    moved = true
                }
            }

            for i in 0..<vSegs.count {
                for j in (i + 1)..<vSegs.count {
                    let v1 = vSegs[i]
                    let v2 = vSegs[j]
                    if abs(v1.0 - v2.0) >= deconflictTol { continue }
                    if !rangesOverlap(v1.1, v1.2, v2.1, v2.2, tol: 2) { continue }
                    let ri = v2.3
                    let x = v2.0
                    if polylineIsSingleColumn(routes[ri].points) { continue }
                    nudgePointsOnCoord(points: &routes[ri].points, coord: "x", value: x, delta: minChannelSep)
                    moved = true
                }
            }

            if moved {
                for i in routes.indices {
                    routes[i].points = enforceOrthogonalPolyline(dedupePolylinePoints(routes[i].points))
                }
            } else {
                break
            }
        }

        for i in routes.indices {
            routes[i].points = enforceOrthogonalPolyline(dedupePolylinePoints(routes[i].points))
        }
    }

    // MARK: - Route edges

    private static func routeEdges(
        edgeList: [EdgeKey],
        nodeRects: [String: CGRect],
        layerOfPath: [String: Int],
        gutterCenters: [Int: CGFloat],
        colorTheme: String,
        contentLeft: CGFloat,
        contentWidth: CGFloat,
        pathOrder: [String: Int]?
    ) -> [GraphEdgeRoute] {
        let canonical = edgeList.filter {
            nodeRects[$0.source] != nil && nodeRects[$0.target] != nil
        }

        var attachments = computeEdgeAttachments(edgeList: canonical, nodeRects: nodeRects)
        alignTailToHeadOnBorder(attachments: &attachments, edgeList: canonical, nodeRects: nodeRects)

        var outgoingLanes: [String: [EdgeKey]] = [:]
        for edge in canonical {
            outgoingLanes[edge.source, default: []].append(edge)
        }
        for sp in outgoingLanes.keys {
            outgoingLanes[sp]?.sort { a, b in
                let ra = nodeRects[a.target]!
                let rb = nodeRects[b.target]!
                if ra.center.y != rb.center.y { return ra.center.y < rb.center.y }
                return ra.center.x < rb.center.x
            }
        }

        let gutterYOffsets = assignGlobalGutterOffsets(
            canonical: canonical,
            layerOfPath: layerOfPath,
            gutterCenters: gutterCenters,
            nodeRects: nodeRects,
            attachments: attachments
        )
        let contentRight = contentLeft + contentWidth
        let vertChannels = assignGlobalVertChannels(
            canonical: canonical,
            attachments: attachments,
            layerOfPath: layerOfPath,
            nodeRects: nodeRects,
            contentLeft: contentLeft,
            contentRight: contentRight
        )

        let colorMap = assignEdgeColors(
            canonical: canonical,
            outgoingLanes: outgoingLanes,
            colorTheme: colorTheme,
            pathOrder: pathOrder
        )
        let defaultColor = edgeColorPalette(theme: colorTheme).first ?? "#0088FF"

        var routes: [GraphEdgeRoute] = []
        for edge in canonical {
            guard let srcRect = nodeRects[edge.source],
                  let tgtRect = nodeRects[edge.target],
                  let pair = attachments[edge] else { continue }
            let (srcAttach, tgtAttach) = pair
            let sl = layerOfPath[edge.source, default: 0]
            let tl = layerOfPath[edge.target, default: 0]
            let onSpine = edgeUsesVerticalSpine(
                srcAttach: srcAttach, tgtAttach: tgtAttach, srcRect: srcRect, tgtRect: tgtRect
            ) || edgeUsesHorizontalSpine(
                srcAttach: srcAttach, tgtAttach: tgtAttach, srcRect: srcRect, tgtRect: tgtRect
            )
            let xCh = vertChannels[edge]
            let xS = srcAttach.x
            let useChannel: CGFloat? = onSpine
                ? nil
                : (xCh != nil && abs(xCh! - xS) > 0.5 ? xCh : nil)
            let gOff = onSpine ? 0 : primaryGutterOffset(
                gutterYOffsets: gutterYOffsets[edge, default: [:]],
                srcLayer: sl,
                tgtLayer: tl
            )
            let points = orthogonalPolyline(
                srcAttach: srcAttach,
                tgtAttach: tgtAttach,
                srcRect: srcRect,
                tgtRect: tgtRect,
                srcLayer: sl,
                tgtLayer: tl,
                gutterCenters: gutterCenters,
                gutterYOffset: gOff,
                vertChannelX: useChannel
            )
            routes.append(GraphEdgeRoute(
                sourcePath: edge.source,
                targetPath: edge.target,
                points: points,
                color: colorMap[edge, default: defaultColor]
            ))
        }

        deconflictRoutePolylines(routes: &routes)
        return routes
    }
}

// MARK: - CGRect helpers

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
