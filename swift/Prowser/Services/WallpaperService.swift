import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Desktop wallpaper operations. Port of `browser_window/managers/wallpaper_manager.py`.
@MainActor
final class WallpaperManager {
    enum FitMethod: String {
        case contain
        case cover
        case width
        case height

        init(configValue: String) {
            switch configValue {
            case "cover": self = .cover
            case "width", "fitWidth": self = .width
            case "height", "fitHeight": self = .height
            default: self = .contain
            }
        }

        var configValue: String { rawValue }
    }

    enum WallpaperError: LocalizedError {
        case fileNotFound
        case noScreen
        case loadFailed
        case saveFailed
        case setFailed

        var errorDescription: String? {
            switch self {
            case .fileNotFound: return "No current image available"
            case .noScreen: return "No main display found."
            case .loadFailed: return "Could not load image."
            case .saveFailed: return "Failed to create wallpaper file"
            case .setFailed: return "Failed to set desktop background"
            }
        }
    }

    private weak var appState: AppState?
    private var previousWallpaperPath: String?
    private var previousWallpaperBackupPath: String?

    func bind(_ appState: AppState) {
        self.appState = appState
    }

    var canUndoWallpaper: Bool {
        previousWallpaperPath != nil || previousWallpaperBackupPath != nil
    }

    private var wallpaperDirectory: URL {
        appState?.config.profilePaths.wallpaperDirectory
            ?? ProfilePaths(profilePath: nil).wallpaperDirectory
    }

    func setImageAsDesktopBackground(
        imagePath: String,
        fitMethod: FitMethod,
        ignoreExifRotation: Bool? = nil
    ) throws {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw WallpaperError.fileNotFound
        }
        if isInOSSpacesFullscreen() {
            StyledMessageDialog.showWarning(
                title: "Cannot Set Wallpaper",
                message: "Cannot set wallpaper while in OS fullscreen mode."
            )
            return
        }

        let ignoreExif = ignoreExifRotation ?? appState?.config.ignoreExifRotation ?? false
        let wallpaperDir = wallpaperDirectory
        try FileManager.default.createDirectory(at: wallpaperDir, withIntermediateDirectories: true)

        backupCurrentWallpaper()

        let letterboxedPath: String
        if isFileInWallpaperDirectory(imagePath, wallpaperDir: wallpaperDir) {
            letterboxedPath = URL(fileURLWithPath: imagePath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        } else {
            letterboxedPath = try createLetterboxedWallpaperFile(
                imagePath: imagePath,
                fitMethod: fitMethod,
                wallpaperDir: wallpaperDir,
                ignoreExifRotation: ignoreExif
            )
        }

        guard FileManager.default.fileExists(atPath: letterboxedPath) else {
            throw WallpaperError.saveFailed
        }

        try applyDesktopImage(path: letterboxedPath)

        let filename = (imagePath as NSString).lastPathComponent
        appState?.status.show("Set '\(filename)' as desktop background")
        appState?.refreshMenuState()
    }

    @discardableResult
    func undoWallpaper() -> Bool {
        if isInOSSpacesFullscreen() {
            StyledMessageDialog.showWarning(
                title: "Undo Failed",
                message: "Cannot undo wallpaper while in OS fullscreen mode."
            )
            return false
        }

        let restorePath: String?
        if let backup = previousWallpaperBackupPath, FileManager.default.fileExists(atPath: backup) {
            restorePath = backup
        } else if let original = previousWallpaperPath, FileManager.default.fileExists(atPath: original) {
            restorePath = original
        } else {
            StyledMessageDialog.showWarning(title: "Restore Error", message: "Previous wallpaper not found")
            return false
        }

        guard let restorePath else { return false }

        do {
            try applyDesktopImage(path: restorePath)
        } catch {
            StyledMessageDialog.showWarning(title: "Restore Error", message: "Undo: Error restoring wallpaper")
            return false
        }

        appState?.status.show("Undo: Previous wallpaper restored")

        if let backup = previousWallpaperBackupPath,
           backup != restorePath,
           FileManager.default.fileExists(atPath: backup) {
            try? FileManager.default.removeItem(atPath: backup)
        }

        previousWallpaperPath = nil
        previousWallpaperBackupPath = nil
        appState?.refreshMenuState()
        return true
    }

    /// Remove ephemeral scratch files only; keep numbered `prowser_wallpaper-*.webp` (Python `cleanup_temp_files`).
    func cleanupTempFiles() {
        let dir = wallpaperDirectory.path
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in names {
            if name.hasPrefix("temp_") || name.hasSuffix(".tmp") || name == "desktop.webp" {
                try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(name))
            }
        }
    }

    private func backupCurrentWallpaper() {
        guard let screen = NSScreen.main else { return }
        guard let currentURL = NSWorkspace.shared.desktopImageURL(for: screen) else {
            previousWallpaperPath = nil
            previousWallpaperBackupPath = nil
            return
        }

        let currentPath = currentURL.path
        if isFileInWallpaperDirectory(currentPath, wallpaperDir: wallpaperDirectory) {
            previousWallpaperPath = currentPath
            previousWallpaperBackupPath = nil
            return
        }

        let backupName = "backup_wallpaper_\(Int(Date().timeIntervalSince1970)).webp"
        let backupPath = wallpaperDirectory.appendingPathComponent(backupName).path
        do {
            try FileManager.default.createDirectory(at: wallpaperDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: backupPath) {
                try FileManager.default.removeItem(atPath: backupPath)
            }
            try FileManager.default.copyItem(atPath: currentPath, toPath: backupPath)
            previousWallpaperPath = currentPath
            previousWallpaperBackupPath = backupPath
        } catch {
            NSLog("Error backing up wallpaper: \(error)")
        }
    }

    private func applyDesktopImage(path: String) throws {
        guard let screen = NSScreen.main else { throw WallpaperError.noScreen }
        // Python `wallpaper_manager.py`: NSWorkspaceDesktopImageScalingKey = 3 (proportionally up/down).
        // Letterboxed file is screen-sized in points; system scales to fit the display.
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: true,
            .fillColor: NSColor.black,
        ]
        let url = URL(fileURLWithPath: path)
        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
    }

    private func createLetterboxedWallpaperFile(
        imagePath: String,
        fitMethod: FitMethod,
        wallpaperDir: URL,
        ignoreExifRotation: Bool
    ) throws -> String {
        guard let mainScreen = NSScreen.main else { throw WallpaperError.noScreen }
        let frame = mainScreen.frame
        let screenWidth = Int(frame.width)
        let screenHeight = Int(frame.height)

        let sourceURL = URL(fileURLWithPath: imagePath)
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = ImageReencodeMetadata.orientedImage(from: source, ignoreExifRotation: ignoreExifRotation) else {
            throw WallpaperError.loadFailed
        }

        let imgWidth = image.width
        let imgHeight = image.height
        guard imgWidth > 0, imgHeight > 0 else { throw WallpaperError.loadFailed }

        let scaleX = Double(screenWidth) / Double(imgWidth)
        let scaleY = Double(screenHeight) / Double(imgHeight)
        let scale: Double
        switch fitMethod {
        case .contain: scale = min(scaleX, scaleY)
        case .cover: scale = max(scaleX, scaleY)
        case .width: scale = scaleX
        case .height: scale = scaleY
        }

        let newWidth = max(1, Int(Double(imgWidth) * scale))
        let newHeight = max(1, Int(Double(imgHeight) * scale))
        let resized = resize(image: image, width: newWidth, height: newHeight)
        let letterboxed = cropOrPadToScreen(
            image: resized,
            screenWidth: screenWidth,
            screenHeight: screenHeight
        )

        let tempPath = wallpaperDir.appendingPathComponent("desktop.webp").path
        try saveWebP(image: letterboxed, sourcePath: imagePath, to: tempPath)

        Thread.sleep(forTimeInterval: 0.1)

        let tempData = try Data(contentsOf: URL(fileURLWithPath: tempPath))
        let tempMD5 = Insecure.MD5.hash(data: tempData).map { String(format: "%02x", $0) }.joined()

        let incrementLength = renameIncrementLength()
        if let existing = findExistingWallpaperFile(matchingMD5: tempMD5, wallpaperDir: wallpaperDir, skipName: "desktop.webp") {
            try? FileManager.default.removeItem(atPath: tempPath)
            return existing
        }

        let nextNumber = nextWallpaperNumber(wallpaperDir: wallpaperDir, incrementLength: incrementLength)
        let numberedName = String(format: "prowser_wallpaper-%0\(incrementLength)d.webp", nextNumber)
        let numberedPath = wallpaperDir.appendingPathComponent(numberedName).path

        do {
            try FileManager.default.moveItem(atPath: tempPath, toPath: numberedPath)
        } catch {
            try FileManager.default.copyItem(atPath: tempPath, toPath: numberedPath)
            try? FileManager.default.removeItem(atPath: tempPath)
        }
        return numberedPath
    }

    private func renameIncrementLength() -> Int {
        let raw = appState?.config.int(forKey: "rename_increment_length", default: 5) ?? 5
        return min(6, max(3, raw))
    }

    private func nextWallpaperNumber(wallpaperDir: URL, incrementLength: Int) -> Int {
        var numbers = Set<Int>()
        let pattern = #"^prowser_wallpaper-(\d+)\.webp$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 1 }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: wallpaperDir.path) else { return 1 }
        for name in names {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = regex.firstMatch(in: name, range: range),
                  match.numberOfRanges > 1,
                  let numberRange = Range(match.range(at: 1), in: name) else { continue }
            if let value = Int(name[numberRange]) {
                numbers.insert(value)
            }
        }
        return (numbers.max() ?? 0) + 1
    }

    private func findExistingWallpaperFile(matchingMD5 md5: String, wallpaperDir: URL, skipName: String) -> String? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: wallpaperDir.path) else { return nil }
        for name in names {
            if name == skipName { continue }
            let path = wallpaperDir.appendingPathComponent(name).path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            let digest = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if digest == md5 { return path }
        }
        return nil
    }

    private func saveWebP(image: CGImage, sourcePath: String, to path: String) throws {
        let outputURL = URL(fileURLWithPath: path)
        do {
            try WebPImageWriter.write(
                image: image,
                to: outputURL,
                sourcePathForMetadata: sourcePath,
                lossless: false
            )
        } catch {
            NSLog("WallpaperManager: WebP save failed: \(error)")
            throw WallpaperError.saveFailed
        }
    }

    private func resize(image: CGImage, width: Int, height: Int) -> CGImage {
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

    private func cropOrPadToScreen(image: CGImage, screenWidth: Int, screenHeight: Int) -> CGImage {
        let width = image.width
        let height = image.height
        if width == screenWidth, height == screenHeight { return image }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: screenWidth,
            height: screenHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.setFillColor(CGColor.black)
        context.fill(CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight))

        if width > screenWidth || height > screenHeight {
            let cropX = (width - screenWidth) / 2
            let cropY = (height - screenHeight) / 2
            if let cropped = image.cropping(to: CGRect(
                x: cropX, y: cropY, width: screenWidth, height: screenHeight
            )) {
                context.draw(cropped, in: CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight))
            }
        } else {
            let pasteX = (screenWidth - width) / 2
            let pasteY = (screenHeight - height) / 2
            context.draw(
                image,
                in: CGRect(x: pasteX, y: pasteY, width: width, height: height)
            )
        }

        return context.makeImage() ?? image
    }

    /// Python: `os.path.realpath(dirname(image)) == os.path.realpath(wallpaper_dir)`.
    private func isFileInWallpaperDirectory(_ filePath: String, wallpaperDir: URL) -> Bool {
        let fileParent = URL(fileURLWithPath: filePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .path
        let wallpaperPath = wallpaperDir
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return fileParent == wallpaperPath
    }

    private func isInOSSpacesFullscreen() -> Bool {
        let options = NSApp.presentationOptions
        return options.contains(.fullScreen)
    }
}
