import Foundation

/// Display model for the information pane.
struct ExifRecord {
    var filePath: String
    var fileName: String
    var directory: String
    var fileSize: String
    var fileDate: String
    var imageSize: String
    var exifDate: String?
    var camera: String?
    var lens: String?
    var orientation: String?
    var location: String?
    var description: String?
    var exposure: String?
    var aperture: String?
    var iso: String?
    var focalLength: String?
    var software: String?
    var artist: String?
    var extraFields: [(String, String)]

    static let empty = ExifRecord(
        filePath: "",
        fileName: "",
        directory: "",
        fileSize: "",
        fileDate: "",
        imageSize: "",
        exifDate: nil,
        camera: nil,
        lens: nil,
        orientation: nil,
        location: nil,
        description: nil,
        exposure: nil,
        aperture: nil,
        iso: nil,
        focalLength: nil,
        software: nil,
        artist: nil,
        extraFields: []
    )
}
