import AppKit
import Foundation

/// GPS map opening. Port of `files/map_manager.py` (phase 1).
enum MapService {
    enum MapError: Error {
        case noImages
        case noGPSData(String)
        case openFailed(String)
    }

    static func openMap(
        for paths: [String],
        preferredApp: String,
        temporaryDirectory: URL? = nil
    ) -> Result<Void, MapError> {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return .failure(.noImages) }

        let located = existing.compactMap { path -> (String, Double, Double)? in
            guard let coords = ExifService.gpsCoordinates(for: path) else { return nil }
            return (path, coords.latitude, coords.longitude)
        }
        guard !located.isEmpty else {
            let message = existing.count == 1
                ? "No GPS location data found in the image."
                : "No GPS location data found in any of the \(existing.count) selected images."
            return .failure(.noGPSData(message))
        }

        let app = preferredApp.isEmpty ? "apple_maps" : preferredApp
        if app == "google_earth", located.count > 1 {
            return openGoogleEarthKML(located, temporaryDirectory: temporaryDirectory)
        }

        let (_, lat, lon) = located[0]
        return openCoordinates(
            latitude: lat,
            longitude: lon,
            preferredApp: app,
            temporaryDirectory: temporaryDirectory
        )
    }

    private static func openCoordinates(
        latitude: Double,
        longitude: Double,
        preferredApp: String,
        temporaryDirectory: URL? = nil
    ) -> Result<Void, MapError> {
        switch preferredApp {
        case "google_maps":
            let url = URL(string: "https://www.google.com/maps?q=\(latitude),\(longitude)")!
            if openInChrome(url) || NSWorkspace.shared.open(url) {
                return .success(())
            }
        case "google_earth":
            if case .success = openGoogleEarthKML([("", latitude, longitude)], temporaryDirectory: temporaryDirectory) {
                return .success(())
            }
        default:
            let url = URL(string: "maps://?q=\(latitude),\(longitude)")!
            if NSWorkspace.shared.open(url) {
                return .success(())
            }
        }

        let fallback = URL(string: "maps://?q=\(latitude),\(longitude)")!
        if NSWorkspace.shared.open(fallback) {
            return .success(())
        }

        return .failure(.openFailed(
            "No map applications are available. Please install Apple Maps, Google Chrome, or Google Earth."
        ))
    }

    private static func openInChrome(_ url: URL) -> Bool {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil else {
            return false
        }
        return runOpenCommand(application: "Google Chrome", target: url)
    }

    private static func runOpenCommand(application: String, target: URL) -> Bool {
        let targetArg = target.isFileURL ? target.path : target.absoluteString
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", application, targetArg]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func openGoogleEarthKML(
        _ located: [(String, Double, Double)],
        temporaryDirectory: URL?
    ) -> Result<Void, MapError> {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.EarthPro")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.earth")
        guard let appURL else {
            let first = located[0]
            return openCoordinates(latitude: first.1, longitude: first.2, preferredApp: "apple_maps")
        }

        let placemarks = located.map { item in
            let name = item.0.isEmpty ? "Location" : (item.0 as NSString).lastPathComponent
            return """
                <Placemark>
                  <name>\(escapeXML(name))</name>
                  <Point><coordinates>\(item.2),\(item.1),0</coordinates></Point>
                </Placemark>
            """
        }.joined(separator: "\n")

        let kml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
        \(placemarks)
          </Document>
        </kml>
        """

        let tempRoot = temporaryDirectory ?? FileManager.default.temporaryDirectory
        let url = tempRoot.appendingPathComponent("prowser-map-\(UUID().uuidString).kml")
        do {
            try kml.write(to: url, atomically: true, encoding: .utf8)
            let appName = appURL.deletingPathExtension().lastPathComponent
            if runOpenCommand(application: appName, target: url) {
                return .success(())
            }
            if NSWorkspace.shared.open(url) {
                return .success(())
            }
            let first = located[0]
            return openCoordinates(latitude: first.1, longitude: first.2, preferredApp: "apple_maps")
        } catch {
            let first = located[0]
            return openCoordinates(latitude: first.1, longitude: first.2, preferredApp: "apple_maps")
        }
    }

    private static func escapeXML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
