import Foundation

/// Insert piexif-style EXIF segments into JPEG / PNG / WebP without re-encoding raster data (port of ``piexif.insert``).
enum ExifSegmentInserter {
    static func insert(exifSegment: Data, intoFileAt path: String) throws -> Data {
        guard exifSegment.count >= 6, exifSegment.prefix(6) == Data("Exif\0\0".utf8) else {
            throw ExifService.ExifError.writeFailed
        }
        let fileData = try Data(contentsOf: URL(fileURLWithPath: path))
        let onDisk = ExifService.detectedRasterExtension(path: path)
            ?? URL(fileURLWithPath: path).pathExtension.lowercased()
        switch onDisk {
        case "jpeg":
            return try insertIntoJPEG(exifSegment: exifSegment, jpeg: fileData)
        case "png":
            return try insertIntoPNG(exifSegment: exifSegment, png: fileData)
        case "webp":
            let tiff = ExifPiexifSegmentBuilder.tiffBytes(fromExifSegment: exifSegment)
            return try WebPImageWriter.dataWithReplacedExifChunk(webpData: fileData, exifTiff: tiff)
        default:
            throw ExifService.ExifError.unsupportedFormat
        }
    }

    static func insertIntoJPEG(exifSegment: Data, jpeg: Data) throws -> Data {
        guard jpeg.count >= 2, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else {
            throw ExifService.ExifError.readFailed
        }
        let segmentLength = exifSegment.count + 2
        guard segmentLength <= Int(UInt16.max) else { throw ExifService.ExifError.writeFailed }
        var app1 = Data([0xFF, 0xE1])
        var len = UInt16(segmentLength).bigEndian
        app1.append(Data(bytes: &len, count: 2))
        app1.append(exifSegment)
        return mergeJPEGSegments(splitJPEGSegments(jpeg), insertingAPP1: app1)
    }

    static func insertIntoPNG(exifSegment: Data, png: Data) throws -> Data {
        guard png.count >= 8, png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            throw ExifService.ExifError.readFailed
        }
        let tiff = ExifPiexifSegmentBuilder.tiffBytes(fromExifSegment: exifSegment)
        var chunks: [Data] = []
        var offset = 8
        var insertedBeforeIEND = false
        while offset + 12 <= png.count {
            let length = readUInt32BE(png, offset)
            let type = png[offset + 4..<offset + 8]
            let chunkEnd = offset + 12 + length
            guard chunkEnd <= png.count else { break }
            if type != Data("eXIf".utf8) {
                chunks.append(Data(png[offset..<chunkEnd]))
            }
            if type == Data("IEND".utf8) {
                var exifChunk = Data()
                exifChunk.appendBE(UInt32(tiff.count))
                exifChunk.append(Data("eXIf".utf8))
                exifChunk.append(tiff)
                exifChunk.append(pngCRC(type: Data("eXIf".utf8), data: tiff))
                chunks.append(exifChunk)
                chunks.append(Data(png[offset..<chunkEnd]))
                insertedBeforeIEND = true
                break
            }
            offset = chunkEnd
        }
        guard insertedBeforeIEND, !chunks.isEmpty else { throw ExifService.ExifError.writeFailed }
        var out = Data(png.prefix(8))
        for chunk in chunks { out.append(chunk) }
        return out
    }

    private static func splitJPEGSegments(_ jpeg: Data) -> [Data] {
        var segments: [Data] = []
        var index = 0
        while index < jpeg.count {
            guard jpeg[index] == 0xFF else { break }
            if index + 1 >= jpeg.count { break }
            let marker = jpeg[index + 1]
            if marker == 0xD9 { break }
            if marker == 0xDA {
                segments.append(jpeg[index...])
                break
            }
            guard index + 4 <= jpeg.count else { break }
            let length = Int(jpeg[index + 2]) << 8 | Int(jpeg[index + 3])
            guard length >= 2, index + 2 + length <= jpeg.count else { break }
            segments.append(jpeg[index..<(index + 2 + length)])
            index += 2 + length
        }
        return segments
    }

    private static func mergeJPEGSegments(_ segments: [Data], insertingAPP1 app1: Data) -> Data {
        guard let first = segments.first else { return Data() }
        var out = Data(first)
        var index = 1
        while index < segments.count {
            let seg = segments[index]
            if seg.count >= 10, seg[0] == 0xFF, seg[1] == 0xE1, seg[4..<10] == Data("Exif\0\0".utf8) {
                index += 1
                continue
            }
            if seg.count >= 2, seg[0] == 0xFF, seg[1] == 0xDA {
                out.append(app1)
                out.append(seg)
                return out
            }
            out.append(seg)
            index += 1
        }
        out.append(app1)
        return out
    }

    private static func readUInt32BE(_ data: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let value = (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
        return Int(value)
    }

    private static func pngCRC(type: Data, data: Data) -> Data {
        var crcInput = Data()
        crcInput.append(type)
        crcInput.append(data)
        let crc = crc32(crcInput)
        return Data([
            UInt8((crc >> 24) & 0xFF),
            UInt8((crc >> 16) & 0xFF),
            UInt8((crc >> 8) & 0xFF),
            UInt8(crc & 0xFF),
        ])
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt32) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 4))
    }
}
