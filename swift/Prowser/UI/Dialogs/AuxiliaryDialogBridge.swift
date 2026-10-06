import SwiftUI

/// Keeps AppState dialog flags in sync with independent NSWindows (not SwiftUI sheets).
struct AuxiliaryDialogBridge: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear { appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.showKeyboardHelp) { _, _ in appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.showHiddenGemsHelp) { _, _ in appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.showConvertFormatSheet) { _, _ in appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.showResizeSheet) { _, _ in appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.renamePrefixDialog?.id) { _, _ in appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.showFindReferencesSheet) { _, _ in appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.showReferenceGraphSheet) { _, _ in appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.exifBatchConfirmation?.id) { _, _ in appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.showFilterDialog) { _, _ in appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.showMoveWorkFilesSheet) { _, _ in appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.showEditUserCommentSheet) { _, _ in appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.showSimilaritySearchSheet) { _, _ in appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.showClipSearchSheet) { _, _ in appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.showPersonSearchSheet) { _, _ in appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.personSearchSheetWindowTitle) { _, _ in appState.syncAuxiliaryDialogs() }
            .onChange(of: appState.showImageRecognitionCaveats) { _, _ in appState.syncAuxiliaryDialogs() }
    }
}
