import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fit edit sources to target canvas sizes (white borders, centered). Port of ``edit_aspect_pad.py``.
enum ImageGenEditAspectPad {
    static func removeEditAspectPadTemps(_ paths: [String]) {
        let fm = FileManager.default
        for path in paths where !path.isEmpty {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            try? fm.removeItem(atPath: path)
        }
    }

    static func generatorPathsWithScreenSizeExpansion(
        sourcePaths: [String],
        targetWidth: Int,
        targetHeight: Int,
        tempRoot: URL
    ) -> (generatorPaths: [String], tempPaths: [String]) {
        guard !sourcePaths.isEmpty else { return ([], []) }
        let originals = sourcePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let refW = max(1, targetWidth)
        let refH = max(1, targetHeight)
        guard let size = ImageRecognitionImageLoader.orientedPixelSize(path: originals[0]) else {
            return (originals, [])
        }
        if size.width == refW, size.height == refH {
            return (originals, [])
        }
        guard let fitted = saveFittedToReferenceSize(
            sourcePath: originals[0],
            refWidth: refW,
            refHeight: refH,
            allowUpscale: true,
            tempRoot: tempRoot
        ) else {
            return (originals, [])
        }
        return ([fitted] + Array(originals.dropFirst()), [fitted])
    }

    static func generatorPathsWithAspectPadding(
        sourcePaths: [String],
        tempRoot: URL
    ) -> (generatorPaths: [String], tempPaths: [String]) {
        guard !sourcePaths.isEmpty else { return ([], []) }
        let originals = sourcePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if originals.count == 1 {
            return (originals, [])
        }
        guard let refSize = ImageRecognitionImageLoader.orientedPixelSize(path: originals[0]) else {
            return (originals, [])
        }
        var out: [String] = [originals[0]]
        var temps: [String] = []
        for path in originals.dropFirst() {
            guard let size = ImageRecognitionImageLoader.orientedPixelSize(path: path) else {
                out.append(path)
                continue
            }
            if size.width == refSize.width, size.height == refSize.height {
                out.append(path)
                continue
            }
            guard let fitted = saveFittedToReferenceSize(
                sourcePath: path,
                refWidth: refSize.width,
                refHeight: refSize.height,
                allowUpscale: false,
                tempRoot: tempRoot
            ) else {
                out.append(path)
                continue
            }
            out.append(fitted)
            temps.append(fitted)
        }
        return (out, temps)
    }

    static func fitDimensions(
        width: Int,
        height: Int,
        refWidth: Int,
        refHeight: Int,
        allowUpscale: Bool
    ) -> (width: Int, height: Int) {
        let w = width
        let h = height
        let refW = refWidth
        let refH = refHeight
        if w <= 0 || h <= 0 {
            return (max(1, refW), max(1, refH))
        }
        var scale = min(Double(refW) / Double(w), Double(refH) / Double(h))
        if !allowUpscale {
            scale = min(scale, 1.0)
        }
        return (
            max(1, Int((Double(w) * scale).rounded())),
            max(1, Int((Double(h) * scale).rounded()))
        )
    }

    private static func saveFittedToReferenceSize(
        sourcePath: String,
        refWidth: Int,
        refHeight: Int,
        allowUpscale: Bool,
        tempRoot: URL
    ) -> String? {
        guard let image = ImageRecognitionImageLoader.loadCGImage(path: sourcePath) else { return nil }
        let w = image.width
        let h = image.height
        let (fitW, fitH) = fitDimensions(
            width: w,
            height: h,
            refWidth: refWidth,
            refHeight: refHeight,
            allowUpscale: allowUpscale
        )
        let fitted = (fitW != w || fitH != h) ? resize(image: image, width: fitW, height: fitH) : image
        guard let canvas = whiteCanvas(
            width: refWidth,
            height: refHeight,
            image: fitted,
            pasteWidth: fitW,
            pasteHeight: fitH
        ) else { return nil }
        let outPath = createEditAspectPadTempPath(tempRoot: tempRoot)
        guard writePNG(image: canvas, to: outPath) else {
            try? FileManager.default.removeItem(atPath: outPath)
            return nil
        }
        return outPath
    }

    private static func createEditAspectPadTempPath(tempRoot: URL) -> String {
        let dir = tempRoot.standardizedFileURL.path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("imagegen-edit-aspect-pad-\(UUID().uuidString).png")
    }

    private static func whiteCanvas(
        width: Int,
        height: Int,
        image: CGImage,
        pasteWidth: Int,
        pasteHeight: Int
    ) -> CGImage? {
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
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let pasteX = (width - pasteWidth) / 2
        let pasteY = (height - pasteHeight) / 2
        context.draw(
            image,
            in: CGRect(x: pasteX, y: pasteY, width: pasteWidth, height: pasteHeight)
        )
        return context.makeImage()
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

    private static func writePNG(image: CGImage, to path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
