import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Basic JPEG/PNG conversion using ImageIO. Port of `files/convert_format.py` (minimal).
@MainActor
enum ConvertFormatService {
    enum TargetFormat: String, CaseIterable, Identifiable {
        case jpeg
        case png

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .jpeg: return "JPEG"
            case .png: return "PNG"
            }
        }

        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            }
        }

        var utType: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .png: return .png
            }
        }
    }

    enum ConvertError: LocalizedError {
        case fileNotFound
        case loadFailed
        case saveFailed(String)
        case alreadyTargetFormat

        var errorDescription: String? {
            switch self {
            case .fileNotFound: return "Image file not found."
            case .loadFailed: return "Could not load image."
            case .saveFailed(let path): return "Could not save converted image to \(path)."
            case .alreadyTargetFormat: return "Image is already in the target format."
            }
        }
    }

    static func pathsNeedingConversion(_ paths: [String], target: TargetFormat) -> [String] {
        let targetExt = "." + target.fileExtension
        return paths.filter { path in
            guard FileManager.default.fileExists(atPath: path) else { return false }
            return (path as NSString).pathExtension.lowercased() != target.fileExtension
                && (path as NSString).pathExtension.lowercased() != targetExt.dropFirst()
        }
    }

    static func convert(
        path: String,
        to target: TargetFormat,
        deleteOriginal: Bool = false,
        preserveDates: Bool = true
    ) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ConvertError.fileNotFound
        }

        let sourceExt = (path as NSString).pathExtension.lowercased()
        if sourceExt == target.fileExtension || (target == .jpeg && sourceExt == "jpeg") {
            throw ConvertError.alreadyTargetFormat
        }

        let base = (path as NSString).deletingPathExtension
        let outputPath = base + "." + target.fileExtension
        let sourceURL = URL(fileURLWithPath: path)
        let outputURL = URL(fileURLWithPath: outputPath)

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConvertError.loadFailed
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            target.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ConvertError.saveFailed(outputPath)
        }

        var properties: [CFString: Any] = [:]
        if target == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConvertError.saveFailed(outputPath)
        }

        if preserveDates, let attrs {
            var outAttrs: [FileAttributeKey: Any] = [:]
            if let mtime = attrs[.modificationDate] { outAttrs[.modificationDate] = mtime }
            if let ctime = attrs[.creationDate] { outAttrs[.creationDate] = ctime }
            if !outAttrs.isEmpty {
                try? FileManager.default.setAttributes(outAttrs, ofItemAtPath: outputPath)
            }
        }

        if deleteOriginal {
            try? FileManager.default.removeItem(atPath: path)
        }

        return outputPath
    }

    static func convertAll(
        paths: [String],
        to target: TargetFormat,
        deleteOriginal: Bool = false,
        preserveDates: Bool = true
    ) -> (converted: [String], errors: [String]) {
        var converted: [String] = []
        var errors: [String] = []
        for path in pathsNeedingConversion(paths, target: target) {
            do {
                let output = try convert(
                    path: path,
                    to: target,
                    deleteOriginal: deleteOriginal,
                    preserveDates: preserveDates
                )
                converted.append(output)
            } catch {
                let name = (path as NSString).lastPathComponent
                errors.append("\(name): \(error.localizedDescription)")
            }
        }
        return (converted, errors)
    }
}
