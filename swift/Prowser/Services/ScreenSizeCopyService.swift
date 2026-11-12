import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Creates screen-sized image copies. Port of `screen_size_copy.py`.
enum ScreenSizeCopyService {
    enum FitMethod: String {
        case contain
        case cover
        case width
        case height

        init(configValue: String) {
            self = FitMethod(rawValue: configValue) ?? .cover
        }
    }

    enum CopyError: LocalizedError {
        case fileNotFound
        case loadFailed
        case saveFailed
        case unsupportedFormat

        var errorDescription: String? {
            switch self {
            case .fileNotFound: return "Image file not found."
            case .loadFailed: return "Could not load image."
            case .saveFailed: return "Could not save screen-sized copy."
            case .unsupportedFormat:
                return "Unsupported file type for screen size copy (same types as Resize: JPEG, PNG, GIF, BMP, WebP, TIFF)."
            }
        }
    }

    /// Output formats ImageIO / WebPImageWriter can write (port of Python `screen_size_copy` format_map + Resize parity).
    static func supportsOutputFormat(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ImageReencodeMetadata.saveFormatName(for: ext) != nil
    }

    static func physicalScreenSize() -> CGSize {
        NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
    }

    private static func orientedPixelSize(path: String, ignoreExifRotation: Bool) -> (width: Int, height: Int)? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, sourceOptions as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions as CFDictionary) as? [CFString: Any] else {
            return nil
        }
        guard let rawWidth = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let rawHeight = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              rawWidth > 0, rawHeight > 0 else {
            return nil
        }
        if ignoreExifRotation {
            return (rawWidth, rawHeight)
        }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5 ... 8).contains(orientation) {
            return (rawHeight, rawWidth)
        }
        return (rawWidth, rawHeight)
    }

    private static func expectedOutputDimensions(
        imageWidth: Int,
        imageHeight: Int,
        bordersOnCopy: Bool
    ) -> (width: Int, height: Int) {
        let screen = physicalScreenSize()
        let screenWidth = Int(screen.width.rounded())
        let screenHeight = Int(screen.height.rounded())
        guard imageWidth > 0, imageHeight > 0, screenWidth > 0, screenHeight > 0 else {
            return (imageWidth, imageHeight)
        }
        let scaleX = Double(screenWidth) / Double(imageWidth)
        let scaleY = Double(screenHeight) / Double(imageHeight)
        if !bordersOnCopy {
            let scale = min(scaleX, scaleY)
            return (
                max(1, Int(Double(imageWidth) * scale)),
                max(1, Int(Double(imageHeight) * scale))
            )
        }
        return (screenWidth, screenHeight)
    }

    private static func checkImageNeedsResize(
        path: String,
        bordersOnCopy: Bool,
        ignoreExifRotation: Bool
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard supportsOutputFormat(path: path) else { return false }
        guard let (imgWidth, imgHeight) = orientedPixelSize(path: path, ignoreExifRotation: ignoreExifRotation) else {
            return true
        }
        let expected = expectedOutputDimensions(
            imageWidth: imgWidth,
            imageHeight: imgHeight,
            bordersOnCopy: bordersOnCopy
        )
        return (imgWidth, imgHeight) != (expected.width, expected.height)
    }

    static func wouldDownsize(
        path: String,
        fitMethod: FitMethod,
        bordersOnCopy: Bool,
        ignoreExifRotation: Bool
    ) -> Bool {
        guard let (imgWidth, imgHeight) = orientedPixelSize(path: path, ignoreExifRotation: ignoreExifRotation) else {
            return false
        }
        let screen = physicalScreenSize()
        let screenWidth = Double(Int(screen.width.rounded()))
        let screenHeight = Double(Int(screen.height.rounded()))
        guard imgWidth > 0, imgHeight > 0 else { return false }
        let scaleX = screenWidth / Double(imgWidth)
        let scaleY = screenHeight / Double(imgHeight)
        let scale: Double
        if !bordersOnCopy {
            scale = min(scaleX, scaleY)
        } else {
            switch fitMethod {
            case .contain: scale = min(scaleX, scaleY)
            case .cover: scale = max(scaleX, scaleY)
            case .width: scale = scaleX
            case .height: scale = scaleY
            }
        }
        return scale < 1.0
    }

    static func filesNeedingResize(
        paths: [String],
        bordersOnCopy: Bool,
        ignoreExifRotation: Bool
    ) -> [String] {
        paths.filter {
            checkImageNeedsResize(
                path: $0,
                bordersOnCopy: bordersOnCopy,
                ignoreExifRotation: ignoreExifRotation
            )
        }
    }

    static func createCopy(
        path: String,
        fitMethod: FitMethod,
        bordersOnCopy: Bool,
        preserveDates: Bool,
        ignoreExifRotation: Bool = false
    ) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CopyError.fileNotFound
        }

        let sourceExt = (path as NSString).pathExtension.lowercased()
        guard let saveFormat = ImageReencodeMetadata.saveFormatName(for: sourceExt) else {
            throw CopyError.unsupportedFormat
        }
        let screen = physicalScreenSize()
        let screenWidth = Int(screen.width.rounded())
        let screenHeight = Int(screen.height.rounded())

        guard let opened = RasterImagePipeline.open(path: path) else {
            throw CopyError.loadFailed
        }
        let displayedSize = opened.displayedSize(ignoreExifRotation: ignoreExifRotation)
        let metaWidth = displayedSize.width
        let metaHeight = displayedSize.height
        guard metaWidth > 0, metaHeight > 0 else {
            throw CopyError.loadFailed
        }

        let scaleX = Double(screenWidth) / Double(metaWidth)
        let scaleY = Double(screenHeight) / Double(metaHeight)
        let scale: Double
        if !bordersOnCopy {
            scale = min(scaleX, scaleY)
        } else {
            switch fitMethod {
            case .contain: scale = min(scaleX, scaleY)
            case .cover: scale = max(scaleX, scaleY)
            case .width: scale = scaleX
            case .height: scale = scaleY
            }
        }

        let newWidth = max(1, Int(Double(metaWidth) * scale))
        let newHeight = max(1, Int(Double(metaHeight) * scale))
        let displayedOutputWidth = bordersOnCopy ? screenWidth : newWidth
        let displayedOutputHeight = bordersOnCopy ? screenHeight : newHeight
        let rawOutput = opened.rawOutputSize(
            displayedWidth: displayedOutputWidth,
            displayedHeight: displayedOutputHeight,
            ignoreExifRotation: ignoreExifRotation
        )

        let outputPath = uniqueOutputPath(for: path)
        let outputURL = URL(fileURLWithPath: outputPath)
        let outDir = outputURL.deletingLastPathComponent()
        let tempURL = outDir
            .appendingPathComponent(".screensize_\(UUID().uuidString)")
            .appendingPathExtension(sourceExt)

        do {
            let decoded = try RasterImagePipeline.decode(opened)
            let supportsAlpha = ["PNG", "GIF", "WEBP", "TIFF"].contains(saveFormat)
            let preserveAlpha = supportsAlpha && opened.hasAlpha
            let needsRGBABytes = preserveAlpha || saveFormat == "WEBP"

            let rawDrawRect: CGRect
            if bordersOnCopy {
                let displayedDrawWidth = CGFloat(metaWidth) * scale
                let displayedDrawHeight = CGFloat(metaHeight) * scale
                let swapsAxes = !ignoreExifRotation && (5 ... 8).contains(opened.orientation)
                let rawDrawWidth = swapsAxes ? displayedDrawHeight : displayedDrawWidth
                let rawDrawHeight = swapsAxes ? displayedDrawWidth : displayedDrawHeight
                rawDrawRect = CGRect(
                    x: (CGFloat(rawOutput.width) - rawDrawWidth) / 2,
                    y: (CGFloat(rawOutput.height) - rawDrawHeight) / 2,
                    width: rawDrawWidth,
                    height: rawDrawHeight
                )
            } else {
                rawDrawRect = CGRect(
                    x: 0,
                    y: 0,
                    width: rawOutput.width,
                    height: rawOutput.height
                )
            }

            let rendered = try RasterImagePipeline.render(
                image: decoded,
                width: rawOutput.width,
                height: rawOutput.height,
                drawRect: rawDrawRect,
                interpolationQuality: .high,
                useAlphaChannel: needsRGBABytes,
                colorSpace: RasterImagePipeline.outputColorSpace(for: decoded, opened: opened),
                background: bordersOnCopy
                    ? CGColor(red: 0, green: 0, blue: 0, alpha: 1)
                    : (preserveAlpha
                        ? CGColor(red: 0, green: 0, blue: 0, alpha: 0)
                        : CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            )
            try RasterImagePipeline.write(
                image: rendered,
                opened: opened,
                to: tempURL,
                rawWidth: rawOutput.width,
                rawHeight: rawOutput.height,
                preserveMetadata: ExifService.canWriteExif(path: outputPath)
            )
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw CopyError.saveFailed
        }

        do {
            try FileManager.default.moveItem(at: tempURL, to: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw CopyError.saveFailed
        }

        if preserveDates {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                var outAttrs: [FileAttributeKey: Any] = [:]
                if let mtime = attrs[.modificationDate] { outAttrs[.modificationDate] = mtime }
                if let ctime = attrs[.creationDate] { outAttrs[.creationDate] = ctime }
                if !outAttrs.isEmpty {
                    try? FileManager.default.setAttributes(outAttrs, ofItemAtPath: outputPath)
                }
            }
        }

        return outputPath
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
}
