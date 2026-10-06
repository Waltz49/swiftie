import Foundation

/// Builds plain-text overlay data for the information pane. Port of `information_sidebar.py` field assembly.
@MainActor
enum InformationOverlayBuilder {
    private static let priorityExifFields = ["Camera", "Orientation", "Lens", "Location"]

    static func buildOverlayData(
        from record: ExifRecord,
        imageDirectory: String,
        imagePath: String
    ) -> InformationOverlayData {
        var pairs: [(String, String)] = []

        let directory = InformationFormatting.normalizePathForDisplay(record.directory)
        if !directory.isEmpty {
            pairs.append(("Directory", InformationFormatting.elideValue(directory)))
        }

        if !record.imageSize.isEmpty {
            pairs.append(("Image Size", record.imageSize))
        }

        if !record.fileSize.isEmpty, !InformationFormatting.isZeroValue(record.fileSize) {
            pairs.append(("File Size", record.fileSize))
        }

        if !record.fileDate.isEmpty {
            pairs.append(("File Date", record.fileDate))
        }

        if let exifDate = record.exifDate, !exifDate.isEmpty {
            pairs.append(("EXIF Date", exifDate))
        }

        for field in priorityExifFields {
            let value = priorityValue(field, record: record)
            if let value, !InformationFormatting.isZeroValue(value) {
                pairs.append((field, InformationFormatting.elideValue(value)))
            }
        }

        var speakablePlainText: String?
        if let description = record.description?.replacingOccurrences(of: "\u{0000}", with: ""),
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("b'"),
           !description.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("b\"") {
            speakablePlainText = ImageGenExifCommentFormatting.formatUserCommentTextForDisplay(description)
        }

        let remaining = remainingFieldPairs(from: record)
        pairs.append(contentsOf: remaining)

        return InformationOverlayData(
            filename: record.fileName,
            fieldValuePairs: pairs,
            speakablePlainText: speakablePlainText,
            imageDirectory: imageDirectory,
            imagePath: imagePath
        )
    }

    private static func priorityValue(_ field: String, record: ExifRecord) -> String? {
        switch field {
        case "Camera": return record.camera
        case "Orientation": return record.orientation
        case "Lens": return record.lens
        case "Location": return record.location
        default: return nil
        }
    }

    private static func remainingFieldPairs(from record: ExifRecord) -> [(String, String)] {
        var extras: [(String, String)] = []
        let named: [(String, String?)] = [
            ("Exposure", record.exposure),
            ("Aperture", record.aperture),
            ("ISO", record.iso),
            ("Focal Length", record.focalLength),
            ("Software", record.software),
            ("Artist", record.artist),
        ]
        for (field, value) in named {
            guard let value, !InformationFormatting.isZeroValue(value) else { continue }
            extras.append((field, InformationFormatting.elideValue(value)))
        }
        for (field, value) in record.extraFields.sorted(by: { $0.0 < $1.0 }) {
            guard !InformationFormatting.isZeroValue(value) else { continue }
            extras.append((field, InformationFormatting.elideValue(value)))
        }
        return extras
    }
}
