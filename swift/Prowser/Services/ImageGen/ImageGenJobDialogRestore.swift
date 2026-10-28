import Foundation

/// Restore unified-dialog sources when editing a queue job (Python ``open_imagegen_dialog_from_job`` / ``_job_session_state``).
@MainActor
enum ImageGenJobDialogRestore {
    /// Python ``_job_session_state`` (edit): live ``source_image_paths`` / ``source_image_path`` only.
    /// Do not use ``sourcePathsForGenerationExif`` here — ``_canonical_source_image_paths`` is for
    /// output EXIF and can lag behind the panel list after Replace/Update.
    static func editSourcePaths(from values: [String: Any], tempRoot: String) -> [String] {
        _ = tempRoot
        return ImageGenExifReferences.resolveSourceImagePaths(values).filter {
            FileManager.default.fileExists(atPath: $0)
        }
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
