import Foundation

/// Read EXIF UserComment from embedded TIFF (PNG ``eXIf``, JPEG APP1, WebP EXIF chunk) when ImageIO returns nothing.
enum ExifEmbeddedTIFFReader {
    static func userComment(fromFile path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return userComment(fromImageData: data)
    }

    /// Read UserComment from JPEG/PNG bytes (embedded ``eXIf`` / APP1); skips ImageIO.
    static func userComment(fromImageData data: Data) -> String? {
        guard let tiff = tiffFromPNG(data) ?? tiffFromJPEG(data) else {
            return nil
        }
        return userComment(fromTIFF: tiff)
    }

    static func userComment(fromEmbeddedTIFF tiff: Data) -> String? {
        userComment(fromTIFF: tiff)
    }

    private static func tiffFromPNG(_ data: Data) -> Data? {
        guard data.count >= 8, data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            return nil
        }
        var offset = 8
        while offset + 12 <= data.count {
            let length = readUInt32BE(data, offset)
            let type = data[offset + 4..<offset + 8]
            let chunkEnd = offset + 12 + length
            guard chunkEnd <= data.count else { break }
            if type == Data("eXIf".utf8) {
                return Data(data[offset + 8..<chunkEnd])
            }
            offset = chunkEnd
        }
        return nil
    }

    private static func tiffFromJPEG(_ data: Data) -> Data? {
        guard data.count >= 2, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        var index = 2
        while index + 4 <= data.count {
            guard data[index] == 0xFF else { break }
            let marker = data[index + 1]
            if marker == 0xD9 { break }
            let length = Int(data[index + 2]) << 8 | Int(data[index + 3])
            guard length >= 2, index + 2 + length <= data.count else { break }
            if marker == 0xE1, length >= 8 {
                let payloadStart = index + 4
                let header = data[payloadStart..<payloadStart + 6]
                if header == Data("Exif\0\0".utf8) {
                    return Data(data[(payloadStart + 6)..<(index + 2 + length)])
                }
            }
            index += 2 + length
        }
        return nil
    }

    private static func userComment(fromTIFF tiff: Data) -> String? {
        userCommentParse(fromTIFF: tiff)
    }

    private static func userCommentParse(fromTIFF tiff: Data) -> String? {
        guard tiff.count >= 8 else { return nil }
        if let quick = quickUserCommentFromMinimalPiexifTIFF(tiff) {
            return quick
        }
        return genericUserComment(fromTIFF: tiff)
    }

    private static func genericUserComment(fromTIFF tiff: Data) -> String? {
        let littleEndian = tiff.prefix(2) == Data([0x49, 0x49])
        guard let ifd0Offset = readUInt32(tiff, 4, littleEndian: littleEndian) else { return nil }
        guard Int(ifd0Offset) >= 0, Int(ifd0Offset) + 2 <= tiff.count else { return nil }
        guard let exifIFDOffset = pointerTag(in: tiff, ifdOffset: Int(ifd0Offset), tag: 0x8769, littleEndian: littleEndian)
        else { return nil }
        guard exifIFDOffset >= 0, exifIFDOffset + 2 <= tiff.count else { return nil }
        guard let payload = undefinedTag(in: tiff, ifdOffset: exifIFDOffset, tag: 0x9286, littleEndian: littleEndian)
        else { return nil }
        guard !payload.isEmpty else { return nil }
        return decodeUserCommentPayload(payload)
    }

    /// Fast path for ``ExifPiexifSegmentBuilder`` / piexif-style big-endian TIFF with a single UserComment tag.
    private static func quickUserCommentFromMinimalPiexifTIFF(_ tiff: Data) -> String? {
        guard tiff.prefix(2) == Data([0x4D, 0x4D]), tiff.count >= 48 else { return nil }
        guard readUInt16BE(tiff, 26) == 1 else { return nil }
        guard readUInt16BE(tiff, 28) == 0x9286 else { return nil }
        guard readUInt16BE(tiff, 30) == 7 else { return nil }
        let count = readInt32BE(tiff, 32)
        guard count > 0, count <= tiff.count else { return nil }
        let valueOffset = readInt32BE(tiff, 36)
        guard valueOffset >= 0, valueOffset + count <= tiff.count else { return nil }
        return decodeUserCommentPayload(tiff[valueOffset ..< (valueOffset + count)])
    }

    private static func decodeUserCommentPayload(_ payload: Data) -> String? {
        let decoded = ExifService.decodeUserComment(payload)
        let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func readUInt16BE(_ data: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let value = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        return Int(value)
    }

    private static func readInt32BE(_ data: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let value = (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
        return Int(value)
    }

    private static func pointerTag(in tiff: Data, ifdOffset: Int, tag: UInt16, littleEndian: Bool) -> Int? {
        guard let raw = ifdEntryValue(in: tiff, ifdOffset: ifdOffset, tag: tag, littleEndian: littleEndian) else {
            return nil
        }
        return Int(raw)
    }

    private static func undefinedTag(
        in tiff: Data,
        ifdOffset: Int,
        tag: UInt16,
        littleEndian: Bool
    ) -> Data? {
        guard let entry = ifdEntry(in: tiff, ifdOffset: ifdOffset, tag: tag, littleEndian: littleEndian) else {
            return nil
        }
        if entry.count <= 4 {
            return entry.inlineData
        }
        let start = Int(entry.valueOffset)
        let end = start + entry.count
        guard start >= 0, end <= tiff.count else { return nil }
        return tiff[start..<end]
    }

    private struct IFDEntry {
        var count: Int
        var valueOffset: UInt32
        var inlineData: Data
    }

    private static func ifdEntryValue(in tiff: Data, ifdOffset: Int, tag: UInt16, littleEndian: Bool) -> UInt32? {
        guard let entry = ifdEntry(in: tiff, ifdOffset: ifdOffset, tag: tag, littleEndian: littleEndian) else {
            return nil
        }
        if entry.count <= 4 {
            var bytes = entry.inlineData
            while bytes.count < 4 { bytes.append(0) }
            return readUInt32(bytes, 0, littleEndian: littleEndian)
        }
        return entry.valueOffset
    }

    private static func ifdEntry(
        in tiff: Data,
        ifdOffset: Int,
        tag: UInt16,
        littleEndian: Bool
    ) -> IFDEntry? {
        guard ifdOffset >= 0, ifdOffset + 2 <= tiff.count else { return nil }
        let entryCountRaw = readUInt16(tiff, ifdOffset, littleEndian: littleEndian) ?? 0
        guard entryCountRaw <= 256 else { return nil }
        let entryCount = Int(entryCountRaw)
        var index = ifdOffset + 2
        for _ in 0..<entryCount {
            guard index + 12 <= tiff.count else { return nil }
            guard let entryTag = readUInt16(tiff, index, littleEndian: littleEndian) else {
                return nil
            }
            let count = Int(readUInt32(tiff, index + 4, littleEndian: littleEndian) ?? 0)
            let valueOffset = readUInt32(tiff, index + 8, littleEndian: littleEndian) ?? 0
            if entryTag == tag {
                let inline = tiff[(index + 8)..<(index + 12)]
                return IFDEntry(count: count, valueOffset: valueOffset, inlineData: inline)
            }
            index += 12
        }
        return nil
    }

    private static func readUInt16(_ data: Data, _ offset: Int, littleEndian: Bool) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1])
        return littleEndian ? (b1 << 8 | b0) : (b0 << 8 | b1)
    }

    private static func readUInt32(_ data: Data, _ offset: Int, littleEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        if littleEndian {
            return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
        }
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func readUInt32BE(_ data: Data, _ offset: Int) -> Int {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let value = (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
        return Int(value)
    }
}
