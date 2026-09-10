import AppKit
import SwiftUI

extension Notification.Name {
    static let prowserRaiseImageGenDialog = Notification.Name("prowser.raiseImageGenDialog")
}

@MainActor
struct ImageGenUnifiedDialog: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFunction = "create"
    @State private var pluginsByFunction: [String: [[String: Any]]] = [:]
    @State private var values: [String: Any] = [:]
    @State private var selectedPluginID = ""
    @State private var isLoading = true
    @State private var errorMessage = ""
    @State private var closeOnGenerate = false
    @State private var submitNotice = ""
    @State private var isDirty = false
    @State private var baselineValues: [String: Any] = [:]
    @State private var visitedFunctions: Set<String> = []
    private let functions = ["edit", "create", "expand", "infill"]
    private let session = ImageGenSessionState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isLoading {
                ProgressView("Loading models…")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ImageGenPanelShell(
                    function: selectedFunction,
                    values: $values,
                    plugins: pluginsByFunction[selectedFunction] ?? [],
                    selectedPluginID: $selectedPluginID,
                    sourcePaths: editSourcePaths,
                    sourcePath: activeImagePath,
                    onValuesChanged: { markDirtyIfNeeded() }
                )
            }
            if !submitNotice.isEmpty {
                Text(submitNotice).font(.caption).foregroundStyle(.secondary)
            }
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            footer
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 560)
        .background(
            ImageGenDialogKeyHandler(
                onCommandLeft: { cycleFunction(delta: -1) },
                onCommandRight: { cycleFunction(delta: 1) },
                onCommandReturn: { Task { await primarySubmit() } },
                onCommandW: { performClose() },
                onOptionReturn: { false },
                onShiftOptionReturn: { false }
            )
        )
        .background(ImageGenUnifiedWindowConfigurator(title: titleText))
        .task { await loadDialog() }
        .onChange(of: appState.imageGenDialogReloadToken) { _, _ in
            Task { await loadDialog() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserRaiseImageGenDialog)) { _ in
            raiseWindow()
        }
        .onDisappear {
            appState.closeImageGenUnifiedDialog()
        }
        .onExitCommand { performClose() }
    }

    private var header: some View {
        HStack {
            Text(titleText)
                .font(.headline)
            Spacer()
        }
    }

    private var titleText: String {
        switch selectedFunction {
        case "create": return "Create an image from text"
        case "edit": return "Edit image with AI"
        case "expand": return "Expand image"
        case "infill": return "Infill / paint"
        default: return "Image generation"
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            ImageGenFunctionSwitcher(
                selectedFunction: $selectedFunction,
                availableFunctions: functions.filter { !(pluginsByFunction[$0] ?? []).isEmpty }
            )
            .onChange(of: selectedFunction) { oldValue, newValue in
                guard oldValue != newValue else { return }
                Task { await switchFunction(from: oldValue, to: newValue) }
            }

            Spacer()

            Toggle("Close dialog on generate", isOn: $closeOnGenerate)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: closeOnGenerate) { _, enabled in
                    ImageGenPersistence.setCloseDialogOnGenerate(enabled, config: appState.config)
                }

            Spacer()

            if isDirty {
                Button("Cancel") { performCancel() }
                    .help("Discard changes and close.")
            }
            Button("Close") { performClose() }
                .keyboardShortcut("w", modifiers: [.command])
            if showReplaceUpdate {
                Button(replaceUpdateLabel) { Task { await submit(replace: true) } }
                    .keyboardShortcut(.return, modifiers: [.command])
            }
            Button(primaryLabel) { Task { await submit(replace: false) } }
                .keyboardShortcut(.return, modifiers: showReplaceUpdate ? [] : [.command])
        }
    }

    private var request: ImageGenDialogRequest {
        appState.imageGenDialogRequest
    }

    private var replaceJobID: String? { request.replaceJobID }

    private var showReplaceUpdate: Bool {
        guard let replaceJobID else { return false }
        return appState.imageGen.isQueuedJobReplaceable(jobID: replaceJobID)
            || appState.imageGen.isActiveJobRemainingUpdatable(jobID: replaceJobID)
    }

    private var replaceUpdateLabel: String {
        guard let replaceJobID else { return "Update" }
        return appState.imageGen.isActiveJobRemainingUpdatable(jobID: replaceJobID) ? "Update" : "Replace"
    }

    private var primaryLabel: String { "Generate" }

    private var activeImagePath: String? {
        appState.fileData.currentImagePath
    }

    private var editSourcePaths: [String] {
        if !request.editSourcePaths.isEmpty { return request.editSourcePaths }
        if let path = activeImagePath { return [path] }
        return []
    }

    private func loadDialog() async {
        appState.imageGen.beginImageGenDialogBuild()
        defer { appState.imageGen.endImageGenDialogBuild() }
        closeOnGenerate = ImageGenPersistence.closeDialogOnGenerate(config: appState.config)
        selectedFunction = request.function.isEmpty ? session.lastFunction(config: appState.config) : request.function
        isLoading = true
        errorMessage = ""
        do {
            for function in functions {
                let plugins = try await appState.workers.imageGenRegistry.listPlugins(function: function)
                pluginsByFunction[function] = plugins
            }
            if let replaceJobID, let job = appState.imageGen.queue.jobs.first(where: { $0.jobID == replaceJobID }) {
                selectedFunction = job.function
                selectedPluginID = job.pluginID
                values = job.values
                baselineValues = job.values
                visitedFunctions.insert(selectedFunction)
            } else {
                await switchFunction(from: "", to: selectedFunction)
                if let prompt = request.initialPrompt, !prompt.isEmpty {
                    values["prompt"] = prompt
                }
            }
            isDirty = false
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func switchFunction(from oldFunction: String, to newFunction: String) async {
        if !oldFunction.isEmpty {
            session.setValues(values, for: oldFunction)
            session.setPluginID(selectedPluginID, for: oldFunction)
        }

        selectedFunction = newFunction
        session.saveLastFunction(newFunction, config: appState.config)
        visitedFunctions.insert(newFunction)

        let plugins = pluginsByFunction[newFunction] ?? []
        if let savedID = session.pluginID(for: newFunction),
           plugins.contains(where: { ($0["plugin_id"] as? String) == savedID }) {
            selectedPluginID = savedID
        } else if let first = plugins.first {
            selectedPluginID = first["plugin_id"] as? String ?? ""
        }

        let savedValues = session.values(for: newFunction)
        if !savedValues.isEmpty {
            values = savedValues
        } else if let plugin = plugins.first(where: { ($0["plugin_id"] as? String) == selectedPluginID }),
                  let defaults = plugin["merged_defaults"] as? [String: Any] {
            values = defaults
            if let prompt = values["prompt"] as? String, prompt.isEmpty,
               let initial = request.initialPrompt {
                values["prompt"] = initial
            }
        }

        baselineValues = values
        isDirty = false
    }

    private func cycleFunction(delta: Int) {
        let available = functions.filter { !(pluginsByFunction[$0] ?? []).isEmpty }
        guard !available.isEmpty else { return }
        guard let index = available.firstIndex(of: selectedFunction) else { return }
        let next = available[(index + delta + available.count) % available.count]
        let previous = selectedFunction
        selectedFunction = next
        Task { await switchFunction(from: previous, to: next) }
    }

    private func markDirtyIfNeeded() {
        isDirty = !ImageGenPersistence.snapshotsEqual(values, baselineValues)
    }

    private func performClose() {
        if replaceJobID != nil {
            performCancel()
            return
        }
        session.setValues(values, for: selectedFunction)
        session.setPluginID(selectedPluginID, for: selectedFunction)
        closeDialog()
    }

    private func performCancel() {
        if isDirty {
            session.setValues(baselineValues, for: selectedFunction)
        } else {
            session.setValues(values, for: selectedFunction)
            session.setPluginID(selectedPluginID, for: selectedFunction)
        }
        closeDialog()
    }

    private func closeDialog() {
        appState.closeImageGenUnifiedDialog()
        dismiss()
    }

    private func raiseWindow() {
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: {
                $0.identifier?.rawValue == ImageGenUnifiedWindowConfigurator.windowIdentifier
            }) else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func primarySubmit() async {
        if showReplaceUpdate {
            await submit(replace: true)
        } else {
            await submit(replace: false)
        }
    }

    private func submit(replace: Bool) async {
        errorMessage = ""
        let copies = JobStepQueue.normalizeCopies(values["copies"] ?? 1)
        var submitValues = values
        submitValues["copies"] = copies
        do {
            if replace, let replaceJobID {
                if appState.imageGen.isActiveJobRemainingUpdatable(jobID: replaceJobID) {
                    try await appState.imageGen.updateActiveJobRemaining(
                        jobID: replaceJobID,
                        pluginID: selectedPluginID,
                        values: submitValues
                    )
                    submitNotice = "Job updated."
                } else {
                    try await appState.imageGen.replaceQueuedJob(
                        jobID: replaceJobID,
                        pluginID: selectedPluginID,
                        function: selectedFunction,
                        values: submitValues
                    )
                    submitNotice = "Job replaced."
                }
            } else {
                try await appState.imageGen.enqueueGeneration(
                    pluginID: selectedPluginID,
                    function: selectedFunction,
                    values: submitValues,
                    copies: copies
                )
                submitNotice = "Job submitted."
            }
            session.setValues(submitValues, for: selectedFunction)
            session.setPluginID(selectedPluginID, for: selectedFunction)
            baselineValues = submitValues
            isDirty = false
            if closeOnGenerate {
                closeDialog()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ImageGenUnifiedWindowConfigurator: NSViewRepresentable {
    static let windowIdentifier = "imagegen-unified"

    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.title = title
        window.isReleasedWhenClosed = false
    }
}
