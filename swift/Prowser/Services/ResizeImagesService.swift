import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Basic in-place image resize using Core Graphics. Port of `resize_images.py` (minimal).
@MainActor
enum ResizeImagesService {
    enum ResizeError: LocalizedError {
        case fileNotFound
        case loadFailed
        case saveFailed
        case locked

        var errorDescription: String? {
            switch self {
            case .fileNotFound: return "Image file not found."
            case .loadFailed: return "Could not load image."
            case .saveFailed: return "Could not save resized image."
            case .locked: return "File is locked."
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

    static func resize(
        path: String,
        width: Int,
        height: Int,
        preserveDates: Bool = true
    ) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ResizeError.fileNotFound
        }
        if PrsortIO.isFileLocked(path) {
            throw ResizeError.locked
        }

        let targetW = max(1, width)
        let targetH = max(1, height)
        let url = URL(fileURLWithPath: path)

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ResizeError.loadFailed
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.jpeg.identifier
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".prowser_resize_\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)

        guard let resized = resizeImage(image, width: targetW, height: targetH),
              let destination = CGImageDestinationCreateWithURL(
                tempURL as CFURL,
                uti as CFString,
                1,
                nil
              ) else {
            throw ResizeError.saveFailed
        }

        var properties: [CFString: Any] = [:]
        if uti == UTType.jpeg.identifier {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        }
        CGImageDestinationAddImage(destination, resized, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ResizeError.saveFailed
        }

        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)

        if preserveDates, let attrs {
            var outAttrs: [FileAttributeKey: Any] = [:]
            if let mtime = attrs[.modificationDate] { outAttrs[.modificationDate] = mtime }
            if let ctime = attrs[.creationDate] { outAttrs[.creationDate] = ctime }
            if !outAttrs.isEmpty {
                try? FileManager.default.setAttributes(outAttrs, ofItemAtPath: path)
            }
        }

        return path
    }

    static func resizeAll(
        paths: [String],
        width: Int,
        height: Int,
        preserveAspect: Bool,
        preserveDates: Bool = true
    ) -> (resized: [String], errors: [String]) {
        var resized: [String] = []
        var errors: [String] = []
        for path in paths {
            do {
                var targetW = width
                var targetH = height
                if preserveAspect, let dims = dimensions(for: path), dims.width > 0, dims.height > 0 {
                    let scaleW = Double(width) / Double(dims.width)
                    let scaleH = Double(height) / Double(dims.height)
                    let scale = min(scaleW, scaleH)
                    targetW = max(1, Int(Double(dims.width) * scale))
                    targetH = max(1, Int(Double(dims.height) * scale))
                }
                let output = try resize(path: path, width: targetW, height: targetH, preserveDates: preserveDates)
                resized.append(output)
            } catch {
                let name = (path as NSString).lastPathComponent
                errors.append("\(name): \(error.localizedDescription)")
            }
        }
        return (resized, errors)
    }

    private static func resizeImage(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
