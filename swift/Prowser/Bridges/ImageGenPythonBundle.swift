import Foundation

/// Vendored `swift/ImageGenPython` tree (synced from monorepo; see `Scripts/sync_imagegen_python.sh`).
enum ImageGenPythonBundle {
    static let bundleResourceName = "ImageGenPython"

    /// Root directory containing `imagegen_plugins/`, placed on `PYTHONPATH`.
    static func rootURL() -> URL? {
        if let resource = ProwserResourceBundle.bundle.resourceURL?
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

    /// Colon-separated ``PYTHONPATH`` for worker subprocesses.
    ///
    /// Always includes ``bundleRoot`` (``imagegen_plugins``, ``config``, …).
    /// LoRA probe CNN compare imports ``search.cnn_image_similarity_sorter`` (same stack as ⌘K).
    /// When ``bundleRoot/search`` is vendored (sync script), that alone is enough; otherwise
    /// append the monorepo root (``swift/ImageGenPython`` → parent ``swift`` → repo root).
    nonisolated static func pythonPath(forBundleRoot bundleRoot: URL) -> String {
        var entries = [bundleRoot.path]
        let vendoredSearch = bundleRoot.appendingPathComponent("search", isDirectory: true)
        if !FileManager.default.fileExists(atPath: vendoredSearch.path),
           let repoRoot = monorepoRootForBundledDevLayout(imageGenRoot: bundleRoot) {
            entries.append(repoRoot.path)
        }
        return entries.joined(separator: ":")
    }

    /// ``…/swift/ImageGenPython`` in the monorepo; nil for shipped ``Resources/.../ImageGenPython`` only trees.
    nonisolated private static func monorepoRootForBundledDevLayout(imageGenRoot: URL) -> URL? {
        let swiftPackage = imageGenRoot.deletingLastPathComponent()
        guard swiftPackage.lastPathComponent == "swift" else { return nil }
        let repoRoot = swiftPackage.deletingLastPathComponent()
        let searchDir = repoRoot.appendingPathComponent("search", isDirectory: true)
        guard FileManager.default.fileExists(atPath: searchDir.path) else { return nil }
        return repoRoot
    }

    nonisolated static func applyPythonEnvironment(
        _ env: inout [String: String],
        bundleRoot: URL,
        profilePath: String?
    ) {
        env["PYTHONPATH"] = pythonPath(forBundleRoot: bundleRoot)
        env["PYTHONUNBUFFERED"] = "1"
        if let profilePath, !profilePath.isEmpty {
            env["PROWSER_PROFILE"] = profilePath
        }
    }
}
