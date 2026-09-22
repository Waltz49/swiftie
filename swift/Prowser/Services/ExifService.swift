import Foundation
import ImageIO
/// EXIF read/write via ImageIO. Port of `exif/exif_utils.py` (phase 1).
enum ExifService {
    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()


    static let supportedWriteExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tiff", "tif", "webp",
    ]

    private static let exifDateTimeKey = "DateTime" as CFString

    static func canWriteExif(path: String) -> Bool {
        supportedWriteExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    // MARK: - Read

    static func loadRecord(for path: String) -> ExifRecord {
        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent
        let directory = url.deletingLastPathComponent().path
        var record = ExifRecord.empty
        record.filePath = path
        record.fileName = fileName
        record.directory = directory

        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            if let size = attrs[.size] as? NSNumber {
                record.fileSize = InformationFormatting.formatFileSize(size.intValue)
            }
            if let mtime = attrs[.modificationDate] as? Date {
                record.fileDate = InformationFormatting.formatFileDate(mtime)
            }
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return record }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return record
        }

        if let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int {
            record.imageSize = InformationFormatting.formatImageSize(width: width, height: height)
        }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        let dateCandidates = [
            exif[kCGImagePropertyExifDateTimeOriginal] as? String,
            exif[kCGImagePropertyExifDateTimeDigitized] as? String,
            exif[exifDateTimeKey] as? String,
            tiff[kCGImagePropertyTIFFDateTime] as? String,
        ]
        for candidate in dateCandidates {
            if let candidate, let formatted = InformationFormatting.formatExifDateString(candidate) {
                record.exifDate = formatted
                break
            }
        }

        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        let camera = [make, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        if !camera.isEmpty { record.camera = camera }

        if let orientation = exif[kCGImagePropertyOrientation] as? Int {
            record.orientation = orientationLabel(orientation)
        }

        let lensModel = exif[kCGImagePropertyExifLensModel] as? String
        if let lensModel, !lensModel.isEmpty { record.lens = lensModel }

        record.description = userDescription(exif: exif, tiff: tiff)

        if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double {
            record.exposure = formatExposureTime(exposure)
        } else if let exposure = exif[kCGImagePropertyExifExposureTime] as? NSNumber {
            record.exposure = formatExposureTime(exposure.doubleValue)
        }

        if let fNumber = exif[kCGImagePropertyExifFNumber] as? Double {
            record.aperture = InformationFormatting.formatAperture(fNumber)
        } else if let fNumber = exif[kCGImagePropertyExifFNumber] as? NSNumber {
            record.aperture = InformationFormatting.formatAperture(fNumber.doubleValue)
        }

        if let iso = exif[kCGImagePropertyExifISOSpeedRatings] as? Int {
            record.iso = "\(iso)"
        } else if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = isoArray.first {
            record.iso = "\(first)"
        }

        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            record.focalLength = InformationFormatting.formatFocalLength(focal)
        } else if let focal = exif[kCGImagePropertyExifFocalLength] as? NSNumber {
            record.focalLength = InformationFormatting.formatFocalLength(focal.doubleValue)
        }

        record.software = tiff[kCGImagePropertyTIFFSoftware] as? String
        record.artist = tiff[kCGImagePropertyTIFFArtist] as? String

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let coords = parseGPS(gps) {
            record.location = InformationFormatting.formatGPS(
                latitude: coords.latitude,
                longitude: coords.longitude
            )
        }

        record.extraFields = extraExifFields(exif: exif)

        return record
    }

    /// Port of Python `ExposureTime` display (`information_sidebar.py`); avoids divide-by-zero on bad EXIF.
    private static func formatExposureTime(_ exposure: Double) -> String? {
        guard exposure.isFinite, exposure > 0 else { return nil }
        if exposure < 1 {
            let reciprocal = 1 / exposure
            guard reciprocal.isFinite else { return nil }
            let denominator = Int(round(reciprocal))
            guard denominator > 0 else { return nil }
            return "1/\(denominator)s"
        }
        return "\(exposure)s"
    }

    static func userComment(path: String) -> String? {
        let record = loadRecord(for: path)
        return record.description
    }

    /// Lightweight read of description / user-comment fields only (list view comments column).
    static func readUserDescription(path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        return userDescription(exif: exif, tiff: tiff)
    }

    /// Port of Prowser generation EXIF layout (`format_image_exif_prompt` / mflux JSON).
    static func isProwserFormattedUserComment(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if parseMfluxMetadataJSON(trimmed) != nil { return true }
        guard hasPromptSection(trimmed), hasImageModelSection(trimmed) else { return false }
        return true
    }

    private static func hasImageModelSection(_ text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
            if lower == "image model" || lower == "image model:" {
                return true
            }
        }
        return false
    }

    private static func hasPromptSection(_ text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let lower = line.trimmingCharacters(in: .whitespaces).lowercased()
            if lower == "prompt" || lower == "prompt:" {
                return true
            }
        }
        return false
    }

    private static func parseMfluxMetadataJSON(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if json["mflux_version"] != nil { return json }
        if json["prompt"] != nil,
           json.keys.contains(where: { ["seed", "steps", "model", "quantize"].contains($0) }) {
            return json
        }
        return nil
    }

    /// Python/piexif-backed user description (matches information sidebar in Qt app).
    @MainActor
    static func userDescription(path: String) async -> String? {
        loadRecord(for: path).description
    }

    @MainActor
    static func loadRecord(for path: String, preferPythonDescription: Bool) async -> ExifRecord {
        loadRecord(for: path)
    }

    private static let userCommentSkipHeadings: Set<String> = [
        "prompt", "prompt:", "description", "description:",
    ]

    /// Port of `imagegen_plugins/image_gen_menu.py` `initial_prompt_from_usercomment`.
    static func initialPromptFromUserComment(_ text: String) -> String? {
        let prompt = truncateUserCommentBeforePrompt(text).trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    /// Prompt text for image-gen import / ⇧⌥/ priming (display-normalized comment → prompt section only).
    @MainActor
    static func importPromptFromPath(_ path: String) async -> String? {
        guard let comment = await userDescription(path: path) else { return nil }
        return initialPromptFromUserComment(comment)
    }

    /// Sync fallback when the Python EXIF bridge is unavailable (`load_import_prompt_from_path`).
    static func importPromptFromPathSync(_ path: String) -> String? {
        importPromptText(from: path)
    }

    /// Port of `exif/exif_utils.py` `usercomment_text_for_clipboard`.
    static func userCommentTextForClipboard(_ text: String, copyFull: Bool = false) -> String {
        guard !text.isEmpty else { return text }
        if copyFull { return text }
        return truncateUserCommentBeforePrompt(text).replacingOccurrences(of: ";", with: ".")
    }

    /// Port of `exif/exif_utils.py` `truncate_usercomment_before_prompt`.
    static func truncateUserCommentBeforePrompt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            if userCommentSkipHeadings.contains(line.trimmingCharacters(in: .whitespaces).lowercased()) {
                return lines.dropFirst(index + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    static func importPromptText(from path: String) -> String? {
        guard let comment = userComment(path: path)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !comment.isEmpty else {
            return nil
        }
        let prompt = truncateUserCommentBeforePrompt(comment)
        return prompt.isEmpty ? nil : prompt
    }

    static func exifTimestamp(path: String) -> Date? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let candidates = [
            exif[kCGImagePropertyExifDateTimeOriginal] as? String,
            exif[kCGImagePropertyExifDateTimeDigitized] as? String,
            exif[exifDateTimeKey] as? String,
            tiff[kCGImagePropertyTIFFDateTime] as? String,
        ]
        for candidate in candidates {
            if let candidate, let date = exifDateFormatter.date(from: candidate) {
                return date
            }
        }
        return nil
    }

    // MARK: - Write

    @MainActor
    static func writeUserComment(path: String, text: String) async throws {
        try writeUserCommentImageIO(path: path, text: text)
    }

    @MainActor
    static func deleteUserComment(path: String) async throws {
        try deleteUserCommentImageIO(path: path)
    }

    private static func writeUserCommentImageIO(path: String, text: String) throws {
        guard canWriteExif(path: path) else {
            throw ExifError.unsupportedFormat
        }
        let url = URL(fileURLWithPath: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let mtime = attrs[.modificationDate] as? Date
        let atime = attrs[.creationDate] as? Date

        if url.pathExtension.lowercased() == "webp" {
            try writeUserCommentWebP(url: url, text: text, mtime: mtime, atime: atime)
            return
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let uti = CGImageSourceGetType(source),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ExifError.readFailed
        }

        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        applyUserComment(text, to: &properties)

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".prowser-exif-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, uti, 1, nil) else {
            throw ExifError.writeFailed
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ExifError.writeFailed
        }
        try replaceWrittenFile(at: url, with: tempURL, mtime: mtime, atime: atime)
    }

    private static func writeUserCommentWebP(
        url: URL,
        text: String,
        mtime: Date?,
        atime: Date?
    ) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ExifError.readFailed
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        applyUserComment(text, to: &properties)
        let exifTiff = try exifTiffBytes(fromImageProperties: properties)
        let fileData = try Data(contentsOf: url)
        let output = try WebPImageWriter.dataWithReplacedExifChunk(webpData: fileData, exifTiff: exifTiff)
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".prowser-exif-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        try output.write(to: tempURL, options: .atomic)
        try replaceWrittenFile(at: url, with: tempURL, mtime: mtime, atime: atime)
    }

    /// ImageIO writes `kCGImagePropertyExifUserComment` as a `String`; `Data` is dropped on finalize.
    private static func applyUserComment(_ text: String, to properties: inout [CFString: Any]) {
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if text.isEmpty {
            exif.removeValue(forKey: kCGImagePropertyExifUserComment)
        } else {
            exif[kCGImagePropertyExifUserComment] = text
        }
        if exif.isEmpty {
            properties.removeValue(forKey: kCGImagePropertyExifDictionary)
        } else {
            properties[kCGImagePropertyExifDictionary] = exif
        }
    }

    private static func replaceWrittenFile(at url: URL, with tempURL: URL, mtime: Date?, atime: Date?) throws {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        let path = url.path
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
        }
        if let atime {
            try FileManager.default.setAttributes([.creationDate: atime], ofItemAtPath: path)
        }
    }

    /// Build a TIFF EXIF blob (for WebP EXIF chunk) from ImageIO property dictionaries.
    private static func exifTiffBytes(fromImageProperties properties: [CFString: Any]) throws -> Data {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prowser-exif-stub-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let image = context.makeImage() else {
            throw ExifError.writeFailed
        }
        guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw ExifError.writeFailed
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExifError.writeFailed
        }
        let jpegData = try Data(contentsOf: tempURL)
        guard let tiff = extractExifTiffFromJPEG(jpegData) else {
            throw ExifError.writeFailed
        }
        return tiff
    }

    private static func extractExifTiffFromJPEG(_ jpegData: Data) -> Data? {
        let bytes = [UInt8](jpegData)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var index = 2
        while index + 4 < bytes.count {
            guard bytes[index] == 0xFF else { break }
            let marker = bytes[index + 1]
            if marker == 0xD9 { break }
            let segmentLength = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            if marker == 0xE1, segmentLength > 8 {
                let payloadStart = index + 4
                let payloadEnd = payloadStart + segmentLength - 2
                guard payloadEnd <= bytes.count else { break }
                let segment = Data(bytes[payloadStart..<payloadEnd])
                let exifHeader = Data("Exif\0\0".utf8)
                if segment.count > exifHeader.count, segment.prefix(exifHeader.count) == exifHeader {
                    return segment.subdata(in: exifHeader.count..<segment.count)
                }
            }
            index += 2 + segmentLength
        }
        return nil
    }

    private static func deleteUserCommentImageIO(path: String) throws {
        try writeUserCommentImageIO(path: path, text: "")
    }

    static func resetFileDateToExif(path: String) throws {
        guard let date = exifTimestamp(path: path) else { throw ExifError.noExifDate }
        try FileManager.default.setAttributes(
            [.modificationDate: date, .creationDate: date],
            ofItemAtPath: path
        )
    }

    static func deleteExifDate(path: String) throws {
        guard canWriteExif(path: path) else { throw ExifError.unsupportedFormat }
        guard exifTimestamp(path: path) != nil else { throw ExifError.noExifDate }

        let url = URL(fileURLWithPath: path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let mtime = attrs[.modificationDate] as? Date

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let uti = CGImageSourceGetType(source),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ExifError.readFailed
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifDateTimeOriginal)
            exif.removeValue(forKey: kCGImagePropertyExifDateTimeDigitized)
            exif.removeValue(forKey: exifDateTimeKey)
            properties[kCGImagePropertyExifDictionary] = exif.isEmpty ? nil : exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFDateTime)
            properties[kCGImagePropertyTIFFDictionary] = tiff.isEmpty ? nil : tiff
        }

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".prowser-exif-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, uti, 1, nil) else {
            throw ExifError.writeFailed
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExifError.writeFailed }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
        }
    }

    static func resetExifDateToFileDate(path: String) throws {
        guard canWriteExif(path: path) else { throw ExifError.unsupportedFormat }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        guard let mtime = attrs[.modificationDate] as? Date else { throw ExifError.noFileDate }
        let formatted = exifDateFormatter.string(from: mtime)

        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let uti = CGImageSourceGetType(source),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ExifError.readFailed
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifDateTimeOriginal] = formatted
        exif[kCGImagePropertyExifDateTimeDigitized] = formatted
        exif[exifDateTimeKey] = formatted
        tiff[kCGImagePropertyTIFFDateTime] = formatted
        properties[kCGImagePropertyExifDictionary] = exif
        properties[kCGImagePropertyTIFFDictionary] = tiff

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".prowser-exif-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
        guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, uti, 1, nil) else {
            throw ExifError.writeFailed
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExifError.writeFailed }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: path)
    }

    // MARK: - Helpers

    /// Port of `exif/exif_utils.py` `decode_usercomment`.
    static func decodeUserComment(_ data: Data) -> String {
        if data.isEmpty { return "" }

        let textBytes: Data
        if data.count >= 8 {
            let prefix = data.prefix(8)
            if prefix == Data("ASCII\0\0\0".utf8) {
                let payload = data.dropFirst(8)
                if let ascii = String(data: payload, encoding: .ascii) {
                    return trimNulls(ascii)
                }
                if let utf8 = String(data: payload, encoding: .utf8) {
                    return trimNulls(utf8)
                }
                return trimNulls(String(data: payload, encoding: .isoLatin1) ?? "")
            }
            if prefix == Data("UNICODE\0".utf8) {
                if let decoded = String(data: data.dropFirst(8), encoding: .utf16LittleEndian) {
                    return trimNulls(decoded)
                }
                return ""
            }
            if prefix == Data("JIS\0\0\0\0\0".utf8) {
                if let decoded = String(data: data.dropFirst(8), encoding: .iso2022JP) {
                    return trimNulls(decoded)
                }
            }
            if prefix == Data([0, 0, 0, 0, 0, 0, 0, 0]) {
                textBytes = data.dropFirst(8)
            } else {
                textBytes = data
            }
        } else {
            textBytes = data
        }

        if let utf8 = String(data: textBytes, encoding: .utf8) {
            return trimNulls(utf8)
        }
        return trimNulls(String(data: textBytes, encoding: .isoLatin1) ?? "")
    }

    /// ImageIO returns UNICODE UserComment as UTF-16BE code units (e.g. U+4900 for 'I').
    static func repairImageIOMisdecodedUTF16UserComment(_ text: String) -> String {
        var bytes = Data()
        bytes.reserveCapacity(text.unicodeScalars.count * 2)
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value <= 0xFF {
                bytes.append(UInt8(value))
                bytes.append(0)
            } else {
                bytes.append(UInt8((value >> 8) & 0xFF))
                bytes.append(UInt8(value & 0xFF))
            }
        }
        if let repaired = String(data: bytes, encoding: .utf16LittleEndian) {
            return trimNulls(repaired)
        }
        return text
    }

    static func looksLikeImageIOMisdecodedUTF16UserComment(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.map(\.value)
        guard scalars.count >= 4 else { return false }
        let misdecodedASCII = scalars.filter { value in
            value >= 0x100 && (value & 0xFF) == 0 && (value >> 8) < 0x80
        }
        return misdecodedASCII.count >= max(4, scalars.count * 2 / 3)
    }

    static func decodeUserCommentValue(_ raw: Any) -> String? {
        if let data = raw as? Data {
            let decoded = trimNulls(decodeUserComment(data))
            return decoded.isEmpty ? nil : decoded
        }
        if let string = raw as? String {
            var decoded = trimNulls(string)
            if decoded.isEmpty { return nil }
            if looksLikeImageIOMisdecodedUTF16UserComment(decoded) {
                decoded = repairImageIOMisdecodedUTF16UserComment(decoded)
            }
            decoded = trimNulls(decoded)
            if decoded.hasPrefix("b'") || decoded.hasPrefix("b\"") { return nil }
            return decoded.isEmpty ? nil : decoded
        }
        return nil
    }

    static func decodeDescriptionValue(_ raw: Any) -> String? {
        if let data = raw as? Data {
            let decoded = trimNulls(String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "")
            return decoded.isEmpty ? nil : decoded
        }
        if let string = raw as? String {
            let decoded = trimNulls(string)
            if decoded.isEmpty || decoded.hasPrefix("b'") || decoded.hasPrefix("b\"") { return nil }
            return decoded
        }
        return nil
    }

    private static func trimNulls(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    /// Piexif-style UserComment bytes (read/decode paths). ImageIO writes need a plain `String` instead.
    static func encodeUserCommentData(_ text: String) -> Data {
        if text.canBeConverted(to: .ascii) {
            return Data("ASCII\0\0\0".utf8) + text.data(using: .ascii)!
        }
        return Data("UNICODE\0".utf8) + text.data(using: .utf16LittleEndian)!
    }

    private static func userDescription(exif: [CFString: Any], tiff: [CFString: Any]) -> String? {
        // Match Python `get_user_description_from_exif_dict` / information sidebar order.
        if let raw = tiff[kCGImagePropertyTIFFImageDescription],
           let desc = decodeDescriptionValue(raw) {
            return desc
        }
        if let raw = exif[kCGImagePropertyExifUserComment],
           let desc = decodeUserCommentValue(raw) {
            return desc
        }
        let xpCommentKey = "{XPComment}" as CFString
        let xpSubjectKey = "{XPSubject}" as CFString
        if let raw = exif[xpCommentKey], let desc = decodeDescriptionValue(raw) {
            return desc
        }
        if let raw = exif[xpSubjectKey], let desc = decodeDescriptionValue(raw) {
            return desc
        }
        return nil
    }

    private static func orientationLabel(_ value: Int) -> String {
        switch value {
        case 1: return "Normal"
        case 2: return "Mirrored"
        case 3: return "Rotated 180°"
        case 4: return "Rotated 180°, Mirrored"
        case 5: return "Rotated 90° CCW, Mirrored"
        case 6: return "Rotated 90° CW"
        case 7: return "Rotated 90° CW, Mirrored"
        case 8: return "Rotated 90° CCW"
        default: return "\(value)"
        }
    }

    static func gpsCoordinates(for path: String) -> (latitude: Double, longitude: Double)? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] else {
            return nil
        }
        return parseGPS(gps)
    }

    private static func parseGPS(_ gps: [CFString: Any]) -> (latitude: Double, longitude: Double)? {
        guard let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
        var latitude = lat
        var longitude = lon
        if latRef == "S" { latitude = -latitude }
        if lonRef == "W" { longitude = -longitude }
        return (latitude, longitude)
    }

    private static func extraExifFields(exif: [CFString: Any]) -> [(String, String)] {
        let skipNames: Set<String> = [
            "Camera", "Orientation", "Lens", "Location", "Description",
            "EXIF Date", "Exposure", "Aperture", "ISO", "Focal Length", "Software", "Artist",
        ]
        var fields: [String: String] = [:]

        if let flash = exif[kCGImagePropertyExifFlash] as? Int {
            fields["Flash"] = flashLabel(flash)
        } else if let flash = exif[kCGImagePropertyExifFlash] as? NSNumber {
            fields["Flash"] = flashLabel(flash.intValue)
        }

        if let whiteBalance = exif[kCGImagePropertyExifWhiteBalance] as? Int {
            fields["White Balance"] = whiteBalance == 0 ? "Auto" : "Manual"
        }

        if let metering = exif[kCGImagePropertyExifMeteringMode] as? Int {
            fields["Metering Mode"] = "\(metering)"
        }

        if let exposureMode = exif[kCGImagePropertyExifExposureMode] as? Int {
            fields["Exposure Mode"] = "\(exposureMode)"
        }

        if let exposureProgram = exif[kCGImagePropertyExifExposureProgram] as? Int {
            fields["Exposure Program"] = "\(exposureProgram)"
        }

        if let shutter = exif[kCGImagePropertyExifShutterSpeedValue] as? Double {
            fields["Shutter Speed"] = InformationFormatting.formatFloat(shutter)
        }

        if let apertureValue = exif[kCGImagePropertyExifApertureValue] as? Double {
            fields["Aperture Value"] = InformationFormatting.formatFloat(apertureValue)
        }

        if let brightness = exif[kCGImagePropertyExifBrightnessValue] as? Double {
            fields["Brightness"] = InformationFormatting.formatFloat(brightness)
        }

        if let subjectDistance = exif[kCGImagePropertyExifSubjectDistance] as? Double {
            fields["Subject Distance"] = InformationFormatting.formatFloat(subjectDistance)
        }

        if let focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int {
            fields["Focal Len (35mm)"] = "\(focal35)mm"
        } else if let focal35 = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber {
            fields["Focal Len (35mm)"] = "\(focal35.intValue)mm"
        }

        if let colorSpace = exif[kCGImagePropertyExifColorSpace] as? Int {
            fields["Color Space"] = "\(colorSpace)"
        }

        return fields
            .filter { !skipNames.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }

    private static func flashLabel(_ value: Int) -> String {
        switch value {
        case 0: return "No Flash"
        case 1: return "Fired"
        case 5: return "Fired, Return not detected"
        case 7: return "Fired, Return detected"
        case 9: return "Fired, Compulsory"
        case 13: return "Fired, Compulsory, Return not detected"
        case 15: return "Fired, Compulsory, Return detected"
        default: return "\(value)"
        }
    }

    enum ExifError: LocalizedError {
        case unsupportedFormat
        case readFailed
        case writeFailed
        case noExifDate
        case noFileDate

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat: return "This file format does not support EXIF editing."
            case .readFailed: return "Could not read image metadata."
            case .writeFailed: return "Could not write image metadata."
            case .noExifDate: return "No EXIF date found in this file."
            case .noFileDate: return "Could not read file date."
            }
        }
    }
}
