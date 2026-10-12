import Foundation

/// Restore unified-dialog sources when editing a queue job (Python ``open_imagegen_dialog_from_job`` / ``_job_session_state``).
@MainActor
enum ImageGenJobDialogRestore {
    static func editSourcePaths(from values: [String: Any], tempRoot: String) -> [String] {
        let fromExif = ImageGenExifReferences.sourcePathsForGenerationExif(values: values, tempRoot: tempRoot)
        if !fromExif.isEmpty { return fromExif }
        return ImageGenExifReferences.resolveSourceImagePaths(values)
    }

    static func infillSourcePath(from values: [String: Any], tempRoot: String) -> String? {
        for key in ["source_image_path", "pixelmator_base_path", "pixelmator_doc_path"] {
            guard let raw = values[key] as? String,
                  let path = ImageGenFunctionPrerequisites.normalizedExistingFile(raw) else { continue }
            if key == "pixelmator_base_path" {
                return path
            }
            if !ImageGenInfillPathSemantics.isWorkingTempPath(path, tempRoot: tempRoot) {
                return path
            }
        }
        return nil
    }
}
