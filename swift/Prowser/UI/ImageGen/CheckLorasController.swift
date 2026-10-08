import AppKit
import SwiftUI

@MainActor
enum CheckLorasController {
    private static var worker: PythonNDJSONWorker?
    private static var progressWindow: NSWindow?

    static func present(from appState: AppState) {
        guard appState.workers.lora.isAvailable else {
            showAlert(title: "Check LoRAs", message: "Image generation Python environment is not ready.")
            return
        }
        if appState.workers.modelTasks.isBusy {
            showAlert(title: "Check LoRAs", message: "Wait for the current generation job to finish.")
            return
        }
        Task { await runFlow(appState: appState) }
    }

    private static func runFlow(appState: AppState) async {
        guard let environment = PythonLocator.resolve(profilePath: nil, config: appState.config) else { return }
        let script = checkLorasScriptURL(bundleRoot: environment.bundleRoot)
        let bridge = PythonNDJSONWorker(scriptURL: script)
        worker = bridge
        await bridge.bind(environment: environment)
        do {
            let prescan = try await bridge.send(["command": "prescan"])
            let installed = prescan["installed_models"] as? [String] ?? []
            if installed.isEmpty {
                showAlert(
                    title: "Check LoRAs",
                    message: "No installed base models were found to probe LoRAs against.\n\nInstall at least one image-generation base model, then run Check LoRAs again."
                )
                await bridge.shutdown()
                worker = nil
                return
            }
            let choices = prescan["choices"] as? [[String: Any]] ?? []
            guard let options = await CheckLorasOptionsSheet.present(choices: choices, installedModels: installed) else {
                await bridge.shutdown()
                worker = nil
                return
            }
            _ = try await bridge.send(["command": "prepare", "options": options])
            let progress = CheckLorasProgressWindow()
            progressWindow = progress.show()
            let result = try await bridge.send(
                ["command": "run", "options": options],
                awaitFinalResult: true,
                onProgress: { message in
                    Task { @MainActor in
                        progress.update(message: message)
                    }
                }
            )
            progressWindow?.close()
            progressWindow = nil
            await bridge.shutdown()
            worker = nil
            NotificationCenter.default.post(name: .prowserLoraCatalogChanged, object: nil)
            showResults(result)
        } catch {
            progressWindow?.close()
            progressWindow = nil
            await bridge.shutdown()
            worker = nil
            showAlert(title: "Check LoRAs", message: error.localizedDescription)
        }
    }

    static func cancelActiveRun() {
        Task {
            try? await worker?.send(["command": "cancel"])
        }
    }

    private static func checkLorasScriptURL(bundleRoot: URL) -> URL {
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("run_check_loras_worker.py"),
           FileManager.default.isReadableFile(atPath: resource.path) {
            return resource
        }
        return bundleRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Scripts/run_check_loras_worker.py")
    }

    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private static func showResults(_ result: [String: Any]) {
        let passed = result["passed"] as? Int ?? 0
        let failed = result["failed"] as? Int ?? 0
        let skipped = result["skipped"] as? Int ?? 0
        let cancelled = result["cancelled"] as? Bool ?? false
        var text = cancelled ? "Check LoRAs was cancelled.\n\n" : "Check LoRAs finished.\n\n"
        text += "Passed: \(passed), failed: \(failed), skipped: \(skipped)."
        if let changes = result["changes"] as? [[String: Any]], !changes.isEmpty {
            text += "\n\nChanges:\n"
            for change in changes.prefix(20) {
                let label = change["lora_label"] as? String ?? ""
                let kind = change["kind"] as? String ?? ""
                text += "• \(kind): \(label)\n"
            }
        }
        showAlert(title: "Check LoRAs — Results", message: text)
    }
}

@MainActor
struct CheckLorasOptionsSheet {
    static func present(choices: [[String: Any]], installedModels: [String]) async -> [String: Any]? {
        await withCheckedContinuation { continuation in
            let panel = NSAlert()
            panel.messageText = "Check LoRAs — Options"
            panel.informativeText = "Found \(choices.count) LoRA weight file(s). Run compatibility probes on installed models?"
            panel.addButton(withTitle: "Run")
            panel.addButton(withTitle: "Cancel")
            if panel.runModal() == .alertFirstButtonReturn {
                continuation.resume(returning: [
                    "model_scope": "all",
                    "lora_scope": "all",
                    "registration_mode": "ignore_previous",
                    "probe_prompt": "test",
                    "skip_unchanged": true,
                    "check_cross_families": true,
                    "selected_model_keys": installedModels,
                    "selected_lora_keys": choices.compactMap { $0["key"] as? String },
                ])
            } else {
                continuation.resume(returning: nil)
            }
        }
    }
}

@MainActor
final class CheckLorasProgressWindow: NSObject {
    override init() {
        super.init()
    }

    private var window: NSWindow?
    private var statusLabel: NSTextField?
    private var progress: NSProgressIndicator?

    func show() -> NSWindow {
        let status = NSTextField(labelWithString: "Starting…")
        status.lineBreakMode = .byWordWrapping
        status.maximumNumberOfLines = 4
        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.target = self
        cancel.action = #selector(cancelTapped)
        let stack = NSStackView(views: [status, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.required, for: .vertical)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 120))
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: host.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16),
        ])
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 140),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Check LoRAs"
        win.contentView = host
        win.center()
        win.makeKeyAndOrderFront(nil)
        statusLabel = status
        progress = bar
        window = win
        return win
    }

    func update(message: [String: Any]) {
        guard let stats = message["stats"] as? [String: Any] else { return }
        let activity = stats["probe_activity"] as? String ?? ""
        let label = stats["current_lora_label"] as? String ?? ""
        statusLabel?.stringValue = [activity, label].filter { !$0.isEmpty }.joined(separator: " — ")
        let done = (message["probe_index"] as? NSNumber)?.doubleValue ?? 0
        let total = max((message["probe_total"] as? NSNumber)?.doubleValue ?? 1, 1)
        progress?.doubleValue = (done / total) * 100
    }

    @objc private func cancelTapped() {
        CheckLorasController.cancelActiveRun()
    }
}
