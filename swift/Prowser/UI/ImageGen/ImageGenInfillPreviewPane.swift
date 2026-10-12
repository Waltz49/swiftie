import SwiftUI

@MainActor
struct ImageGenInfillPreviewPane: View {
    @Environment(AppState.self) private var appState

    let sourcePath: String?
    let maxGenerationSide: Int
    var maskPNGData: Data?
    var navigationLocked: Bool
    var showRefineInPixelmator: Bool
    var canvasHolder: ImageGenInfillCanvasHolder
    var onSourcePathChanged: ((String) -> Void)?
    var onMaskPNGDataChanged: ((Data?) -> Void)?
    var onHasPaintChanged: ((Bool) -> Void)?
    var onPixelmatorDocPathChanged: ((String?) -> Void)?
    var onPixelmatorExportChanged: (([String: Any]) -> Void)?

    @State private var localHasPaint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = sourcePath {
                if showRefineInPixelmator {
                    HStack {
                        Spacer()
                        Button("Refine in Pixelmator") {
                            refineInPixelmator(sourcePath: path)
                        }
                        .help("Open the base and mask in Pixelmator Pro, then re-import exports.")
                    }
                    .padding(.bottom, 2)
                }
                ImageGenSourceNavRow(
                    currentPath: path,
                    navigationLocked: navigationLocked,
                    onSelectPath: { newPath in
                        onSourcePathChanged?(newPath)
                    }
                ) {
                    InfillPaintCanvasRepresentable(
                        sourcePath: path,
                        maxSide: maxGenerationSide,
                        maskPNGData: maskPNGData,
                        onMaskChanged: { data in
                            guard let view = canvasHolder.canvas else { return }
                            localHasPaint = view.hasPaintMask()
                            onHasPaintChanged?(localHasPaint)
                            onMaskPNGDataChanged?(data)
                        },
                        canvasRef: { view in
                            canvasHolder.canvas = view
                            localHasPaint = view.hasPaintMask()
                            onHasPaintChanged?(localHasPaint)
                        }
                    )
                    .frame(minHeight: 360)
                }
            } else {
                Text("Infill requires an active source image.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refineInPixelmator(sourcePath: String) {
        guard let view = canvasHolder.canvas, let mask = view.maskCGImage() else { return }
        let tempRoot = appState.config.temporaryFilesDirectory
        do {
            let pair = try InfillExportService.writePaintInfillForPixelmator(
                basePath: sourcePath,
                mask: mask,
                tempRoot: tempRoot
            )
            guard PixelmatorInfillService.launchPixelmatorProMultiFiles(paths: [pair.mask, pair.base]) else {
                StyledMessageDialog.showWarning(
                    title: "Refine in Pixelmator",
                    message: "Could not open Pixelmator Pro."
                )
                return
            }
            guard PixelmatorInfillService.runRefineDialog() else { return }
            switch PixelmatorInfillService.exportBaseAndMask(tempRoot: tempRoot) {
            case .failure(let err):
                StyledMessageDialog.showWarning(
                    title: "Refine in Pixelmator",
                    message: err.localizedDescription
                )
            case .success(let meta):
                applyPixelmatorReimport(meta: meta, view: view, originalSource: sourcePath)
            }
        } catch {
            StyledMessageDialog.showWarning(
                title: "Refine in Pixelmator",
                message: "Could not prepare files for Pixelmator Pro: \(error.localizedDescription)"
            )
        }
    }

    private func applyPixelmatorReimport(
        meta: [String: Any],
        view: InfillPaintCanvasView,
        originalSource: String
    ) {
        let basePath = (meta["pixelmator_base_path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let maskPath = (meta["pixelmator_mask_path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let err = InfillExportService.validateInfillExportDimensions(basePath: basePath, maskPath: maskPath) {
            StyledMessageDialog.showWarning(title: "Refine in Pixelmator", message: err)
            return
        }
        guard let paintMask = ImageGenInfillMath.pixelmatorMaskFileToPaintMask(maskPath) else {
            StyledMessageDialog.showWarning(
                title: "Refine in Pixelmator",
                message: "Could not load the mask exported from Pixelmator Pro."
            )
            return
        }
        let normBase = URL(fileURLWithPath: basePath).standardizedFileURL.path
        let normSource = URL(fileURLWithPath: originalSource).standardizedFileURL.path
        let sourceChanged = !normBase.isEmpty
            && normBase != normSource
            && FileManager.default.isReadableFile(atPath: normBase)

        if !sourceChanged {
            view.reloadSourceFromDisk()
        }
        if !view.loadMask(paintMask) {
            StyledMessageDialog.showWarning(
                title: "Refine in Pixelmator",
                message: "Could not apply the mask from Pixelmator Pro."
            )
            return
        }
        onMaskPNGDataChanged?(view.maskPNGData())
        localHasPaint = view.hasPaintMask()
        onHasPaintChanged?(localHasPaint)
        if sourceChanged {
            onSourcePathChanged?(normBase)
        }
        if let docPath = meta["pixelmator_doc_path"] as? String, !docPath.isEmpty {
            onPixelmatorDocPathChanged?(docPath)
        }
        onPixelmatorExportChanged?(meta)
    }
}
