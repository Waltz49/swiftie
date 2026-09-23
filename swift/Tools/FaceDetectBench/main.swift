import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import ProwserDlibBridge

let imagePath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/Users/douglasnadel/Desktop/image000000.jpg"
let modelDir = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "/tmp/nerb/cache/swift_native/image_recognition/dlib_models"

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil) else {
    exit(1)
}
let thumbOptions: [CFString: Any] = [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceShouldCacheImmediately: true,
    kCGImageSourceThumbnailMaxPixelSize: 10_000,
]
guard let fullCG = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
    exit(1)
}
func downscale(_ cg: CGImage, maxLongEdge: Int) -> CGImage {
    let w = cg.width, h = cg.height
    let longest = max(w, h)
    guard longest > maxLongEdge else { return cg }
    let scale = Double(maxLongEdge) / Double(longest)
    let nw = Int(Double(w) * scale), nh = Int(Double(h) * scale)
    guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
        space: cg.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cg }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
    return ctx.makeImage() ?? cg
}
let cg = downscale(fullCG, maxLongEdge: 2000)
print("full \(fullCG.width)x\(fullCG.height) detect \(cg.width)x\(cg.height)")

func rgbData(from cg: CGImage) -> Data? {
    let width = cg.width, height = cg.height, bytesPerRow = width * 4
    var rgba = Data(count: height * bytesPerRow)
    guard rgba.withUnsafeMutableBytes({ ptr in
        guard let base = ptr.baseAddress,
              let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: cg.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }) else { return nil }
    var rgb = Data(count: width * height * 3)
    rgba.withUnsafeBytes { src in
        rgb.withUnsafeMutableBytes { dst in
            guard let s = src.baseAddress, let d = dst.baseAddress else { return }
            var srcBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: s), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
            var dstBuf = vImage_Buffer(data: d, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 3)
            vImageConvert_RGBA8888toRGB888(&srcBuf, &dstBuf, vImage_Flags(kvImageNoFlags))
        }
    }
    return rgb
}

let t0 = CFAbsoluteTimeGetCurrent()
guard let rgb = rgbData(from: cg) else { exit(1) }
let t1 = CFAbsoluteTimeGetCurrent()
print(String(format: "rgb %.3fs", t1 - t0))

let shape68 = modelDir + "/shape_predictor_68_face_landmarks.dat"
let shape5 = modelDir + "/shape_predictor_5_face_landmarks.dat"
let shape = FileManager.default.fileExists(atPath: shape68) ? shape68 : shape5
let resnet = modelDir + "/dlib_face_recognition_resnet_model_v1.dat"
guard ProwserDlibBridge.loadModels(shapePredictorPath: shape, faceRecognitionResNetPath: resnet) else { exit(1) }

let t2 = CFAbsoluteTimeGetCurrent()
guard let dets = ProwserDlibBridge.encodeFacesRGB(width: cg.width, height: cg.height, rgb: rgb) else { exit(1) }
let t3 = CFAbsoluteTimeGetCurrent()
print(String(format: "dlib %.3fs hog=\(ProwserDlibBridge.lastHogFaceCount) encoded=\(dets.count)", t3 - t2))
for (i, d) in dets.enumerated() {
    print("  \(i) top=\(d.rect.top) right=\(d.rect.right) bottom=\(d.rect.bottom) left=\(d.rect.left)")
}
