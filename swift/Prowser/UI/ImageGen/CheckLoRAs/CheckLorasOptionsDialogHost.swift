import SwiftUI

@MainActor
struct CheckLorasOptionsDialogHost: View {
    @Environment(AppState.self) private var appState
    @Environment(\.closeDialog) private var closeDialog
    let prescan: CheckLorasPrescanResult
    @State private var options: CheckLorasOptions

    init(prescan: CheckLorasPrescanResult, initialOptions: CheckLorasOptions) {
        self.prescan = prescan
        _options = State(initialValue: initialOptions)
    }

    var body: some View {
        CheckLorasOptionsView(
            choices: prescan.choices,
            installedModels: prescan.installedModels,
            options: $options,
            appConfig: appState.config,
            loraBridge: appState.workers.lora,
            onCancel: { closeDialog() },
            onRun: { committed in
                appState.checkLorasFlow.pendingRun = CheckLorasFlowState.PendingRun(
                    prescan: prescan,
                    options: committed
                )
                closeDialog()
            },
            onShowPreviousReport: {
                CheckLorasController.showPreviousReport(from: appState)
            }
        )
        .themeDialogStyle()
        .persistedDialogGeometry(
            DialogGeometryKey.checkLorasOptions,
            defaultWidth: 520,
            defaultHeight: 620,
            minWidth: 480,
            minHeight: 400
        )
    }
}
