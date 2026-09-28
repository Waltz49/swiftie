import Foundation
import ImageIO

/// EXIF month/year section boundaries for segmented thumbnail grid (Python `exif_date_sections`).
@MainActor
enum ExifSectionPresentation {
    struct Section: Equatable, Sendable {
        var startIndex: Int
        var sectionKey: String
    }

    static func sections(
        for sortedPaths: [String],
        mode: SortMode,
        metadataCache: MetadataCacheService?
    ) -> [Section] {
        guard mode == .exifDate || mode == .exifYear else { return [] }
        guard !sortedPaths.isEmpty else { return [] }

        var result: [Section] = []
        var currentKey: String?
        for (index, path) in sortedPaths.enumerated() {
            let key = sectionKey(for: path, mode: mode, metadataCache: metadataCache)
            if key != currentKey {
                result.append(Section(startIndex: index, sectionKey: key))
                currentKey = key
            }
        }
        return result
    }

    private static func sectionKey(
        for path: String,
        mode: SortMode,
        metadataCache: MetadataCacheService?
    ) -> String {
        let timestamp: Int
        if let cache = metadataCache {
            timestamp = cache.fileTimestamp(path: path, preferExif: true)
        } else if let date = exifCaptureDate(path: path) {
            timestamp = Int(date.timeIntervalSince1970)
        } else {
            return "undated"
        }
        guard timestamp > 0 else { return "undated" }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date)
        if mode == .exifYear {
            return String(year)
        }
        let month = calendar.component(.month, from: date)
        return String(format: "%04d-%02d", year, month)
    }

    private static func exifCaptureDate(path: String) -> Date? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let date = formatter.date(from: dateString) {
            return date
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let dateString = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let date = formatter.date(from: dateString) {
            return date
        }
        return nil
    }
}
