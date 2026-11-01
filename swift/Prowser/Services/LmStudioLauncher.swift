import AppKit
import Foundation

/// Launch LM Studio.app or prompt to install (port of ``lmstudio_launcher.py``).
@MainActor
enum LmStudioLauncher {
    private static let downloadURL = URL(string: "https://lmstudio.ai/")!

    static func isAppInstalled() -> Bool {
        installPaths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    @discardableResult
    static func launch() -> Bool {
        guard isAppInstalled() else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "LM Studio"]
        do {
            try task.run()
            return true
        } catch {
            return false
        }
    }

    static func openOrShowInstallHelp() {
        if isAppInstalled() {
            if launch() { return }
            StyledMessageDialog.showWarning(
                title: "Open LM Studio",
                message: "LM Studio appears to be installed but could not be launched."
            )
            return
        }

        let openDownload = StyledMessageDialog.showQuestion(
            title: "Install LM Studio",
            message: """
            LM Studio is not installed.

            Download it from lmstudio.ai, then drag LM Studio.app into Applications (or ~/Applications).

            With LM Studio running and a vision model loaded, Prowser can use it for AI EXIF captions and image-generation prompts.

            Open the download page in your browser?
            """,
            defaultNo: false
        )
        if openDownload {
            NSWorkspace.shared.open(downloadURL)
        }
    }

    private static var installPaths: [String] {
        [
            "/Applications/LM Studio.app",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications/LM Studio.app"),
        ]
    }
}
