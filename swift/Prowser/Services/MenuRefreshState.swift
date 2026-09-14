import Foundation

/// Dynamic menu enable/visibility flags (Python `menu_manager.py` `aboutToShow` handlers).
@MainActor
@Observable
final class MenuRefreshState {
    private weak var appState: AppState?

    var canViewTrash = false
    var moveWorkFilesVisible = false
    var deleteExifDateEnabled = false
    var deleteExifDateTitle = "Delete EXIF Date from File…"
    var destinationsMenuVisible = true

    func bind(_ appState: AppState) {
        self.appState = appState
        refreshAll()
    }

    func refreshAll() {
        guard let appState else { return }
        canViewTrash = TrashDirectoryService.hasReadableTrashWithImages(
            extensions: appState.config.imageExtensions
        )
        moveWorkFilesVisible = MoveWorkFilesService.canMoveWorkFiles(
            currentDirectory: appState.fileData.currentDirectory
        )
        destinationsMenuVisible = appState.config.string(
            forKey: "destination_menu_action",
            default: "move"
        ) != "none"
        refreshDeleteExifDate(appState: appState)
    }

    func refreshDeleteExifDate(appState: AppState) {
        guard appState.fileData.currentViewMode == .thumbnail, !appState.specificFilesActive else {
            deleteExifDateEnabled = false
            deleteExifDateTitle = "Delete EXIF Date from File…"
            return
        }
        let paths = SelectionService.selectedFilesOrCurrent(appState: appState)
        let withExif = paths.filter { ExifService.exifTimestamp(path: $0) != nil }
        deleteExifDateEnabled = !withExif.isEmpty
        deleteExifDateTitle = withExif.count > 1
            ? "Delete EXIF Dates from Files…"
            : "Delete EXIF Date from File…"
    }
}
