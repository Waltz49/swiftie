import AppKit
import SwiftUI

extension Notification.Name {
    static let prowserRaiseImageGenDialog = Notification.Name("prowser.raiseImageGenDialog")
}

@MainActor
struct ImageGenUnifiedDialog: View {
    static let windowIdentifier = "imagegen-unified"

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
    @State private var pluginSwitchGuard = false
    @State private var suppressCloseOnGeneratePersist = false
    @State private var loadGeneration = 0
    /// Frozen edit sources while the dialog is open (Python ``_edit_source_paths_override``).
    @State private var lockedEditSourcePaths: [String] = []
    private let functions = ["edit", "create", "expand", "infill"]
    private let session = ImageGenSessionState()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                ProgressView("Loading models…")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ImageGenPanelShell(
                    function: selectedFunction,
                    values: $values,
                    plugins: pluginsByFunction[selectedFunction] ?? [],
                    selectedPluginID: $selectedPluginID,
                    sourcePaths: selectedFunction == "edit" ? lockedEditSourcePaths : [],
                    sourcePath: panelSourcePath,
                    onValuesChanged: { markDirtyIfNeeded() },
                    onEditSourcePathsChanged: selectedFunction == "edit" ? { paths in
                        lockedEditSourcePaths = paths
                        appState.imageGenDialogRequest.editSourcePaths = paths
                    } : nil,
                    compactSliderTracks: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onChange(of: selectedPluginID) { oldValue, newValue in
                    guard !pluginSwitchGuard, !isLoading, !oldValue.isEmpty, oldValue != newValue else { return }
                    switchPlugin(from: oldValue, to: newValue)
                }
            }
            if !submitNotice.isEmpty {
                Text(submitNotice).font(.caption).foregroundStyle(.secondary)
            }
            if !errorMessage.isEmpty {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            footer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 880, minHeight: 560)
        .background(
            ImageGenDialogKeyHandler(
                windowIdentifier: Self.windowIdentifier,
                onCommandLeft: { cycleFunction(delta: -1) },
                onCommandRight: { cycleFunction(delta: 1) },
                onCommandReturn: { Task { await primarySubmit() } },
                onCommandW: { performClose() },
                onEscape: { performClose() },
                onOptionReturn: { false },
                onShiftOptionReturn: { false }
            )
        )
        .persistedDialogGeometry(
            DialogGeometryKey.imageGenDialog,
            defaultWidth: 880,
            defaultHeight: 560,
            minWidth: 720,
            minHeight: 420,
            nestedInImageGen: true,
            windowIdentifier: ImageGenUnifiedDialog.windowIdentifier,
            windowTitle: titleText
        )
        .task { await loadDialog() }
        .onChange(of: appState.imageGenDialogReloadToken) { _, _ in
            Task { await loadDialog() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserRaiseImageGenDialog)) { _ in
            raiseWindow()
        }
        .background {
            SceneWindowLifecycleBridge(windowIdentifier: Self.windowIdentifier) {
                appState.closeImageGenUnifiedDialog()
            }
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
                .help(
                    "When checked, close this dialog after a job is submitted successfully. "
                    + "When unchecked, keep the dialog open and show a brief confirmation."
                )
                .onChange(of: closeOnGenerate) { _, enabled in
                    guard !suppressCloseOnGeneratePersist else { return }
                    ImageGenPersistence.setCloseDialogOnGenerate(enabled, config: appState.config)
                }

            Spacer()

            DialogButtonRow(footerActionButtons, layout: .inline)
        }
    }

    private var footerActionButtons: [DialogButton] {
        var buttons: [DialogButton] = []
        if isDirty {
            buttons.append(
                DialogButton("Cancel", isCancel: true, help: "Discard changes and close.") {
                    performCancel()
                }
            )
        }
        buttons.append(
            DialogButton("Close", help: "Close this dialog (⌘W).") {
                performClose()
            }
        )
        if showReplaceUpdate {
            buttons.append(
                DialogButton(replaceUpdateLabel, id: "replace", help: replaceUpdateHelp) {
                    Task { await submit(replace: true) }
                }
            )
        }
        buttons.append(
            DialogButton(
                primaryLabel,
                id: "primary",
                isDefault: true,
                help: "Start making the image\nwith these settings.\nAlso saves settings to the EXIF user comment."
            ) {
                Task { await submit(replace: false) }
            }
        )
        return buttons
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
        guard let replaceJobID else { return "Update ⌘↩" }
        let base = appState.imageGen.isActiveJobRemainingUpdatable(jobID: replaceJobID) ? "Update" : "Replace"
        return "\(base) ⌘↩"
    }

    private var replaceUpdateHelp: String {
        guard let replaceJobID else {
            return "Update this queued job with the current settings (does not add a new job)."
        }
        if appState.imageGen.isActiveJobRemainingUpdatable(jobID: replaceJobID) {
            return "Update this job with the current settings "
                + "(does not affect the copy in progress). "
                + "Copies is the number of images still to run, including the in-flight copy."
        }
        return "Update this queued job with the current settings (does not add a new job)."
    }

    private var primaryLabel: String {
        showReplaceUpdate ? "Generate" : "Generate ⌘↩"
    }

    private var activeImagePath: String? {
        appState.fileData.currentImagePath
    }

    private var panelSourcePath: String? {
        if selectedFunction == "edit" {
            return values["source_image_path"] as? String ?? lockedEditSourcePaths.first
        }
        return activeImagePath
    }

    private func resolveInitialEditSourcePaths(from request: ImageGenDialogRequest) -> [String] {
        if !request.editSourcePaths.isEmpty {
            return ImageGenEditSourcePaths.normalizedPaths(request.editSourcePaths)
        }
        let active = ImageGenEditSourcePaths.activeImagePathsForEdit(appState: appState)
        if !active.isEmpty { return active }
        if let path = activeImagePath {
            return ImageGenEditSourcePaths.normalizedPaths([path])
        }
        return []
    }

    /// Snapshot edit sources when opening or switching to edit; ignore live thumbnail selection afterward.
    /// Python ``_resolve_edit_source_paths``: explicit override, else the active image(s). Persisted
    /// ``source_image_paths`` from an earlier session are never used as sources.
    private func bootstrapEditSourcePaths(from request: ImageGenDialogRequest, force: Bool = false) {
        guard selectedFunction == "edit" else { return }
        if force || lockedEditSourcePaths.isEmpty {
            if !request.editSourcePaths.isEmpty {
                lockedEditSourcePaths = ImageGenEditSourcePaths.normalizedPaths(request.editSourcePaths)
            } else {
                lockedEditSourcePaths = resolveInitialEditSourcePaths(from: request)
            }
        }

        guard !lockedEditSourcePaths.isEmpty else { return }
        appState.imageGenDialogRequest.editSourcePaths = lockedEditSourcePaths
        values["source_image_paths"] = lockedEditSourcePaths
        values["source_image_path"] = lockedEditSourcePaths[0]
    }

    private func loadDialog() async {
        loadGeneration += 1
        let generation = loadGeneration
        let pendingAutoGenerate = request.autoGenerate
        let pendingRequest = request
        appState.imageGen.beginImageGenDialogBuild()
        defer { appState.imageGen.endImageGenDialogBuild() }
        closeOnGenerate = ImageGenPersistence.closeDialogOnGenerate(config: appState.config)
        selectedFunction = pendingRequest.function.isEmpty ? session.lastFunction(config: appState.config) : pendingRequest.function
        if pendingRequest.replaceJobID == nil {
            session.reset()
        }
        isLoading = true
        errorMessage = ""
        do {
            for function in functions {
                let saved = ImageGenPersistence.loadDialogSettings(
                    function: function,
                    config: appState.config
                )
                let plugins = try await appState.workers.imageGenRegistry.listPlugins(
                    function: function,
                    savedValues: saved.isEmpty ? nil : saved
                )
                pluginsByFunction[function] = plugins
            }
            if let replaceJobID = pendingRequest.replaceJobID,
               let job = appState.imageGen.queue.jobs.first(where: { $0.jobID == replaceJobID }) {
                selectedFunction = job.function
                selectedPluginID = job.pluginID
                values = job.values
                baselineValues = job.values
                visitedFunctions.insert(selectedFunction)
                if selectedFunction == "edit",
                   let paths = job.values["source_image_paths"] as? [String] {
                    lockedEditSourcePaths = ImageGenEditSourcePaths.normalizedPaths(paths)
                    appState.imageGenDialogRequest.editSourcePaths = lockedEditSourcePaths
                }
            } else {
                // Each open request re-resolves edit sources (Python builds a fresh dialog per open):
                // explicit paths from the caller, else the active image(s).
                lockedEditSourcePaths = ImageGenEditSourcePaths.normalizedPaths(pendingRequest.editSourcePaths)
                await switchFunction(from: "", to: selectedFunction)
                bootstrapEditSourcePaths(from: pendingRequest, force: true)
                if let prompt = pendingRequest.initialPrompt {
                    // Python ``_dialog_initial_prompt_from_user_comment``: an empty comment clears the prompt.
                    values["prompt"] = prompt.isEmpty ? "" : (ExifService.initialPromptFromUserComment(prompt) ?? prompt)
                }
                if pendingRequest.autoImportEXIF {
                    await applyAutoImportEXIF()
                }
            }
            isDirty = false
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        guard generation == loadGeneration else { return }
        if pendingAutoGenerate, errorMessage.isEmpty, replaceJobID == nil {
            appState.imageGenDialogRequest.autoGenerate = false
            scheduleAutoGenerate()
        }
    }

    /// Match Python ``ImageGenUnifiedDialog._schedule_auto_generate`` (next event-loop turn).
    private func scheduleAutoGenerate() {
        suppressCloseOnGeneratePersist = true
        closeOnGenerate = true
        suppressCloseOnGeneratePersist = false
        let generation = loadGeneration
        Task { @MainActor in
            await Task.yield()
            guard generation == loadGeneration else { return }
            guard errorMessage.isEmpty, replaceJobID == nil else { return }
            guard !selectedPluginID.isEmpty else { return }
            let prompt = (values["prompt"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { return }
            await submit(replace: false)
        }
    }

    private func switchFunction(from oldFunction: String, to newFunction: String) async {
        if !oldFunction.isEmpty {
            persistCurrentFunction(oldFunction)
            session.setValues(values, for: oldFunction)
            session.setPluginID(selectedPluginID, for: oldFunction)
        }

        selectedFunction = newFunction
        session.saveLastFunction(newFunction, config: appState.config)
        visitedFunctions.insert(newFunction)

        let plugins = pluginsByFunction[newFunction] ?? []
        let pluginIDs = plugins.compactMap { $0["plugin_id"] as? String }
        pluginSwitchGuard = true
        if let savedID = session.pluginID(for: newFunction),
           pluginIDs.contains(savedID) {
            selectedPluginID = savedID
        } else if let activeID = ImageGenPersistence.loadActivePluginID(
            function: newFunction,
            availablePluginIDs: pluginIDs,
            config: appState.config
        ) {
            selectedPluginID = activeID
        } else if let first = plugins.first {
            selectedPluginID = first["plugin_id"] as? String ?? ""
        }
        pluginSwitchGuard = false

        let sessionValues = session.values(for: newFunction)
        if !sessionValues.isEmpty {
            values = sessionValues
        } else {
            let persisted = ImageGenPersistence.loadPluginDialogSettings(
                function: newFunction,
                pluginID: selectedPluginID,
                config: appState.config
            )
            if !persisted.isEmpty {
                values = persisted
            } else if let plugin = plugins.first(where: { ($0["plugin_id"] as? String) == selectedPluginID }),
                      let defaults = plugin["merged_defaults"] as? [String: Any] {
                values = defaults
            }
        }

        if let prompt = request.initialPrompt, !prompt.isEmpty,
           (values["prompt"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values["prompt"] = ExifService.initialPromptFromUserComment(prompt) ?? prompt
        }

        if newFunction == "edit" {
            bootstrapEditSourcePaths(from: request)
        } else if oldFunction == "edit", !lockedEditSourcePaths.isEmpty {
            values["source_image_paths"] = lockedEditSourcePaths
            values["source_image_path"] = values["source_image_path"] as? String ?? lockedEditSourcePaths[0]
        }

        baselineValues = values
        isDirty = false
    }

    private func switchPlugin(from oldPluginID: String, to newPluginID: String) {
        let preservedPrompt = values["prompt"] as? String ?? ""
        values = ImageGenPersistence.switchPluginPreservingPrompt(
            function: selectedFunction,
            outgoingPluginID: oldPluginID,
            outgoingValues: values,
            incomingPluginID: newPluginID,
            preservedPrompt: preservedPrompt,
            editingQueueJob: replaceJobID != nil,
            config: appState.config
        )
        if selectedFunction == "edit", !lockedEditSourcePaths.isEmpty {
            // Sources belong to the dialog session, not to the incoming plugin's saved settings.
            values["source_image_paths"] = lockedEditSourcePaths
            values["source_image_path"] = lockedEditSourcePaths[0]
        }
        session.setValues(values, for: selectedFunction)
        session.setPluginID(newPluginID, for: selectedFunction)
        baselineValues = values
        isDirty = false
    }

    /// Python `auto_import_available` → panel `import_available` / Import Rest.
    private func applyAutoImportEXIF() async {
        guard let result = await ImageGenExifImport.applyImportRest(
            function: selectedFunction,
            sourcePath: lockedEditSourcePaths.first,
            values: values,
            selectedPluginID: selectedPluginID,
            plugins: pluginsByFunction[selectedFunction] ?? [],
            appState: appState,
            existingSourcePaths: lockedEditSourcePaths
        ) else {
            return
        }
        values = result.values
        if let pluginID = result.selectedPluginID {
            selectedPluginID = pluginID
        }
        if let sourcePaths = result.sourcePaths, !sourcePaths.isEmpty {
            lockedEditSourcePaths = sourcePaths
            appState.imageGenDialogRequest.editSourcePaths = sourcePaths
            values["source_image_paths"] = sourcePaths
            values["source_image_path"] = sourcePaths[0]
        }
        baselineValues = values
        isDirty = false
    }

    private func persistCurrentFunction(_ function: String) {
        guard !selectedPluginID.isEmpty else { return }
        ImageGenPersistence.savePluginDialogSettings(
            function: function,
            pluginID: selectedPluginID,
            values: values,
            config: appState.config
        )
    }

    private func persistVisitedFunctions(excluding excludedFunction: String? = nil) {
        session.setValues(values, for: selectedFunction)
        session.setPluginID(selectedPluginID, for: selectedFunction)
        var sessions: [String: (values: [String: Any], pluginID: String)] = [:]
        for function in visitedFunctions where function != excludedFunction {
            let pluginID = function == selectedFunction
                ? selectedPluginID
                : (session.pluginID(for: function) ?? "")
            guard !pluginID.isEmpty else { continue }
            let functionValues = function == selectedFunction
                ? values
                : session.values(for: function)
            sessions[function] = (functionValues, pluginID)
        }
        ImageGenPersistence.saveDialogSessions(sessions, config: appState.config)
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
        persistVisitedFunctions()
        closeDialog()
    }

    private func performCancel() {
        if isDirty {
            session.setValues(baselineValues, for: selectedFunction)
            persistVisitedFunctions(excluding: selectedFunction)
        } else {
            persistVisitedFunctions()
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
                $0.identifier?.rawValue == Self.windowIdentifier
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

    private func prepareSubmitValues(_ input: [String: Any]) -> [String: Any] {
        var out = input
        if out["random_seed"] as? Bool ?? true {
            let seed = Int.random(in: 0...(2_147_483_647))
            out["seed"] = seed
        }
        switch selectedFunction {
        case "create":
            out.removeValue(forKey: "source_image_path")
            out.removeValue(forKey: "source_image_paths")
            out.removeValue(forKey: "_canonical_source_image_paths")
            out.removeValue(forKey: "use_custom_size")
        case "expand", "infill":
            out.removeValue(forKey: "use_custom_size")
        case "edit":
            // Python ``ImageGenEditDialog.collect_values``: the panel's source list is authoritative
            // (a plugin switch reloads that plugin's saved settings, which carry no sources).
            if !lockedEditSourcePaths.isEmpty {
                out["source_image_paths"] = lockedEditSourcePaths
                out["source_image_path"] = lockedEditSourcePaths[0]
            }
        default:
            break
        }
        return out
    }

    private func submit(replace: Bool) async {
        errorMessage = ""
        let copies = JobStepQueue.normalizeCopies(values["copies"] ?? 1)
        var submitValues = prepareSubmitValues(values)
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
            values = submitValues
            ImageGenPersistence.savePluginDialogSettings(
                function: selectedFunction,
                pluginID: selectedPluginID,
                values: submitValues,
                config: appState.config
            )
            baselineValues = submitValues
            isDirty = false
            if closeOnGenerate {
                persistVisitedFunctions()
                closeDialog()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
