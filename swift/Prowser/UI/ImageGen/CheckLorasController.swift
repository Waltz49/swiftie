import SwiftUI

@MainActor
enum CheckLorasController {
    static func present(from appState: AppState) {
        if appState.workers.modelTasks.isBusy {
            StyledMessageDialog.showWarning(
                title: "Test LoRAs",
                message: "Wait for the current generation job to finish."
            )
            return
        }
        Task { await begin(from: appState) }
    }

    private static func begin(from appState: AppState) async {
        let bridge = appState.workers.lora
        guard bridge.pythonOpsAvailable else {
            StyledMessageDialog.showWarning(
                title: "Test LoRAs",
                message: "Image generation Python environment is not ready."
            )
            return
        }
        do {
            let prescan = try await bridge.checkLorasPrescan()
            if prescan.installedModels.isEmpty {
                StyledMessageDialog.showWarning(
                    title: "Test LoRAs",
                    message:
                        "No installed base models were found to probe LoRAs against.\n\n"
                        + "Install at least one image-generation base model, then run Test LoRAs again."
                )
                return
            }
            appState.checkLorasFlow.optionsPrescan = prescan
            appState.syncAuxiliaryDialogs()
        } catch {
            StyledMessageDialog.showWarning(
                title: "Test LoRAs",
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
                title: "Test LoRAs — Preparing",
                labelText: "Building probe plan…",
                maximum: 1,
                indeterminate: true,
                showsTimeRemainingEstimate: false,
                throttleProgressUpdates: false
            )
            preparing.onCancel = {
                Task { try? await bridge.checkLorasCancel() }
            }
            preparing.show()

            let prepareResult = try await bridge.checkLorasPrepare(options: options)
            preparing.close()

            if prepareResult.cancelled || preparing.cancelRequested {
                StyledMessageDialog.showInformation(
                    title: "Test LoRAs — Cancelled",
                    message: "Test LoRAs was cancelled.\n\nNo probes were completed."
                )
                return
            }

            if prepareResult.nothingToProbe {
                StyledMessageDialog.showInformation(
                    title: "Test LoRAs",
                    message: prepareResult.message
                        ?? "Nothing to probe with the current options."
                )
                return
            }

            let progress = CancellableProgressPanelController(
                title: "Test LoRAs",
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
                        title: "Test LoRAs — Cancelled",
                        message: "Test LoRAs was cancelled.\n\nNo probes were completed."
                    )
                    return
                }
                banner = "Test LoRAs was cancelled. Partial results from completed probes were saved."
            }

            appState.checkLorasFlow.results = CheckLorasFlowState.ResultsPresentation(
                body: body,
                cancelledBanner: banner
            )
            appState.syncAuxiliaryDialogs()
        } catch {
            StyledMessageDialog.showWarning(
                title: "Test LoRAs",
                message: error.localizedDescription
            )
        }
    }
}
