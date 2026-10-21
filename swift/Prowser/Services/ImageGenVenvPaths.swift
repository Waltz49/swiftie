import Foundation

/// Profile-local Python venv for imagegen (torch, diffusers, mflux, etc.).
enum ImageGenVenvPaths {
    static let defaultRelativePath = "venvs/imagegen"

    static func defaultVenvURL(prowserHome: URL) -> URL {
        prowserHome.appendingPathComponent(defaultRelativePath, isDirectory: true)
    }

    static func pythonExecutable(in venv: URL) -> URL {
        venv.appendingPathComponent("bin/python3")
    }

    /// Bundled `requirements-imagegen.txt` from app resources or package tree.
    static func bundledRequirementsURL() -> URL? {
        let bundle = ProwserResourceBundle.bundle
        if let url = bundle.url(forResource: "requirements-imagegen", withExtension: "txt"),
           FileManager.default.isReadableFile(atPath: url.path) {
            return url
        }
        let package = devSwiftPackageRoot()
            .appendingPathComponent("requirements-imagegen.txt")
        return FileManager.default.isReadableFile(atPath: package.path) ? package : nil
    }

    /// `swift/` package root when running from source (`swift run`).
    private static func devSwiftPackageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
