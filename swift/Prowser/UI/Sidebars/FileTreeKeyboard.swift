import AppKit

/// Keyboard routing when the file tree outline is first responder (`files/file_tree_handler.py` CustomTreeView).
@MainActor
enum FileTreeKeyboard {
    private static let localKeyCodes: Set<UInt16> = [
        36, 76, // return, keypad enter
        123, 124, 125, 126, // arrows
        116, 121, // page up, page down
    ]

    static func handle(
        event: NSEvent,
        outlineView: FileTreeOutlineView,
        coordinator: FileTreeView.Coordinator,
        appState: AppState
    ) -> Bool {
        coordinator.markUserNavigatingTree()

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommand = flags.contains(.command)
        let hasShift = flags.contains(.shift)
        let hasOption = flags.contains(.option)
        let hasControl = flags.contains(.control)

        if event.keyCode == 48, !hasCommand { // Tab
            appState.focusMainCanvas()
            return true
        }

        if hasCommand, !hasShift, !hasOption, !hasControl,
           event.charactersIgnoringModifiers?.lowercased() == "c",
           let path = coordinator.selectedTreeRowPath() {
            appState.fileOperations.copyPathsToClipboard([path])
            return true
        }

        if hasCommand, !hasShift, !hasOption, !hasControl,
           event.charactersIgnoringModifiers?.lowercased() == "f",
           let path = coordinator.treeSearchScopeDirectoryPath() {
            if FileTreePathRestrictions.isRootOrSystemVolume(path) {
                showRestrictedAlert(path: path)
            } else {
                appState.searchOperations.presentClipSearchDialog(directoryOverride: path)
            }
            return true
        }

        if hasCommand, !hasShift, !hasOption, !hasControl,
           event.charactersIgnoringModifiers?.lowercased() == "p",
           FaceRecognitionCapabilities.facesUIEnabled(launchOptions: appState.launchOptions),
           let path = coordinator.treeSearchScopeDirectoryPath() {
            if FileTreePathRestrictions.isRootOrSystemVolume(path) {
                showRestrictedAlert(path: path)
            } else {
                appState.searchOperations.presentPersonSearchDialog(directoryOverride: path)
            }
            return true
        }

        if event.keyCode == 120, !hasCommand, !hasShift, !hasOption, !hasControl {
            coordinator.renameSelectedDirectory()
            return true
        }

        if hasShift, !hasCommand, !hasOption, !hasControl,
           event.charactersIgnoringModifiers?.lowercased() == "a",
           let path = coordinator.selectedDirectoryPath() {
            if FileTreePathRestrictions.isRootOrSystemVolume(path) {
                showRestrictedAlert(path: path)
            } else {
                appState.fileTreeOperations.showAllImages(in: path)
            }
            return true
        }

        if hasShift, !hasCommand, !hasOption, !hasControl,
           event.charactersIgnoringModifiers?.lowercased() == "f",
           let path = coordinator.selectedDirectoryPath() {
            if FileTreePathRestrictions.isRootOrSystemVolume(path) {
                showRestrictedAlert(path: path)
            } else {
                appState.fileTreeOperations.findDuplicateImages(in: path)
            }
            return true
        }

        if hasCommand, !hasOption, !hasControl,
           event.keyCode == 36 || event.keyCode == 76 {
            if hasShift {
                appState.collapseFileTree()
            } else {
                appState.expandFileTreeToCurrentDirectory()
            }
            return true
        }

        if (event.keyCode == 36 || event.keyCode == 76),
           !hasCommand, !hasShift, !hasOption, !hasControl {
            coordinator.openSelectedDirectoryFromReturn()
            return true
        }

        if event.keyCode == 49, !hasCommand, !hasShift, !hasOption, !hasControl {
            coordinator.toggleExpandSelectedDirectory()
            return true
        }

        if localKeyCodes.contains(event.keyCode), !hasCommand {
            return false
        }

        if appState.handleTreeForwardedKeyboard(event) {
            return true
        }

        return false
    }

    private static func showRestrictedAlert(path: String) {
        StyledMessageDialog.showWarning(
            title: "Action Not Available",
            message: FileTreePathRestrictions.restrictedActionMessage(for: path)
        )
    }
}
