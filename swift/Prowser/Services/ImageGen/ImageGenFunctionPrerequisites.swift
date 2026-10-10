import AppKit
import Foundation

@MainActor
enum ImageGenFunctionPrerequisites {
    static func validate(
        function: String,
        appState: AppState,
        editSourcePaths: [String] = [],
        persistedSourcePath: String? = nil,
        showWarning: Bool = true
    ) -> Bool {
        switch function {
        case "infill":
            if normalizedExistingFile(persistedSourcePath) != nil {
                return true
            }
            if activeImagePathForExpandOrInfill(appState: appState) != nil {
                return true
            }
            if showWarning {
                showAlert(
                    title: "Infill",
                    message: "Select an image in browse view, or select a single thumbnail, "
                        + "before using infill by painting."
                )
            }
            return false
        case "expand":
            if normalizedExistingFile(persistedSourcePath) != nil {
                return true
            }
            if activeImagePathForExpandOrInfill(appState: appState) != nil {
                return true
            }
            if showWarning {
                showAlert(
                    title: "Expand",
                    message: "Select an image in browse view, or select a single thumbnail, "
                        + "before using expand."
                )
            }
            return false
        case "edit":
            let explicit = ImageGenEditSourcePaths.normalizedPaths(editSourcePaths)
            if !explicit.isEmpty {
                if explicit.count > ImageGenEditSourcePaths.maxSourceImages {
                    if showWarning {
                        showAlert(
                            title: "Edit",
                            message: "Select at most \(ImageGenEditSourcePaths.maxSourceImages) images before using edit."
                        )
                    }
                    return false
                }
                return true
            }
            let active = ImageGenEditSourcePaths.activeImagePathsForEdit(appState: appState)
            if !active.isEmpty { return true }
            if showWarning {
                showAlert(
                    title: "Edit",
                    message: "Select an image in browse view, or select up to "
                        + "\(ImageGenEditSourcePaths.maxSourceImages) thumbnails, before using edit."
                )
            }
            return false
        default:
            return true
        }
    }

    static func activeImagePathForExpandOrInfill(appState: AppState) -> String? {
        ImageGenExifImport.activeImagePathForBrowseOrThumbnail(appState: appState)
    }

    static func normalizedExistingFile(_ path: String?) -> String? {
        let trimmed = (path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = (trimmed as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: normalized) else { return nil }
        return normalized
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
