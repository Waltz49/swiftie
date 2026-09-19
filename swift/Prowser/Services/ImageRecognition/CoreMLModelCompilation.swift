import CoreML
import Foundation

/// Compiles `.mlpackage` bundles to `.mlmodelc` for `MLModel(contentsOf:)`.
enum CoreMLModelCompilation {
    static func compiledSiblingURL(for mlpackageURL: URL) -> URL {
        mlpackageURL.deletingPathExtension().appendingPathExtension("mlmodelc")
    }

    /// Returns a path suitable for `MLModel(contentsOf:)`, compiling the package if needed.
    static func ensureCompiled(at artifactURL: URL) throws -> URL {
        if artifactURL.pathExtension == "mlmodelc" {
            return artifactURL
        }
        guard artifactURL.pathExtension == "mlpackage" else {
            return artifactURL
        }

        let fm = FileManager.default
        let compiledDest = compiledSiblingURL(for: artifactURL)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: compiledDest.path, isDirectory: &isDir), isDir.boolValue {
            let pkgDate = (try? fm.attributesOfItem(atPath: artifactURL.path)[.modificationDate]) as? Date
            let compDate = (try? fm.attributesOfItem(atPath: compiledDest.path)[.modificationDate]) as? Date
            if let pkgDate, let compDate, compDate >= pkgDate {
                return compiledDest
            }
            try? fm.removeItem(at: compiledDest)
        }

        let compiledTemp = try MLModel.compileModel(at: artifactURL)
        if fm.fileExists(atPath: compiledDest.path) {
            try fm.removeItem(at: compiledDest)
        }
        try fm.copyItem(at: compiledTemp, to: compiledDest)
        return compiledDest
    }

    static func compileInstalledPackages(in directory: URL, packageNames: [String]) throws {
        let fm = FileManager.default
        for name in packageNames where name.hasSuffix(".mlpackage") {
            let package = directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: package.path) else { continue }
            _ = try ensureCompiled(at: package)
        }
    }
}
