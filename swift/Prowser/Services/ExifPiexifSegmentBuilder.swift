import Foundation

/// Minimal piexif-compatible ``Exif\\0\\0`` + TIFF for a single UserComment tag (port of empty IFD + Exif/UserComment dump).
enum ExifPiexifSegmentBuilder {
    static func build(userCommentPayload: Data) -> Data {
        let count = userCommentPayload.count
        precondition(count > 4, "UserComment payload must exceed 4 bytes")

        let exifIFDOffset: UInt32 = 26
        let commentOffset: UInt32 = 44

        var tiff = Data()
        tiff.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A])
        tiff.appendBE(UInt32(8))

        tiff.appendBE(UInt16(1))
        tiff.appendIFDEntry(tag: 0x8769, type: 4, count: 1, valueOrOffset: exifIFDOffset)
        tiff.appendBE(UInt32(0))

        tiff.appendBE(UInt16(1))
        tiff.appendIFDEntry(tag: 0x9286, type: 7, count: UInt32(count), valueOrOffset: commentOffset)
        tiff.appendBE(UInt32(0))

        tiff.append(userCommentPayload)

        var segment = Data("Exif\0\0".utf8)
        segment.append(tiff)
        return segment
    }

    static func tiffBytes(fromExifSegment segment: Data) -> Data {
        guard segment.count > 6, segment.prefix(6) == Data("Exif\0\0".utf8) else {
            return segment
        }
        return segment.dropFirst(6)
    }
}

private extension Data {
    mutating func appendBE(_ value: UInt16) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 2))
    }

    mutating func appendBE(_ value: UInt32) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 4))
    }

    mutating func appendIFDEntry(tag: UInt16, type: UInt16, count: UInt32, valueOrOffset: UInt32) {
        appendBE(tag)
        appendBE(type)
        appendBE(count)
        appendBE(valueOrOffset)
    }
}
