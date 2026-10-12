import CoreGraphics
import Foundation

/// Port of ``pixelmator_export`` infill export helpers (paint → job batch dir).
enum InfillExportService {
    static func missingInfillExportPaths(_ values: [String: Any]) -> [String] {
        var missing: [String] = []
        for (key, label) in [("pixelmator_base_path", "infill base image"), ("pixelmator_mask_path", "infill mask")] {
            let path = (values[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if path.isEmpty || !FileManager.default.isReadableFile(atPath: path) {
                missing.append(path.isEmpty ? "(\(label))" : path)
            }
        }
        return missing
    }

    static func validateInfillExportDimensions(basePath: String, maskPath: String) -> String? {
        let base = basePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let mask = maskPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty || !FileManager.default.isReadableFile(atPath: base) {
            return "Infill base image export is missing."
        }
        if mask.isEmpty || !FileManager.default.isReadableFile(atPath: mask) {
            return "Infill mask export is missing."
        }
        guard let baseSize = ImageRecognitionImageLoader.orientedPixelSize(path: base),
              let maskSize = ImageRecognitionImageLoader.orientedPixelSize(path: mask) else {
            return "Could not read exported base or mask."
        }
        if baseSize.width != maskSize.width || baseSize.height != maskSize.height {
            return "Mask and image layers must be the same size "
                + "(\(maskSize.width)×\(maskSize.height) mask vs "
                + "\(baseSize.width)×\(baseSize.height) image)."
        }
        return nil
    }

    static func persistPaintInfillExports(
        sourcePath: String,
        mask: CGImage,
        maxSide: Int,
        tempRoot: URL
    ) throws -> [String: Any] {
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
        guard FileManager.default.isReadableFile(atPath: source) else {
            throw InfillExportError.sourceMissing(source)
        }
        guard let oriented = ImageRecognitionImageLoader.loadCGImage(path: source) else {
            throw InfillExportError.sourceUnreadable
        }
        let (workW, workH) = ImageGenInfillMath.fitInfillPaintDims(
            width: oriented.width,
            height: oriented.height,
            maxSide: maxSide
        )
        let baseCG: CGImage
        if oriented.width != workW || oriented.height != workH {
            baseCG = ImageGenOutpaintMask.resizeImagePublic(oriented, width: workW, height: workH)
        } else {
            baseCG = oriented
        }
        var maskImage = mask
        if mask.width != workW || mask.height != workH {
            maskImage = ImageGenOutpaintMask.resizeImagePublic(mask, width: workW, height: workH)
        }

        let jobDir = ProwserTempFiles.makeInfillBatchDirectory(tempRoot: tempRoot)
        let ext = (source as NSString).pathExtension
        let baseExt = ext.isEmpty ? "png" : ext
        let baseDest = (jobDir as NSString).appendingPathComponent("base.\(baseExt)")
        let maskDest = (jobDir as NSString).appendingPathComponent("mask.png")

        guard ImageGenOutpaintMask.savePNG(baseCG, path: baseDest),
              ImageGenOutpaintMask.savePNG(maskImage, path: maskDest) else {
            throw InfillExportError.writeFailed
        }

        return [
            "pixelmator_base_path": baseDest,
            "pixelmator_mask_path": maskDest,
            "pixelmator_doc_name": (source as NSString).lastPathComponent,
            "pixelmator_doc_path": source,
            "width": workW,
            "height": workH,
            "_pixelmator_batch_dir": jobDir,
        ]
    }

    static func removePersistedBatch(values: [String: Any]) {
        guard let jobDir = values["_pixelmator_batch_dir"] as? String, !jobDir.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: jobDir)
    }

    static func writePaintInfillForPixelmator(
        basePath: String,
        mask: CGImage,
        tempRoot: URL
    ) throws -> (base: String, mask: String) {
        let source = URL(fileURLWithPath: basePath).standardizedFileURL.path
        guard FileManager.default.isReadableFile(atPath: source) else {
            throw InfillExportError.sourceMissing(source)
        }
        let jobDir = ProwserTempFiles.makeInfillBatchDirectory(tempRoot: tempRoot)
        let ext = (source as NSString).pathExtension
        let baseExt = ext.isEmpty ? "png" : ext
        let baseDest = (jobDir as NSString).appendingPathComponent("base.\(baseExt)")
        let maskDest = (jobDir as NSString).appendingPathComponent("mask.png")
        try FileManager.default.copyItem(atPath: source, toPath: baseDest)
        guard let pixel = ImageGenInfillMath.paintMaskToPixelmatorRGBA(mask),
              ImageGenOutpaintMask.savePNG(pixel, path: maskDest) else {
            throw InfillExportError.writeFailed
        }
        return (baseDest, maskDest)
    }
}

enum InfillExportError: LocalizedError {
    case sourceMissing(String)
    case sourceUnreadable
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .sourceMissing(let path):
            return "Source image not found: \(path)"
        case .sourceUnreadable:
            return "Could not load source image."
        case .writeFailed:
            return "Could not prepare base and mask."
        }
    }
}
