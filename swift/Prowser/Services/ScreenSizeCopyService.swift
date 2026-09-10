import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

        var errorDescription: String? {
            switch self {
            case .fileNotFound: return "Image file not found."
            case .loadFailed: return "Could not load image."
            case .saveFailed: return "Could not save screen-sized copy."
            }
        }
    }

    static func physicalScreenSize() -> CGSize {
        NSScreen.main?.frame.size ?? CGSize(width: 1920, height: 1080)
    }

    static func createCopy(
        path: String,
        fitMethod: FitMethod,
        bordersOnCopy: Bool,
        preserveDates: Bool
    ) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CopyError.fileNotFound
        }

        let screen = physicalScreenSize()
        let screenWidth = Int(screen.width.rounded())
        let screenHeight = Int(screen.height.rounded())

        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CopyError.loadFailed
        }

        let imgWidth = image.width
        let imgHeight = image.height
        guard imgWidth > 0, imgHeight > 0 else { throw CopyError.loadFailed }

        let scaleX = Double(screenWidth) / Double(imgWidth)
        let scaleY = Double(screenHeight) / Double(imgHeight)
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

        let newWidth = max(1, Int(Double(imgWidth) * scale))
        let newHeight = max(1, Int(Double(imgHeight) * scale))

        let outputPath = uniqueOutputPath(for: path)
        let outputURL = URL(fileURLWithPath: outputPath)
        let uti = UTType(filenameExtension: outputURL.pathExtension)?.identifier
            ?? UTType.jpeg.identifier

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            uti as CFString,
            1,
            nil
        ) else {
            throw CopyError.saveFailed
        }

        let resized = resize(image: image, width: newWidth, height: newHeight)
        let finalImage: CGImage
        if bordersOnCopy {
            finalImage = cropOrPadToScreen(
                image: resized,
                screenWidth: screenWidth,
                screenHeight: screenHeight
            )
        } else {
            finalImage = resized
        }

        var properties: [CFString: Any] = [:]
        if uti == UTType.jpeg.identifier {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        }
        CGImageDestinationAddImage(destination, finalImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
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

    private static func resize(image: CGImage, width: Int, height: Int) -> CGImage {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func cropOrPadToScreen(
        image: CGImage,
        screenWidth: Int,
        screenHeight: Int
    ) -> CGImage {
        let width = image.width
        let height = image.height
        if width == screenWidth, height == screenHeight { return image }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: screenWidth,
            height: screenHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.setFillColor(CGColor.black)
        context.fill(CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight))

        if width > screenWidth || height > screenHeight {
            let cropX = (width - screenWidth) / 2
            let cropY = (height - screenHeight) / 2
            if let cropped = image.cropping(to: CGRect(
                x: cropX, y: cropY, width: screenWidth, height: screenHeight
            )) {
                context.draw(cropped, in: CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight))
            }
        } else {
            let pasteX = (screenWidth - width) / 2
            let pasteY = (screenHeight - height) / 2
            context.draw(
                image,
                in: CGRect(x: pasteX, y: pasteY, width: width, height: height)
            )
        }

        return context.makeImage() ?? image
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
