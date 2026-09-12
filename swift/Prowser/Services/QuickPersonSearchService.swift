import Foundation

struct QuickPersonFacePickState: Identifiable {
    let id = UUID()
    let path: String
    let previewJPEG: Data?
    let faces: [QuickPersonFace]
}

@MainActor
enum QuickPersonSearchService {
    static let maxImages = 4
    private static var isRunning = false

    static func run(appState: AppState) async {
        guard BundleCapabilities.facesUIEnabled else { return }
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let mode = appState.fileData.currentViewMode
        guard mode == .thumbnail || mode == .browse else { return }

        let paths = dedupedSelectedPaths(appState: appState)
        if paths.isEmpty {
            appState.status.show("Select 1 to 4 images with at least one face each")
            return
        }
        if paths.count > maxImages {
            appState.status.show("Too many images selected (\(paths.count)). Select at most \(maxImages).")
            return
        }

        let bridge = appState.workers.quickPerson
        guard bridge.isAvailable else {
            appState.status.show("Face recognition is not available")
            return
        }

        appState.status.show("Detecting faces…")
        do {
            let encoded = try await bridge.encodeFaces(imagePaths: paths)
            if encoded.isEmpty {
                appState.status.show("Face encoding returned no results")
                return
            }
            var samples: [(path: String, embedding: [Double])] = []
            for result in encoded {
                if result.faces.isEmpty {
                    appState.status.show("No faces found in \((result.path as NSString).lastPathComponent)")
                    return
                }
                let embedding: [Double]
                if result.faces.count == 1 {
                    embedding = result.faces[0].embedding
                } else if let picked = await pickFace(appState: appState, result: result) {
                    embedding = picked
                } else {
                    return
                }
                samples.append((result.path, embedding))
            }

            let subjectID = try await bridge.saveQuickPersonSamples(samples: samples)
            appState.config.updateSetting("find_person_subject_id", value: subjectID)
            appState.knownFacesChangedToken += 1
            await presentPersonSearchSheet(appState: appState)
            appState.status.show("Quick Person samples saved")
        } catch {
            appState.status.show(error.localizedDescription)
        }
    }

    private static func presentPersonSearchSheet(appState: AppState) async {
        if appState.showPersonSearchSheet {
            appState.showPersonSearchSheet = false
            await Task.yield()
        }
        appState.showPersonSearchSheet = true
    }

    private static func dedupedSelectedPaths(appState: AppState) -> [String] {
        // Python `get_deduped_selected_image_paths` uses `get_selected_files()` which
        // falls back to the highlighted/current image when nothing is multi-selected.
        let ordered = SelectionService.selectedFilesOrCurrent(appState: appState)
        var seen = Set<String>()
        var results: [String] = []
        for path in ordered {
            let key = URL(fileURLWithPath: path).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: path), !seen.contains(key) else { continue }
            seen.insert(key)
            results.append(path)
            if results.count >= maxImages { break }
        }
        return results
    }

    private static func pickFace(
        appState: AppState,
        result: QuickPersonImageResult
    ) async -> [Double]? {
        await withCheckedContinuation { continuation in
            let previewData = Data(base64Encoded: result.previewJPEGBase64)
            appState.quickPersonFacePick = QuickPersonFacePickState(
                path: result.path,
                previewJPEG: previewData,
                faces: result.faces
            )
            appState.quickPersonFacePickContinuation = { embedding in
                continuation.resume(returning: embedding)
            }
        }
    }
}

extension AppState {
    func completeQuickPersonFacePick(selectedIndex: Int?) {
        guard let state = quickPersonFacePick else {
            quickPersonFacePickContinuation?(nil)
            quickPersonFacePickContinuation = nil
            return
        }
        quickPersonFacePick = nil
        if let selectedIndex, selectedIndex >= 0, selectedIndex < state.faces.count {
            quickPersonFacePickContinuation?(state.faces[selectedIndex].embedding)
        } else {
            quickPersonFacePickContinuation?(nil)
        }
        quickPersonFacePickContinuation = nil
    }
}
