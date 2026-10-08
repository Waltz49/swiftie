import Foundation

/// Vendored `swift/ImageGenPython` tree (synced from monorepo; see `Scripts/sync_imagegen_python.sh`).
enum ImageGenPythonBundle {
    static let bundleResourceName = "ImageGenPython"

    /// Root directory containing `imagegen_plugins/`, placed on `PYTHONPATH`.
    static func rootURL() -> URL? {
        if let resource = Bundle.main.resourceURL?
            .appendingPathComponent(bundleResourceName, isDirectory: true),
           FileManager.default.fileExists(atPath: resource.appendingPathComponent("imagegen_plugins").path) {
            return resource
        }
        let dev = devPackageImageGenRoot()
        if FileManager.default.fileExists(atPath: dev.appendingPathComponent("imagegen_plugins").path) {
            return dev
        }
        if let env = ProcessInfo.processInfo.environment["PROWSER_IMAGEGEN_PYTHON_ROOT"],
           !env.isEmpty {
            let url = URL(fileURLWithPath: (env as NSString).expandingTildeInPath).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("imagegen_plugins").path) {
                return url
            }
        }
        return nil
    }

    /// `swift/ImageGenPython` when running via `swift run` from the package.
    private static func devPackageImageGenRoot() -> URL {
        // Prowser/Bridges/ImageGenPythonBundle.swift → swift/ImageGenPython
        let bridges = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return bridges
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(bundleResourceName, isDirectory: true)
    }

    nonisolated static func applyPythonEnvironment(
        _ env: inout [String: String],
        bundleRoot: URL,
        profilePath: String?
    ) {
        env["PYTHONPATH"] = bundleRoot.path
        env["PYTHONUNBUFFERED"] = "1"
        if let profilePath, !profilePath.isEmpty {
            env["PROWSER_PROFILE"] = profilePath
        }
    }
}
