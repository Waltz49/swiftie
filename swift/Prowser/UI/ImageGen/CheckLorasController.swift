import SwiftUI

@MainActor
enum CheckLorasController {
    static func present(from appState: AppState) {
        guard appState.workers.lora.isAvailable else {
            StyledMessageDialog.showWarning(
                title: "Check LoRAs",
                message: "Image generation Python environment is not ready."
            )
            return
        }
        if appState.workers.modelTasks.isBusy {
            StyledMessageDialog.showWarning(
                title: "Check LoRAs",
                message: "Wait for the current generation job to finish."
            )
            return
        }
        Task { await begin(from: appState) }
    }

    private static func begin(from appState: AppState) async {
        let bridge = appState.workers.lora
        do {
            let prescan = try await bridge.checkLorasPrescan()
            if prescan.installedModels.isEmpty {
                StyledMessageDialog.showWarning(
                    title: "Check LoRAs",
                    message:
                        "No installed base models were found to probe LoRAs against.\n\n"
                        + "Install at least one image-generation base model, then run Check LoRAs again."
                )
                return
            }
            appState.checkLorasFlow.optionsPrescan = prescan
            appState.syncAuxiliaryDialogs()
        } catch {
            StyledMessageDialog.showWarning(
                title: "Check LoRAs",
                message: error.localizedDescription
            )
        }
    }

    static func executeRun(
        appState: AppState,
        prescan: CheckLorasPrescanResult,
        options: CheckLorasOptions
    ) async {
        let bridge = appState.workers.lora
        do {
            let preparing = CancellableProgressPanelController(
                title: "Check LoRAs — Preparing",
                labelText: "Building probe plan…",
                maximum: 1,
                indeterminate: true,
                showsTimeRemainingEstimate: false,
                throttleProgressUpdates: false
            )
            preparing.show()

            let prepareResult = try await bridge.checkLorasPrepare(options: options)
            preparing.close()

            if prepareResult.nothingToProbe {
                StyledMessageDialog.showInformation(
                    title: "Check LoRAs",
                    message: prepareResult.message
                        ?? "Nothing to probe with the current options."
                )
                return
            }

            let progress = CancellableProgressPanelController(
                title: "Check LoRAs",
                labelText: "Starting…",
                maximum: 100,
                showsTimeRemainingEstimate: true,
                throttleProgressUpdates: false
            )
            progress.onCancel = {
                Task { try? await bridge.checkLorasCancel() }
            }
            progress.show()

            let runResult: CheckLorasRunResult
            do {
                runResult = try await bridge.checkLorasRun(options: options) { message in
                    let (done, total) = CheckLorasProgressFormatter.progressValue(message: message)
                    let label = CheckLorasProgressFormatter.statusText(
                        message: message,
                        elapsed: 0,
                        eta: nil
                    )
                    progress.setMaximum(max(1, total))
                    progress.update(value: done, label: label)
                }
            } catch {
                progress.close()
                throw error
            }
            progress.close()

            NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)

            let body = CheckLorasResultsDialog.resolvedBody(
                resultsText: runResult.resultsText,
                reportPaths: runResult.reportPaths
            )
            var banner: String?
            if runResult.cancelled {
                if runResult.probesDone == 0 {
                    StyledMessageDialog.showInformation(
                        title: "Check LoRAs — Cancelled",
                        message: "Check LoRAs was cancelled.\n\nNo probes were completed."
                    )
                    return
                }
                banner = "Check LoRAs was cancelled. Partial results from completed probes were saved."
            }

            appState.checkLorasFlow.results = CheckLorasFlowState.ResultsPresentation(
                body: body,
                cancelledBanner: banner
            )
            appState.syncAuxiliaryDialogs()
        } catch {
            StyledMessageDialog.showWarning(
                title: "Check LoRAs",
                message: error.localizedDescription
            )
        }
    }
}
