import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

    static func computeTargetSize(
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
        guard let saveFormat = extensionSaveFormat(ext) else {
            return ResizeFileResult(success: false, error: ResizeError.unsupportedType.localizedDescription, wroteFile: false, outputPath: nil)
        }

        let userComment = ExifService.userComment(path: path)
        let sourceURL = URL(fileURLWithPath: path)
        var origAtime: Date?
        var origMtime: Date?
        if request.preserveDates {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            origAtime = attrs?[.creationDate] as? Date
            origMtime = attrs?[.modificationDate] as? Date
        }

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let uti = CGImageSourceGetType(source) else {
            return ResizeFileResult(success: false, error: ResizeError.loadFailed.localizedDescription, wroteFile: false, outputPath: nil)
        }

        guard let image = loadOrientedImage(from: source, ignoreExifRotation: request.ignoreExifRotation) else {
            return ResizeFileResult(success: false, error: ResizeError.loadFailed.localizedDescription, wroteFile: false, outputPath: nil)
        }

        let ow = image.width
        let oh = image.height
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

        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let preserveTransparency = ["PNG", "GIF", "WEBP", "TIFF"].contains(saveFormat)
        guard let resized = resizeImage(
            image,
            width: tw,
            height: th,
            preserveTransparency: preserveTransparency,
            method: request.resampleMethod
        ) else {
            return ResizeFileResult(success: false, error: ResizeError.saveFailed.localizedDescription, wroteFile: false, outputPath: nil)
        }

        let finalPath = request.deleteOriginal ? path : uniqueOutputPath(for: path)
        let finalURL = URL(fileURLWithPath: finalPath)
        let outDir = finalURL.deletingLastPathComponent()
        let tempURL = outDir
            .appendingPathComponent(".resize_\(UUID().uuidString)")
            .appendingPathExtension((path as NSString).pathExtension)

        if saveFormat == "WEBP" {
            do {
                try WebPImageWriter.write(
                    image: resized,
                    to: tempURL,
                    sourcePathForMetadata: path,
                    lossless: preserveTransparency && resizedHasAlpha(resized)
                )
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                return ResizeFileResult(
                    success: false,
                    error: error.localizedDescription,
                    wroteFile: false,
                    outputPath: nil
                )
            }
        } else {
            guard let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, uti, 1, nil) else {
                return ResizeFileResult(success: false, error: ResizeError.saveFailed.localizedDescription, wroteFile: false, outputPath: nil)
            }

            var destProperties = properties
            if var exif = destProperties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                if let userComment, !userComment.isEmpty {
                    exif[kCGImagePropertyExifUserComment] = ExifService.encodeUserCommentData(userComment)
                }
                destProperties[kCGImagePropertyExifDictionary] = exif
            } else if let userComment, !userComment.isEmpty, ExifService.canWriteExif(path: path) {
                destProperties[kCGImagePropertyExifDictionary] = [
                    kCGImagePropertyExifUserComment: ExifService.encodeUserCommentData(userComment),
                ]
            }

            let saveProps = destinationProperties(for: saveFormat, base: destProperties)
            CGImageDestinationAddImage(destination, resized, saveProps as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: tempURL)
                return ResizeFileResult(success: false, error: ResizeError.saveFailed.localizedDescription, wroteFile: false, outputPath: nil)
            }
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

        for (index, path) in paths.enumerated() {
            if progress?.cancelRequested == true {
                stoppedEarly = true
                break
            }
            progress?.update(value: index, label: "Resizing \(index + 1) of \(total)")

            if PrsortIO.isFileLocked(path) {
                errors.append("\((path as NSString).lastPathComponent): file is locked")
                continue
            }

            let result = resizeFile(path: path, request: request)
            if result.success, result.wroteFile, let output = result.outputPath {
                resizedCount += 1
                outputPaths.append(output)
            } else if !result.success {
                let name = (path as NSString).lastPathComponent
                errors.append("\(name): \(result.error ?? "resize failed")")
            }

            progress?.update(value: index + 1)
        }

        progress?.close()
        return BatchResult(
            resizedCount: resizedCount,
            outputPaths: outputPaths,
            errors: errors,
            stoppedEarly: stoppedEarly
        )
    }

    // MARK: - Private helpers

    private static func extensionSaveFormat(_ ext: String) -> String? {
        switch ext {
        case "jpg", "jpeg": return "JPEG"
        case "png": return "PNG"
        case "gif": return "GIF"
        case "bmp": return "BMP"
        case "webp": return "WEBP"
        case "tiff", "tif": return "TIFF"
        default: return nil
        }
    }

    private static func destinationProperties(for format: String, base: [CFString: Any]) -> [CFString: Any] {
        var props = base
        switch format {
        case "JPEG":
            props[kCGImageDestinationLossyCompressionQuality] = 0.95
        case "PNG":
            props[kCGImagePropertyPNGCompressionFilter] = 6
        case "WEBP":
            if let alpha = base[kCGImagePropertyHasAlpha] as? Bool, alpha {
                props[kCGImageDestinationLossyCompressionQuality] = 1.0
            } else {
                props[kCGImageDestinationLossyCompressionQuality] = 0.95
            }
        default:
            break
        }
        return props
    }

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

    private static func loadOrientedImage(from source: CGImageSource, ignoreExifRotation: Bool) -> CGImage? {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        if ignoreExifRotation {
            return image
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        guard let orientation = props[kCGImagePropertyOrientation] as? Int, orientation != 1 else {
            return image
        }
        return applyOrientation(image, orientation: orientation) ?? image
    }

    private static func applyOrientation(_ image: CGImage, orientation: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        var transform = CGAffineTransform.identity
        var drawWidth = width
        var drawHeight = height

        switch orientation {
        case 2:
            transform = transform.translatedBy(x: CGFloat(width), y: 0).scaledBy(x: -1, y: 1)
        case 3:
            transform = transform.translatedBy(x: CGFloat(width), y: CGFloat(height)).rotated(by: .pi)
        case 4:
            transform = transform.translatedBy(x: 0, y: CGFloat(height)).scaledBy(x: 1, y: -1)
        case 5:
            transform = transform.translatedBy(x: CGFloat(height), y: 0).rotated(by: .pi / 2).scaledBy(x: -1, y: 1)
            drawWidth = height
            drawHeight = width
        case 6:
            transform = transform.translatedBy(x: 0, y: 0).rotated(by: .pi / 2)
            drawWidth = height
            drawHeight = width
        case 7:
            transform = transform.translatedBy(x: CGFloat(height), y: CGFloat(width)).rotated(by: -.pi / 2).scaledBy(x: -1, y: 1)
            drawWidth = height
            drawHeight = width
        case 8:
            transform = transform.translatedBy(x: 0, y: CGFloat(width)).rotated(by: -.pi / 2)
            drawWidth = height
            drawHeight = width
        default:
            return image
        }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: drawWidth,
            height: drawHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        context.concatenate(transform)
        let drawRect: CGRect
        if orientation >= 5 && orientation <= 8 {
            drawRect = CGRect(x: 0, y: 0, width: height, height: width)
        } else {
            drawRect = CGRect(x: 0, y: 0, width: width, height: height)
        }
        context.draw(image, in: drawRect)
        return context.makeImage()
    }

    private static func resizedHasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }

    private static func resizeImage(
        _ image: CGImage,
        width: Int,
        height: Int,
        preserveTransparency: Bool,
        method: ResampleMethod
    ) -> CGImage? {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let alphaInfo: CGImageAlphaInfo = preserveTransparency ? .premultipliedLast : .noneSkipLast
        let bitmapInfo = alphaInfo.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        if !preserveTransparency {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        context.interpolationQuality = method.interpolationQuality
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
