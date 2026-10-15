import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// JPEG/PNG/WebP conversion (ImageIO + libwebp for WebP encode). Port of `files/convert_format.py` (minimal).
@MainActor
enum ConvertFormatService {
    enum TargetFormat: String, CaseIterable, Identifiable {
        case png
        case webp
        case jpeg

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .jpeg: return "JPEG"
            case .png: return "PNG"
            case .webp: return "WebP"
            }
        }

        var fileExtension: String {
            switch self {
            case .jpeg: return "jpg"
            case .png: return "png"
            case .webp: return "webp"
            }
        }

        var utType: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .png: return .png
            case .webp: return UTType.webP
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
        preserveDates: Bool = false,
        ignoreExifRotation: Bool = false
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
        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".convert_\(UUID().uuidString)")
            .appendingPathExtension(target.fileExtension)

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              var image = ImageReencodeMetadata.orientedImage(from: source, ignoreExifRotation: ignoreExifRotation) else {
            throw ConvertError.loadFailed
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let saveFormat = ImageReencodeMetadata.saveFormatName(for: target.fileExtension) ?? "JPEG"
        let metadata = ImageReencodeMetadata.propertiesForSave(
            from: source,
            renderedImage: image,
            ignoreExifRotation: ignoreExifRotation
        )

        if target == .jpeg {
            image = ImageReencodeMetadata.imageForJPEGSave(image)
        }

        defer { try? FileManager.default.removeItem(at: tempURL) }

        if target == .webp {
            let lossless = ImageReencodeMetadata.imageHasAlpha(image)
            let exifTiff = ImageReencodeMetadata.exifTiffForWebP(from: metadata)
            do {
                try WebPImageWriter.write(
                    image: image,
                    to: tempURL,
                    sourcePathForMetadata: path,
                    metadataExifTiff: exifTiff,
                    lossless: lossless
                )
            } catch {
                throw ConvertError.saveFailed(outputPath)
            }
        } else {
            guard let destination = CGImageDestinationCreateWithURL(
                tempURL as CFURL,
                target.utType.identifier as CFString,
                1,
                nil
            ) else {
                throw ConvertError.saveFailed(outputPath)
            }

            let properties = ImageReencodeMetadata.destinationEncodeProperties(
                saveFormat: saveFormat,
                base: metadata
            )
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ConvertError.saveFailed(outputPath)
            }
        }

        guard outputFileIsValid(at: tempURL.path) else {
            throw ConvertError.saveFailed(outputPath)
        }

        do {
            if FileManager.default.fileExists(atPath: outputPath) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: outputURL)
            }
        } catch {
            throw ConvertError.saveFailed(outputPath)
        }

        guard outputFileIsValid(at: outputPath) else {
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
            deleteSourceAfterSuccessfulConvert(sourcePath: path, outputPath: outputPath)
        }

        return outputPath
    }

    static func convertAll(
        paths: [String],
        to target: TargetFormat,
        deleteOriginal: Bool = false,
        preserveDates: Bool = false,
        ignoreExifRotation: Bool = false
    ) -> (converted: [String], errors: [String]) {
        var converted: [String] = []
        var errors: [String] = []
        for path in pathsNeedingConversion(paths, target: target) {
            do {
                let output = try convert(
                    path: path,
                    to: target,
                    deleteOriginal: deleteOriginal,
                    preserveDates: preserveDates,
                    ignoreExifRotation: ignoreExifRotation
                )
                converted.append(output)
            } catch {
                let name = (path as NSString).lastPathComponent
                errors.append("\(name): \(error.localizedDescription)")
            }
        }
        return (converted, errors)
    }

    /// Python: only delete after verified output exists; never delete on failed save.
    private static func deleteSourceAfterSuccessfulConvert(sourcePath: String, outputPath: String) {
        guard !FileDataModel.pathsReferToSameFile(sourcePath, outputPath) else { return }
        if RenamePrefixPlanner.isInsidePhotosLibrary(sourcePath) { return }
        guard outputFileIsValid(at: outputPath) else { return }
        guard FileManager.default.fileExists(atPath: sourcePath) else { return }
        try? FileManager.default.removeItem(atPath: sourcePath)
    }

    private static func outputFileIsValid(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

}
