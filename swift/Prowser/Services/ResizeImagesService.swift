import CoreGraphics
import Foundation
import ImageIO

/// Image resize port of `browser_window/managers/resize_images.py`.
@MainActor
enum ResizeImagesService {
    static let maxResizeDimension = 6000
    static let percentScaleMin = 20
    static let percentScaleMax = 200
    static let percentScaleDefault = 100

    enum ResampleMethod: String, CaseIterable, Identifiable {
        case lanczos
        case bicubic
        case bilinear
        case nearest

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .lanczos: return "Lanczos"
            case .bicubic: return "Bicubic"
            case .bilinear: return "Bilinear"
            case .nearest: return "Nearest"
            }
        }

        static func fromSettingsLabel(_ label: String) -> ResampleMethod {
            ResampleMethod.allCases.first { $0.displayName == label } ?? .lanczos
        }

        var interpolationQuality: CGInterpolationQuality {
            switch self {
            case .lanczos: return .high
            case .bicubic: return .medium
            case .bilinear: return .low
            case .nearest: return .none
            }
        }
    }

    struct ResizeRequest {
        var targetWidth: Int
        var targetHeight: Int
        var preserveAspect: Bool
        var anchorIsWidth: Bool
        var usePercentScale: Bool
        var percentScale: Int
        var resampleMethod: ResampleMethod
        var deleteOriginal: Bool
        var preserveDates: Bool
        var ignoreExifRotation: Bool
    }

    struct ResizeFileResult {
        var success: Bool
        var error: String?
        var wroteFile: Bool
        var outputPath: String?
    }

    struct BatchResult {
        var resizedCount: Int
        var outputPaths: [String]
        var errors: [String]
        var stoppedEarly: Bool
    }

    enum ResizeError: LocalizedError {
        case fileNotFound
        case loadFailed
        case saveFailed
        case locked
        case photosLibrary
        case unsupportedType

        var errorDescription: String? {
            switch self {
            case .fileNotFound: return "File does not exist"
            case .loadFailed: return "Could not open image"
            case .saveFailed: return "Failed to save"
            case .locked: return "File is locked"
            case .photosLibrary: return "Cannot resize files inside a Photos Library"
            case .unsupportedType: return "Unsupported file type for resize"
            }
        }
    }

    static func dimensions(for path: String) -> (width: Int, height: Int)? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    static func percentModeAllowed(refWidth: Int, refHeight: Int) -> Bool {
        refWidth <= maxResizeDimension && refHeight <= maxResizeDimension
    }

    static func maxPercentForReference(refWidth: Int, refHeight: Int) -> Int {
        guard refWidth > 0, refHeight > 0 else { return percentScaleMax }
        let maxW = maxResizeDimension * 100 / refWidth
        let maxH = maxResizeDimension * 100 / refHeight
        return max(percentScaleMin, min(percentScaleMax, maxW, maxH))
    }

    static func dimensionsFromPercent(refWidth: Int, refHeight: Int, percent: Int) -> (width: Int, height: Int) {
        let maxPct = maxPercentForReference(refWidth: refWidth, refHeight: refHeight)
        let pct = max(percentScaleMin, min(maxPct, percent))
        var w = max(1, Int(round(Double(refWidth) * Double(pct) / 100.0)))
        var h = max(1, Int(round(Double(refHeight) * Double(pct) / 100.0)))
        w = min(w, maxResizeDimension)
        h = min(h, maxResizeDimension)
        return (w, h)
    }

    static func bestFitWithinBounds(
        origW: Int,
        origH: Int,
        boundW: Int,
        boundH: Int,
        maxDim: Int
    ) -> (width: Int, height: Int) {
        guard origW > 0, origH > 0 else {
            return (max(1, min(maxDim, boundW)), max(1, min(maxDim, boundH)))
        }
        let bw = max(1, boundW)
        let bh = max(1, boundH)
        let cap = max(1, maxDim)
        let scale = min(Double(bw) / Double(origW), Double(bh) / Double(origH), Double(cap) / Double(origW), Double(cap) / Double(origH))
        var tw = max(1, Int(round(Double(origW) * scale)))
        var th = max(1, Int(round(Double(origH) * scale)))
        tw = min(tw, cap)
        th = min(th, cap)
        return (tw, th)
    }

    private static func computeTargetSize(
        origW: Int,
        origH: Int,
        dialogW: Int,
        dialogH: Int,
        preserveAspect: Bool,
        anchorIsWidth: Bool
    ) -> (width: Int, height: Int) {
        guard origW > 0, origH > 0 else {
            return (max(1, dialogW), max(1, dialogH))
        }
        if !preserveAspect {
            return (max(1, dialogW), max(1, dialogH))
        }
        if anchorIsWidth {
            let tw = max(1, dialogW)
            let th = max(1, Int(round(Double(origH) * Double(tw) / Double(origW))))
            return (tw, th)
        }
        let th = max(1, dialogH)
        let tw = max(1, Int(round(Double(origW) * Double(th) / Double(origH))))
        return (tw, th)
    }

    static func resizeFile(path: String, request: ResizeRequest) -> ResizeFileResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return ResizeFileResult(success: false, error: ResizeError.fileNotFound.localizedDescription, wroteFile: false, outputPath: nil)
        }
        if RenamePrefixPlanner.isInsidePhotosLibrary(path) {
            return ResizeFileResult(success: false, error: ResizeError.photosLibrary.localizedDescription, wroteFile: false, outputPath: nil)
        }
        if PrsortIO.isFileLocked(path) {
            return ResizeFileResult(success: false, error: ResizeError.locked.localizedDescription, wroteFile: false, outputPath: nil)
        }

        let ext = (path as NSString).pathExtension.lowercased()
        guard ImageReencodeMetadata.saveFormatName(for: ext) != nil else {
            return ResizeFileResult(success: false, error: ResizeError.unsupportedType.localizedDescription, wroteFile: false, outputPath: nil)
        }
        guard let opened = RasterImagePipeline.open(path: path) else {
            return ResizeFileResult(success: false, error: ResizeError.loadFailed.localizedDescription, wroteFile: false, outputPath: nil)
        }

        var origAtime: Date?
        var origMtime: Date?
        if request.preserveDates {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            origAtime = attrs?[.creationDate] as? Date
            origMtime = attrs?[.modificationDate] as? Date
        }

        let sourceSize = opened.displayedSize(ignoreExifRotation: request.ignoreExifRotation)
        let ow = sourceSize.width
        let oh = sourceSize.height
        guard ow > 0, oh > 0 else {
            return ResizeFileResult(success: false, error: ResizeError.loadFailed.localizedDescription, wroteFile: false, outputPath: nil)
        }
        let (tw, th): (Int, Int)
        if request.usePercentScale {
            let pct = max(percentScaleMin, min(percentScaleMax, request.percentScale))
            tw = max(1, min(maxResizeDimension, Int(round(Double(ow) * Double(pct) / 100.0))))
            th = max(1, min(maxResizeDimension, Int(round(Double(oh) * Double(pct) / 100.0))))
        } else {
            (tw, th) = computeTargetSize(
                origW: ow,
                origH: oh,
                dialogW: request.targetWidth,
                dialogH: request.targetHeight,
                preserveAspect: request.preserveAspect,
                anchorIsWidth: request.anchorIsWidth
            )
        }

        if tw == ow && th == oh {
            return ResizeFileResult(success: true, error: nil, wroteFile: false, outputPath: nil)
        }

        let rawTarget = opened.rawOutputSize(
            displayedWidth: tw,
            displayedHeight: th,
            ignoreExifRotation: request.ignoreExifRotation
        )
        let finalPath = request.deleteOriginal ? path : uniqueOutputPath(for: path)
        let finalURL = URL(fileURLWithPath: finalPath)
        let outDir = finalURL.deletingLastPathComponent()
        let tempURL = outDir
            .appendingPathComponent(".resize_\(UUID().uuidString)")
            .appendingPathExtension((path as NSString).pathExtension)

        do {
            let decoded = try RasterImagePipeline.decode(opened)
            let supportsAlpha = ["PNG", "GIF", "WEBP", "TIFF"].contains(opened.saveFormat)
            let preserveAlpha = supportsAlpha && opened.hasAlpha
            let needsRGBABytes = preserveAlpha || opened.saveFormat == "WEBP"
            let resized = try RasterImagePipeline.render(
                image: decoded,
                width: rawTarget.width,
                height: rawTarget.height,
                interpolationQuality: request.resampleMethod.interpolationQuality,
                useAlphaChannel: needsRGBABytes,
                colorSpace: RasterImagePipeline.outputColorSpace(for: decoded, opened: opened),
                background: preserveAlpha
                    ? CGColor(red: 0, green: 0, blue: 0, alpha: 0)
                    : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            )
            try RasterImagePipeline.write(
                image: resized,
                opened: opened,
                to: tempURL,
                rawWidth: rawTarget.width,
                rawHeight: rawTarget.height
            )
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ResizeFileResult(success: false, error: message, wroteFile: false, outputPath: nil)
        }

        do {
            if request.deleteOriginal {
                _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: finalURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return ResizeFileResult(success: false, error: "Failed to save: \(error.localizedDescription)", wroteFile: false, outputPath: nil)
        }

        if request.preserveDates {
            var attrs: [FileAttributeKey: Any] = [:]
            if let origMtime { attrs[.modificationDate] = origMtime }
            if let origAtime { attrs[.creationDate] = origAtime }
            if !attrs.isEmpty {
                try? FileManager.default.setAttributes(attrs, ofItemAtPath: finalPath)
            }
        }

        return ResizeFileResult(success: true, error: nil, wroteFile: true, outputPath: finalPath)
    }

    static func resizeBatch(
        paths: [String],
        request: ResizeRequest,
        progress: CancellableProgressPanelController?
    ) -> BatchResult {
        var resizedCount = 0
        var outputPaths: [String] = []
        var errors: [String] = []
        var stoppedEarly = false
        let total = paths.count
        defer { progress?.close() }

        for (index, path) in paths.enumerated() {
            if let progress, progress.cancelRequested {
                stoppedEarly = true
                break
            }

            let result = resizeFile(path: path, request: request)
            if result.success, result.wroteFile, let output = result.outputPath {
                resizedCount += 1
                outputPaths.append(output)
            } else if !result.success {
                let name = (path as NSString).lastPathComponent
                errors.append("\(name): \(result.error ?? "resize failed")")
            }

            if let progress {
                progress.serviceBatchIteration(
                    value: index + 1,
                    label: "Resizing \(min(index + 1, total)) of \(total)",
                    pumpDeadline: 0.002
                )
                if progress.cancelRequested {
                    stoppedEarly = true
                    break
                }
            }
        }
        return BatchResult(
            resizedCount: resizedCount,
            outputPaths: outputPaths,
            errors: errors,
            stoppedEarly: stoppedEarly
        )
    }

    // MARK: - Private helpers

    private static func uniqueOutputPath(for path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let filename = (path as NSString).lastPathComponent
        let ext = (filename as NSString).pathExtension
        let name = (filename as NSString).deletingPathExtension
        let suffixExt = ext.isEmpty ? "" : ".\(ext)"

        for counter in 1...9999 {
            let candidate = "\(name)-\(String(format: "%04d", counter))\(suffixExt)"
            let full = (directory as NSString).appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: full) {
                return full
            }
        }
        return (directory as NSString).appendingPathComponent("\(name)-copy\(suffixExt)")
    }

}
