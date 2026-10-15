import SwiftUI

@MainActor
enum CheckLorasController {
    // #region agent log
    private static func agentLog(
        hypothesisId: String,
        location: String,
        message: String,
        data: [String: String] = [:]
    ) {
        let path = "/Users/douglasnadel/dev/swiftie/.cursor/debug-f5adc1.log"
        let payload: [String: Any] = [
            "sessionId": "f5adc1",
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "data": data,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let json = try? JSONSerialization.data(withJSONObject: payload),
              let line = String(data: json, encoding: .utf8)
        else { return }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        if let bytes = (line + "\n").data(using: .utf8) {
            try? handle.write(contentsOf: bytes)
        }
    }
    // #endregion

    static func present(from appState: AppState) {
        // #region agent log
        agentLog(
            hypothesisId: "A",
            location: "CheckLorasController.present",
            message: "present called",
            data: [
                "modelTasksBusy": String(appState.workers.modelTasks.isBusy),
                "imageGenUI": String(BundleCapabilities.imageGenUIEnabled),
            ]
        )
        // #endregion
        if appState.workers.modelTasks.isBusy {
            // #region agent log
            agentLog(hypothesisId: "B", location: "CheckLorasController.present", message: "blocked: modelTasks busy")
            // #endregion
            StyledMessageDialog.showWarning(
                title: "Test LoRAs",
                message: "Wait for the current generation job to finish."
            )
            return
        }
        Task { await begin(from: appState) }
    }

    private static func begin(from appState: AppState) async {
        // #region agent log
        agentLog(hypothesisId: "A", location: "CheckLorasController.begin", message: "begin started")
        // #endregion
        let bridge = appState.workers.lora
        guard bridge.pythonOpsAvailable else {
            // #region agent log
            agentLog(hypothesisId: "C", location: "CheckLorasController.begin", message: "pythonOps unavailable")
            // #endregion
            StyledMessageDialog.showWarning(
                title: "Test LoRAs",
                message: "Image generation Python environment is not ready."
            )
            return
        }
        let prescanPanel = CancellableProgressPanelController(
            title: "Test LoRAs",
            labelText: "Scanning LoRA files…",
            maximum: 1,
            indeterminate: true,
            showsTimeRemainingEstimate: false,
            throttleProgressUpdates: false
        )
        prescanPanel.show()
        defer { prescanPanel.close() }
        do {
            // #region agent log
            agentLog(hypothesisId: "D", location: "CheckLorasController.begin", message: "prescan starting")
            // #endregion
            let prescan = try await bridge.checkLorasPrescan()
            // #region agent log
            agentLog(
                hypothesisId: "D",
                location: "CheckLorasController.begin",
                message: "prescan finished",
                data: [
                    "installedModels": String(prescan.installedModels.count),
                    "choices": String(prescan.choices.count),
                ]
            )
            // #endregion
            if prescan.installedModels.isEmpty {
                // #region agent log
                agentLog(hypothesisId: "C", location: "CheckLorasController.begin", message: "no installed models")
                // #endregion
                StyledMessageDialog.showWarning(
                    title: "Test LoRAs",
                    message:
                        "No installed base models were found to probe LoRAs against.\n\n"
                        + "Install at least one image-generation base model, then run Test LoRAs again."
                )
                return
            }
            appState.checkLorasFlow.optionsPrescan = prescan
            // #region agent log
            agentLog(
                hypothesisId: "E",
                location: "CheckLorasController.begin",
                message: "optionsPrescan set, syncing dialogs",
                data: ["hasPrescan": String(appState.checkLorasFlow.optionsPrescan != nil)]
            )
            // #endregion
            appState.syncAuxiliaryDialogs()
            // #region agent log
            agentLog(hypothesisId: "E", location: "CheckLorasController.begin", message: "syncAuxiliaryDialogs returned")
            // #endregion
        } catch {
            // #region agent log
            agentLog(
                hypothesisId: "D",
                location: "CheckLorasController.begin",
                message: "prescan error",
                data: ["error": error.localizedDescription]
            )
            // #endregion
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

            if !prepareResult.success {
                StyledMessageDialog.showWarning(
                    title: "Test LoRAs",
                    message: prepareResult.message ?? "Could not prepare Test LoRAs."
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

            let baseProbePrompt = CheckLorasOptions.normalizedProbePrompt(
                options.probePrompt.isEmpty
                    ? appState.config.checkLorasOptionsFromSettings().probePrompt
                    : options.probePrompt
            )
            let progress = CancellableProgressPanelController(
                title: "Test LoRAs",
                labelText: "Starting…",
                maximum: 100,
                showsTimeRemainingEstimate: false,
                throttleProgressUpdates: false,
                accessoryButtonTitle: "Work directory",
                promptAccessoryText: baseProbePrompt
            )
            progress.onCancel = {
                Task { try? await bridge.checkLorasCancel() }
            }
            progress.onAccessory = {
                appState.openProfileTemporaryWorkDirectoryInThumbnailView()
            }
            progress.setAccessoryButtonEnabled(
                CheckLorasWorkDirectory.containsWorkImages(config: appState.config)
            )
            progress.show()

            let runStart = Date()
            let gpuPhaseClock = GpuPhaseClock()

            var workDirectoryRefreshTimer: Timer?
            workDirectoryRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    progress.setAccessoryButtonEnabled(
                        CheckLorasWorkDirectory.containsWorkImages(config: appState.config)
                    )
                }
            }

            let runResult: CheckLorasRunResult
            do {
                runResult = try await bridge.checkLorasRun(options: options) { message in
                    let stats = message["stats"] as? [String: Any] ?? [:]
                    let gpuDone = (stats["gpu_probes_done"] as? NSNumber)?.intValue
                        ?? (stats["gpu_probes_done"] as? Int)
                        ?? 0
                    gpuPhaseClock.noteGPURenderIfNeeded(gpuDone: gpuDone)
                    let elapsed = Date().timeIntervalSince(runStart)
                    let gpuElapsed = gpuPhaseClock.gpuPhaseElapsed()
                    let eta = CheckLorasProgressFormatter.estimatedGPURemaining(
                        stats: stats,
                        gpuPhaseElapsed: gpuElapsed
                    )
                    let (done, total) = CheckLorasProgressFormatter.progressValue(message: message)
                    let label = CheckLorasProgressFormatter.statusText(
                        message: message,
                        elapsed: elapsed,
                        eta: eta
                    )
                    progress.setMaximum(max(1, total))
                    progress.update(value: done, label: label)
                }
            } catch {
                workDirectoryRefreshTimer?.invalidate()
                progress.close()
                throw error
            }
            workDirectoryRefreshTimer?.invalidate()
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

/// Thread-safe GPU-phase start for Check LoRAs ETA (`@Sendable` progress callbacks).
private final class GpuPhaseClock: @unchecked Sendable {
    private let lock = NSLock()
    private var start: Date?

    func noteGPURenderIfNeeded(gpuDone: Int) {
        lock.lock()
        defer { lock.unlock() }
        if gpuDone > 0, start == nil {
            start = Date()
        }
    }

    func gpuPhaseElapsed() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let start else { return nil }
        return Date().timeIntervalSince(start)
    }
}
