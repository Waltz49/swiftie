import AppKit
import Foundation

/// Port of ``pixelmator_export`` AppleScript export and Pixelmator Pro launch for infill refine.
enum PixelmatorInfillService {
    private static let multiOpenScript = """
    on run argv
      set maxWidth to (item 1 of argv) as integer
      set maxHeight to (item 2 of argv) as integer
      set firstPath to POSIX file (item 3 of argv)
      set extraFiles to {}
      repeat with i from 4 to count of argv
        set end of extraFiles to POSIX file (item i of argv)
      end repeat

      tell application "Pixelmator Pro"
        activate
        open firstPath
        repeat until (count of documents) > 0
          delay 0.2
        end repeat
        set docRef to front document
        if maxWidth > 0 and maxHeight > 0 then
          tell docRef
            resize canvas width maxWidth height maxHeight anchor position middle center
          end tell
        end if
        repeat with f in extraFiles
          tell docRef
            make new image layer at the end of layers with properties {file:contents of f, preserve transparency:true}
          end tell
        end repeat
        tell docRef
          set current layer to first layer
        end tell
      end tell
    end run
    """

    static func isPixelmatorRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", "Pixelmator Pro"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func launchPixelmatorProMultiFiles(paths: [String], canvasWidth: Int = 0, canvasHeight: Int = 0) -> Bool {
        let normalized = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            .filter { FileManager.default.isReadableFile(atPath: $0) }
        guard let first = normalized.first else { return false }
        var args = [
            String(canvasWidth),
            String(canvasHeight),
            first,
        ]
        args.append(contentsOf: normalized.dropFirst())
        return runOSAScriptFile(source: multiOpenScript, argv: args)
    }

    static func exportBaseAndMask(tempRoot: URL) -> Result<[String: Any], PixelmatorInfillError> {
        if !isPixelmatorRunning() {
            return .failure(.message(
                "Pixelmator Pro is not running. Open an image with a mask layer first."
            ))
        }
        let exportDir = ProwserTempFiles.pixelmatorExportDirectory(tempRoot: tempRoot)
        cleanExistingExports(in: exportDir)
        var meta: [String: Any] = [
            "pixelmator_doc_name": frontDocumentName() ?? "",
            "pixelmator_doc_path": frontDocumentPath() ?? "",
        ]
        guard runExportAppleScript(exportDir: exportDir) else {
            return .failure(.message("Pixelmator export failed."))
        }
        Thread.sleep(forTimeInterval: 1.0)
        let basePath = (exportDir as NSString).appendingPathComponent("base.webp")
        let maskPath = (exportDir as NSString).appendingPathComponent("mask.webp")
        guard FileManager.default.isReadableFile(atPath: basePath),
              FileManager.default.isReadableFile(atPath: maskPath) else {
            return .failure(.message(
                "Export did not create base.webp and mask.webp in \(exportDir). "
                    + "Use a canvas with at least two layers (mask on top, image below)."
            ))
        }
        if let name = frontDocumentName(), !name.isEmpty {
            meta["pixelmator_doc_name"] = name
        }
        if let path = frontDocumentPath(), !path.isEmpty {
            meta["pixelmator_doc_path"] = path
        }
        meta["pixelmator_base_path"] = basePath
        meta["pixelmator_mask_path"] = maskPath
        return .success(meta)
    }

    @MainActor
    static func runRefineDialog() -> Bool {
        let index = StyledMessageDialog.present(
            title: "Refine in Pixelmator",
            message: "Edit mask in Pixelmator and press OK.",
            style: .informational,
            icon: .information,
            buttons: [
                StyledMessageDialog.Button("Cancel", role: .dismissive),
                StyledMessageDialog.Button("OK", role: .affirmative),
            ],
            defaultButtonIndex: 1,
            escapeButtonIndex: 0
        )
        return index == 1
    }

    private static func cleanExistingExports(in exportDir: String) {
        for name in ["base.webp", "mask.webp"] {
            let path = (exportDir as NSString).appendingPathComponent(name)
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private static func runExportAppleScript(exportDir: String) -> Bool {
        guard let url = ProwserResourceBundle.bundle.url(
            forResource: "applescript_pixelmator_export",
            withExtension: "applescript"
        ),
              let template = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        let script = template.replacingOccurrences(of: "__EXPORT_DIR__", with: exportDir)
        return runOSAScript(script, stdin: true)
    }

    private static func frontDocumentName() -> String? {
        let script = """
        tell application "Pixelmator Pro"
        if not (exists front document) then return ""
        return name of front document
        end tell
        """
        return runOSAScriptOneLine(script)
    }

    private static func frontDocumentPath() -> String? {
        let script = """
        tell application "Pixelmator Pro"
        if not (exists front document) then return ""
        try
        return POSIX path of (file of front document)
        on error
        return ""
        end try
        end tell
        """
        let path = runOSAScriptOneLine(script)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if path.isEmpty || !FileManager.default.isReadableFile(atPath: path) { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func runOSAScriptOneLine(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == true ? nil : text
    }

    private static func runOSAScript(_ script: String, stdin: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        guard stdin else { return false }
        process.arguments = ["-"]
        let pipe = Pipe()
        process.standardInput = pipe
        do {
            try process.run()
            pipe.fileHandleForWriting.write(script.data(using: .utf8) ?? Data())
            try pipe.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func runOSAScriptFile(source: String, argv: [String]) -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("prowser-pixelmator-multi-\(UUID().uuidString).applescript")
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [url.path] + argv
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

enum PixelmatorInfillError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        }
    }
}
