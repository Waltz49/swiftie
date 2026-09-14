import AppKit
import CoreGraphics
import Foundation

/// Copy vs move for file URL drags (thumbnail → tree, Finder, etc.). Matches macOS / Python drag conventions.
enum FileDragDropOperations {
    /// `NSEvent.modifierFlags` is often stale during an active drag; read HID state instead.
    static func dragModifierFlags() -> NSEvent.ModifierFlags {
        let cgFlags = CGEventSource.flagsState(.combinedSessionState)
        var flags = NSEvent.ModifierFlags()
        if cgFlags.contains(.maskAlternate) {
            flags.insert(.option)
        }
        if cgFlags.contains(.maskCommand) {
            flags.insert(.command)
        }
        if cgFlags.contains(.maskShift) {
            flags.insert(.shift)
        }
        if cgFlags.contains(.maskControl) {
            flags.insert(.control)
        }
        return flags.intersection(.deviceIndependentFlagsMask)
    }

    static func sourceOperationMask(for context: NSDraggingContext) -> NSDragOperation {
        // Always offer both. Destination (and ⌥) pick copy vs move. Returning `.copy`
        // only while Option is held makes AppKit cancel the drop when Option is
        // released on mouse-up (slide-back, as if Escape was pressed).
        [.copy, .move]
    }

    /// Single operation for destination feedback (cursor badge + drop). Never return `.copy | .move`.
    static func destinationOperation(
        sourceMask: NSDragOperation,
        filePaths: [String],
        targetDirectory: String?
    ) -> NSDragOperation {
        let flags = dragModifierFlags()
        if flags.contains(.option) {
            return .copy
        }
        if flags.contains(.command) {
            return sourceMask.contains(.move) ? .move : []
        }

        guard let targetDirectory, !filePaths.isEmpty else { return [] }

        let offered = sourceMask == [] ? NSDragOperation([.copy, .move]) : sourceMask
        let allowed = offered.intersection([.copy, .move])
        guard allowed != [] else { return [] }

        if filePaths.contains(where: RenamePrefixPlanner.isInsidePhotosLibrary) {
            return allowed.contains(.copy) ? .copy : []
        }

        let sameVolume = filePaths.allSatisfy { isSameVolume(file: $0, directory: targetDirectory) }
        if sameVolume, allowed.contains(.move) {
            return .move
        }
        if allowed.contains(.copy) {
            return .copy
        }
        return allowed
    }

    /// Use the operation negotiated while dragging. Do not re-read Option at mouse-up;
    /// AppKit often delivers the drop after modifiers have already been released.
    static func isCopyDrop(_ operation: NSDragOperation) -> Bool {
        operation == .copy
    }

    private static func isSameVolume(file: String, directory: String) -> Bool {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        let dirURL = URL(fileURLWithPath: directory).standardizedFileURL
        if let fileVol = volumeIdentifier(for: fileURL),
           let dirVol = volumeIdentifier(for: dirURL) {
            return fileVol == dirVol
        }
        guard let fileDevice = fileSystemDevice(for: fileURL.path),
              let dirDevice = fileSystemDevice(for: dirURL.path) else {
            return false
        }
        return fileDevice == dirDevice
    }

    private static func volumeIdentifier(for url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    private static func fileSystemDevice(for path: String) -> dev_t? {
        var statBuf = stat()
        guard lstat(path, &statBuf) == 0 else { return nil }
        return statBuf.st_dev
    }
}
