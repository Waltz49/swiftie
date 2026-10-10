import SwiftUI

@MainActor
struct ImageGenExpandPreviewPane: View {
    @Binding var values: [String: Any]
    let sourcePath: String?
    let pipelineID: String
    var onSourcePathChanged: ((String) -> Void)?
    var onValuesChanged: (() -> Void)?

    @State private var placementSeedApplied = false

    private var canvasWidth: Int {
        intValue(values["width"], default: 1024)
    }

    private var canvasHeight: Int {
        intValue(values["height"], default: 1024)
    }

    private var placementFromValues: (x: Int, y: Int, w: Int, h: Int)? {
        guard let px = values["placement_x"] as? Int ?? anyInt(values["placement_x"]),
              let py = values["placement_y"] as? Int ?? anyInt(values["placement_y"]),
              let pw = values["placement_w"] as? Int ?? anyInt(values["placement_w"]),
              let ph = values["placement_h"] as? Int ?? anyInt(values["placement_h"]) else {
            return nil
        }
        return (px, py, pw, ph)
    }

    private var maskNote: String {
        switch pipelineID {
        case "mflux_flux2_klein_expand":
            return "Klein expand uses edit-style outfill with placement preserved "
                + "after generation. For mask-constrained expansion, select FLUX.1-Fill-dev."
        case "mflux_fill_expand":
            return "Uses mask-constrained outfill (FLUX Fill)."
        default:
            return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = sourcePath {
                ImageGenSourceNavRow(currentPath: path, onSelectPath: { newPath in
                    onSourcePathChanged?(newPath)
                }) {
                    ExpandPlacementCanvasRepresentable(
                        sourcePath: path,
                        canvasWidth: canvasWidth,
                        canvasHeight: canvasHeight,
                        placement: placementFromValues,
                        onPlacementChanged: { px, py, pw, ph in
                            values["placement_x"] = px
                            values["placement_y"] = py
                            values["placement_w"] = pw
                            values["placement_h"] = ph
                            onValuesChanged?()
                        }
                    )
                    .frame(minHeight: 280)
                }
                if !maskNote.isEmpty {
                    Text(maskNote)
                        .font(ImageGenInlineFieldLayout.infoLineFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Expand requires an active source image.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { seedPlacementIfNeeded() }
        .onChange(of: sourcePath) { _, _ in
            placementSeedApplied = false
            seedPlacementIfNeeded()
        }
        .onChange(of: canvasWidth) { _, _ in syncCanvasDimensions() }
        .onChange(of: canvasHeight) { _, _ in syncCanvasDimensions() }
    }

    private func seedPlacementIfNeeded() {
        guard placementFromValues == nil, sourcePath != nil, !placementSeedApplied else { return }
        let aspect = sourceAspect(path: sourcePath!)
        let fit = ExpandPlacementMath.centeredFit(
            canvasW: canvasWidth,
            canvasH: canvasHeight,
            sourceAspect: aspect
        )
        values["placement_x"] = fit.x
        values["placement_y"] = fit.y
        values["placement_w"] = fit.w
        values["placement_h"] = fit.h
        placementSeedApplied = true
        onValuesChanged?()
    }

    private func syncCanvasDimensions() {
        onValuesChanged?()
    }

    private func intValue(_ any: Any?, default defaultValue: Int) -> Int {
        if let value = any as? Int { return value }
        if let value = any as? Double { return Int(value) }
        if let value = any as? NSNumber { return value.intValue }
        return defaultValue
    }

    private func anyInt(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? Double { return Int(value) }
        if let value = any as? NSNumber { return value.intValue }
        return nil
    }

    private func sourceAspect(path: String) -> Double {
        guard let cg = ImageGenOutpaintMask.loadCGImage(path: path), cg.height > 0 else { return 1 }
        return Double(cg.width) / Double(cg.height)
    }
}
