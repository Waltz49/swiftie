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
        if let url = Bundle.main.url(forResource: "requirements-imagegen", withExtension: "txt") {
            return url
        }
        if let resource = Bundle.main.resourceURL?
            .appendingPathComponent("requirements-imagegen.txt"),
           FileManager.default.fileExists(atPath: resource.path) {
            return resource
        }
        let package = devSwiftPackageRoot()
            .appendingPathComponent("requirements-imagegen.txt")
        return FileManager.default.fileExists(atPath: package.path) ? package : nil
    }

    /// `swift/` package root when running from source (`swift run`).
    private static func devSwiftPackageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
