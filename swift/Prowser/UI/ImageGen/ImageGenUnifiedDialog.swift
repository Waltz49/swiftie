import AppKit
import SwiftUI

extension Notification.Name {
    static let prowserRaiseImageGenDialog = Notification.Name("prowser.raiseImageGenDialog")
    /// Open or front the SwiftUI ``imagegen-unified`` scene (works from jobs panel / sidebar).
    static let prowserPresentImageGenUnifiedWindow = Notification.Name("prowser.presentImageGenUnifiedWindow")
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
    @State private var postOpenWorkGeneration = 0
    /// Prevents duplicate persist/close when the user closes via the window button after ⌘W/Close.
    @State private var dismissing = false
    @State private var skipWorkingFileCleanupOnClose = false
    /// Frozen edit sources while the dialog is open (Python ``_edit_source_paths_override``).
    @State private var lockedEditSourcePaths: [String] = []
    @State private var lockedExpandSourcePath: String?
    @State private var lockedInfillSourcePath: String?
    @State private var infillHasPaint = false
    @State private var infillCanvasHolder = ImageGenInfillCanvasHolder()
    private let functions = ["edit", "create", "expand", "infill"]
    private let session = ImageGenSessionState()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                ProgressView("Loading…")
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
                    onSingleSourcePathChanged: { path in
                        adoptLockedSingleSourcePath(path)
                    },
                    compactSliderTracks: true,
                    infillCanvasHolder: infillCanvasHolder,
                    infillMaskPNGData: session.infillMaskPNGData(),
                    onInfillMaskPNGDataChanged: { data in
                        session.setInfillMaskPNGData(data)
                        markDirtyIfNeeded()
                    },
                    onInfillHasPaintChanged: { infillHasPaint = $0 },
                    onInfillPixelmatorDocPathChanged: { path in
                        session.setInfillPixelmatorDocPath(path)
                        if let path, !path.isEmpty {
                            values["pixelmator_doc_path"] = path
                            values["pixelmator_doc_name"] = (path as NSString).lastPathComponent
                        }
                        markDirtyIfNeeded()
                    },
                    onInfillPixelmatorExportChanged: { meta in
                        adoptInfillPixelmatorExportMeta(meta)
                    }
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
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .padding(.top, 2)
        .padding(.bottom, 4)
        .frame(minWidth: 800, minHeight: 600)
        .background(
            ImageGenDialogKeyHandler(
                windowIdentifier: Self.windowIdentifier,
                onCommandLeft: { cycleFunction(delta: -1) },
                onCommandRight: { cycleFunction(delta: 1) },
                onCommandReturn: { Task { await primarySubmit() } },
                onCommandW: { performClose() },
                onEscape: { performClose() },
                onOptionReturn: { false },
                onShiftOptionReturn: { false },
                onOptionLeft: { stepSourceImage(delta: -1) },
                onOptionRight: { stepSourceImage(delta: 1) },
                onBracketKey: { keyCode in handleInfillBrushBracketKey(keyCode) }
            )
        )
        .persistedDialogGeometry(
            DialogGeometryKey.imageGenDialog,
            defaultWidth: 880,
            defaultHeight: 560,
            minWidth: 800,
            minHeight: 600,
            nestedInImageGen: true,
            windowIdentifier: ImageGenUnifiedDialog.windowIdentifier,
            windowTitle: titleText
        )
        .task(id: appState.imageGenDialogReloadToken) {
            await loadDialog()
        }
        .onChange(of: appState.imageGenDialogApplyToken) { _, _ in
            Task { await applyOpenRequest() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserRaiseImageGenDialog)) { _ in
            raiseWindow()
        }
        .background {
            SceneWindowLifecycleBridge(windowIdentifier: Self.windowIdentifier) {
                performClose()
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
                Task {
                    let ok = await switchFunction(from: oldValue, to: newValue)
                    if !ok { selectedFunction = oldValue }
                }
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

            DialogButtonRow(
                footerActionButtons,
                allowReturnActivatesDefault: false,
                useSwiftUIDefaultActionShortcut: false,
                layout: .inline
            )
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
        if selectedFunction == "expand" {
            return lockedExpandSourcePath
                ?? ImageGenFunctionPrerequisites.normalizedExistingFile(values["source_image_path"] as? String)
        }
        if selectedFunction == "infill" {
            return lockedInfillSourcePath
                ?? ImageGenFunctionPrerequisites.normalizedExistingFile(values["source_image_path"] as? String)
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
        dismissing = false
        skipWorkingFileCleanupOnClose = false
        loadGeneration += 1
        postOpenWorkGeneration += 1
        let generation = loadGeneration
        let pendingRequest = request
        let pendingAutoGenerate = pendingRequest.autoGenerate
        closeOnGenerate = ImageGenPersistence.closeDialogOnGenerate(config: appState.config)
        selectedFunction = pendingRequest.function.isEmpty
            ? session.lastFunction(config: appState.config)
            : pendingRequest.function
        if pendingRequest.replaceJobID == nil {
            session.reset()
            lockedInfillSourcePath = nil
            lockedExpandSourcePath = nil
            infillHasPaint = false
        }
        isLoading = true
        errorMessage = ""
        appState.imageGen.beginImageGenDialogBuild()
        do {
            if let replaceJobID = pendingRequest.replaceJobID,
               let job = appState.imageGen.jobForQueueEditor(jobID: replaceJobID) {
                try await ensurePluginsLoaded(function: job.function, availability: .fast)
                selectedFunction = job.function
                selectedPluginID = job.pluginID
                values = job.values
                baselineValues = job.values
                visitedFunctions.insert(selectedFunction)
                let tempRoot = appState.config.temporaryFilesDirectory.path
                if selectedFunction == "edit" {
                    let paths = ImageGenJobDialogRestore.editSourcePaths(from: job.values, tempRoot: tempRoot)
                    lockedEditSourcePaths = ImageGenEditSourcePaths.normalizedPaths(paths)
                    appState.imageGenDialogRequest.editSourcePaths = lockedEditSourcePaths
                    if !lockedEditSourcePaths.isEmpty {
                        values["source_image_paths"] = lockedEditSourcePaths
                        values["source_image_path"] = lockedEditSourcePaths[0]
                    }
                }
                if selectedFunction == "expand" {
                    let expandPaths = ImageGenJobDialogRestore.editSourcePaths(from: job.values, tempRoot: tempRoot)
                    if let path = expandPaths.first {
                        lockedExpandSourcePath = path
                        values["source_image_path"] = path
                        values["source_image_paths"] = [path]
                    }
                }
                if selectedFunction == "infill",
                   let path = ImageGenJobDialogRestore.infillSourcePath(from: job.values, tempRoot: tempRoot) {
                    lockedInfillSourcePath = path
                    values["source_image_path"] = path
                    values["source_image_paths"] = [path]
                }
                if selectedFunction == "infill" {
                    restoreInfillMaskFromJobValues(job.values)
                }
            } else {
                let targetFunction = selectedFunction
                try await ensurePluginsLoaded(function: targetFunction, availability: .fast)
                lockedEditSourcePaths = ImageGenEditSourcePaths.normalizedPaths(pendingRequest.editSourcePaths)
                await switchFunction(from: "", to: targetFunction)
                bootstrapEditSourcePaths(from: pendingRequest, force: true)
                if targetFunction == "infill", pendingRequest.function == "infill" {
                    refreshInfillFromMenuRequest()
                } else if targetFunction == "expand", pendingRequest.function == "expand" {
                    bootstrapSingleSourcePath(function: "expand", force: true)
                }
                if let prompt = pendingRequest.initialPrompt {
                    values["prompt"] = prompt.isEmpty
                        ? ""
                        : (ExifService.initialPromptFromUserComment(prompt) ?? prompt)
                }
            }
            isDirty = false
        } catch {
            errorMessage = error.localizedDescription
        }
        appState.imageGen.endImageGenDialogBuild()
        isLoading = false
        guard generation == loadGeneration else { return }
        schedulePostOpenWork(
            generation: generation,
            pendingRequest: pendingRequest,
            pendingAutoGenerate: pendingAutoGenerate
        )
    }

    private func applyOpenRequest() async {
        let pendingRequest = request
        if pendingRequest.replaceJobID != nil {
            await loadDialog()
            return
        }
        let targetFunction = pendingRequest.function.isEmpty
            ? session.lastFunction(config: appState.config)
            : pendingRequest.function
        do {
            try await ensurePluginsLoaded(function: targetFunction, availability: .fast)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        lockedEditSourcePaths = ImageGenEditSourcePaths.normalizedPaths(pendingRequest.editSourcePaths)
        if targetFunction != selectedFunction {
            let previous = selectedFunction
            guard await switchFunction(from: previous, to: targetFunction) else { return }
            bootstrapEditSourcePaths(from: pendingRequest, force: true)
            if targetFunction == "infill" {
                refreshInfillFromMenuRequest()
            }
            if let prompt = pendingRequest.initialPrompt {
                values["prompt"] = prompt.isEmpty
                    ? ""
                    : (ExifService.initialPromptFromUserComment(prompt) ?? prompt)
            }
        } else {
            bootstrapEditSourcePaths(from: pendingRequest, force: true)
            if targetFunction == "infill" {
                refreshInfillFromMenuRequest()
            }
            if let prompt = pendingRequest.initialPrompt {
                values["prompt"] = prompt.isEmpty
                    ? ""
                    : (ExifService.initialPromptFromUserComment(prompt) ?? prompt)
            }
        }
        let generation = loadGeneration
        schedulePostOpenWork(
            generation: generation,
            pendingRequest: pendingRequest,
            pendingAutoGenerate: pendingRequest.autoGenerate
        )
    }

    private func savedDialogValues(function: String) -> [String: Any]? {
        let saved = ImageGenPersistence.loadDialogSettings(function: function, config: appState.config)
        return saved.isEmpty ? nil : saved
    }

    private func ensurePluginsLoaded(
        function: String,
        availability: ImageGenPluginListAvailability
    ) async throws {
        if availability == .fast,
           let existing = pluginsByFunction[function], !existing.isEmpty {
            return
        }
        let plugins = try await appState.workers.imageGenRegistry.listPlugins(
            function: function,
            savedValues: savedDialogValues(function: function),
            availability: availability
        )
        pluginsByFunction[function] = plugins
    }

    private func refreshAllPluginsFullAvailability(generation: Int) async {
        guard generation == loadGeneration else { return }
        var savedByFunction: [String: [String: Any]] = [:]
        for function in functions {
            if let saved = savedDialogValues(function: function) {
                savedByFunction[function] = saved
            }
        }
        do {
            let grouped = try await appState.workers.imageGenRegistry.listPluginsGrouped(
                functions: functions,
                savedByFunction: savedByFunction,
                availability: .full
            )
            guard generation == loadGeneration else { return }
            for function in functions {
                if let plugins = grouped[function] {
                    pluginsByFunction[function] = plugins
                }
            }
        } catch {
            // Keep fast availability lists if full probes fail.
        }
    }

    private func schedulePostOpenWork(
        generation: Int,
        pendingRequest: ImageGenDialogRequest,
        pendingAutoGenerate: Bool
    ) {
        postOpenWorkGeneration += 1
        let workToken = postOpenWorkGeneration
        let targetFunction = pendingRequest.function.isEmpty
            ? session.lastFunction(config: appState.config)
            : pendingRequest.function
        Task { @MainActor in
            await Task.yield()
            guard workToken == postOpenWorkGeneration else { return }
            guard generation == loadGeneration else { return }
            if pendingRequest.autoImportEXIF, pendingRequest.replaceJobID == nil {
                await applyAutoImportEXIF()
            }
            guard workToken == postOpenWorkGeneration, generation == loadGeneration else { return }
            if pendingAutoGenerate, errorMessage.isEmpty, pendingRequest.replaceJobID == nil {
                appState.imageGenDialogRequest.autoGenerate = false
                scheduleAutoGenerate()
            }
            let unloaded = functions.filter { function in
                function != targetFunction && (pluginsByFunction[function] ?? []).isEmpty
            }
            for function in unloaded {
                guard workToken == postOpenWorkGeneration, generation == loadGeneration else { return }
                try? await ensurePluginsLoaded(function: function, availability: .fast)
            }
            guard workToken == postOpenWorkGeneration else { return }
            await refreshAllPluginsFullAvailability(generation: generation)
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

    @discardableResult
    private func switchFunction(from oldFunction: String, to newFunction: String) async -> Bool {
        if pluginsByFunction[newFunction]?.isEmpty != false {
            do {
                try await ensurePluginsLoaded(function: newFunction, availability: .fast)
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        let sessionValues = session.values(for: newFunction)
        let persistedPath = sessionValues["source_image_path"] as? String
            ?? values["source_image_path"] as? String
        if !ImageGenFunctionPrerequisites.validate(
            function: newFunction,
            appState: appState,
            editSourcePaths: lockedEditSourcePaths,
            persistedSourcePath: persistedPath
        ) {
            return false
        }

        if !oldFunction.isEmpty {
            persistCurrentFunction(oldFunction)
            session.setValues(values, for: oldFunction)
            session.setPluginID(selectedPluginID, for: oldFunction)
            if oldFunction == "infill" {
                session.setInfillMaskPNGData(infillCanvasHolder.canvas?.maskPNGData())
            }
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

        if newFunction == "expand" {
            bootstrapSingleSourcePath(function: "expand", force: oldFunction.isEmpty)
        } else if newFunction == "infill" {
            let forceInfillSource = oldFunction.isEmpty
                || (request.function == "infill" && oldFunction != "infill")
            bootstrapSingleSourcePath(function: "infill", force: forceInfillSource)
            if forceInfillSource {
                session.setInfillMaskPNGData(nil)
            } else {
                restoreInfillSessionFromJobOrMask()
            }
        }

        baselineValues = values
        isDirty = false
        return true
    }

    private func adoptLockedSingleSourcePath(_ path: String) {
        let normalized = (path as NSString).standardizingPath
        switch selectedFunction {
        case "expand":
            lockedExpandSourcePath = normalized
        case "infill":
            lockedInfillSourcePath = normalized
        default:
            return
        }
        values["source_image_path"] = normalized
        values["source_image_paths"] = [normalized]
        markDirtyIfNeeded()
    }

    private func adoptInfillPixelmatorExportMeta(_ meta: [String: Any]) {
        for key in [
            "pixelmator_base_path",
            "pixelmator_mask_path",
            "pixelmator_doc_path",
            "pixelmator_doc_name",
            "_pixelmator_batch_dir",
        ] {
            if let value = meta[key] as? String, !value.isEmpty {
                values[key] = value
            }
        }
        if let doc = values["pixelmator_doc_path"] as? String, !doc.isEmpty {
            session.setInfillPixelmatorDocPath(doc)
        }
        markDirtyIfNeeded()
    }

    private func refreshInfillFromMenuRequest() {
        bootstrapSingleSourcePath(function: "infill", force: true)
        session.setInfillMaskPNGData(nil)
        session.setInfillPixelmatorDocPath(nil)
        infillHasPaint = false
        infillCanvasHolder.canvas = nil
        values.removeValue(forKey: "pixelmator_base_path")
        values.removeValue(forKey: "pixelmator_mask_path")
        values.removeValue(forKey: "pixelmator_doc_path")
        values.removeValue(forKey: "pixelmator_doc_name")
        values.removeValue(forKey: "_pixelmator_batch_dir")
    }

    private func bootstrapSingleSourcePath(function: String, force: Bool) {
        let locked = function == "expand" ? lockedExpandSourcePath : lockedInfillSourcePath
        if !force, let locked, FileManager.default.fileExists(atPath: locked) {
            values["source_image_path"] = locked
            values["source_image_paths"] = [locked]
            return
        }
        if force, let active = ImageGenFunctionPrerequisites.activeImagePathForExpandOrInfill(appState: appState) {
            if function == "expand" {
                lockedExpandSourcePath = active
            } else {
                lockedInfillSourcePath = active
            }
            values["source_image_path"] = active
            values["source_image_paths"] = [active]
            return
        }
        if let persisted = ImageGenFunctionPrerequisites.normalizedExistingFile(
            values["source_image_path"] as? String
        ) {
            if function == "expand" {
                lockedExpandSourcePath = persisted
            } else {
                lockedInfillSourcePath = persisted
            }
            values["source_image_path"] = persisted
            values["source_image_paths"] = [persisted]
            return
        }
        if let active = ImageGenFunctionPrerequisites.activeImagePathForExpandOrInfill(appState: appState) {
            if function == "expand" {
                lockedExpandSourcePath = active
            } else {
                lockedInfillSourcePath = active
            }
            values["source_image_path"] = active
            values["source_image_paths"] = [active]
        }
    }

    private func stepSourceImage(delta: Int) -> Bool {
        guard selectedFunction == "expand" || selectedFunction == "infill" else { return false }
        guard let path = panelSourcePath else { return false }
        let images = appState.fileData.displayedImages
        guard let index = images.firstIndex(of: path) else { return false }
        let next = index + delta
        guard images.indices.contains(next) else { return false }
        adoptLockedSingleSourcePath(images[next])
        return true
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
        Task {
            let ok = await switchFunction(from: previous, to: next)
            if ok {
                selectedFunction = next
            }
        }
    }

    private func markDirtyIfNeeded() {
        isDirty = !ImageGenPersistence.snapshotsEqual(values, baselineValues)
    }

    private func performClose() {
        guard !dismissing else { return }
        if replaceJobID != nil {
            performCancel()
            return
        }
        dismissing = true
        persistVisitedFunctions()
        closeDialog()
    }

    private func performCancel() {
        guard !dismissing else { return }
        dismissing = true
        if isDirty {
            session.setValues(baselineValues, for: selectedFunction)
            persistVisitedFunctions(excluding: selectedFunction)
        } else {
            persistVisitedFunctions()
        }
        closeDialog()
    }

    private func closeDialog() {
        cleanupDialogWorkingFilesUnlessSkipped()
        appState.closeImageGenUnifiedDialog()
        dismiss()
    }

    private func cleanupDialogWorkingFilesUnlessSkipped() {
        guard !skipWorkingFileCleanupOnClose else { return }
        let debug = appState.config.bool(forKey: "debug_mode", default: false)
        InfillExportService.cleanupDialogWorkingFiles(
            values: values,
            tempRoot: appState.config.temporaryFilesDirectory,
            debugMode: debug
        )
    }

    private func handleInfillBrushBracketKey(_ keyCode: Int) -> Bool {
        guard selectedFunction == "infill", let canvas = infillCanvasHolder.canvas else { return false }
        let step = 4
        if keyCode == 33 {
            canvas.adjustBrushRadius(delta: -step)
        } else if keyCode == 30 {
            canvas.adjustBrushRadius(delta: step)
        } else {
            return false
        }
        canvas.revealBrushCursorForKeyboardAdjust()
        return true
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

    private func resolvedSubmitSourcePath(for function: String) -> String? {
        let locked: String?
        switch function {
        case "expand":
            locked = lockedExpandSourcePath
        case "infill":
            locked = lockedInfillSourcePath
        default:
            locked = nil
        }
        if let locked, let path = ImageGenFunctionPrerequisites.normalizedExistingFile(locked) {
            return path
        }
        return ImageGenFunctionPrerequisites.normalizedExistingFile(values["source_image_path"] as? String)
    }

    /// Original library path for EXIF/thumbnails — not Pixelmator/MFLUX temp exports.
    private func infillCanonicalSourcePathForSubmit(values: [String: Any], tempRoot: String) -> String? {
        let doc = (values["pixelmator_doc_path"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !doc.isEmpty {
            let ap = URL(fileURLWithPath: doc).standardizedFileURL.path
            if FileManager.default.isReadableFile(atPath: ap),
               !ImageGenInfillPathSemantics.isWorkingTempPath(ap, tempRoot: tempRoot) {
                return ap
            }
        }
        if let locked = lockedInfillSourcePath,
           let path = ImageGenFunctionPrerequisites.normalizedExistingFile(locked) {
            let ap = URL(fileURLWithPath: path).standardizedFileURL.path
            if !ImageGenInfillPathSemantics.isWorkingTempPath(ap, tempRoot: tempRoot) {
                return ap
            }
        }
        return nil
    }

    private func prepareInfillSubmitExports(submitValues: inout [String: Any]) throws -> [String: Any]? {
        guard let canvas = infillCanvasHolder.canvas, canvas.hasPaintMask(), let mask = canvas.maskCGImage() else {
            StyledMessageDialog.showWarning(
                title: "Infill",
                message: "Paint a mask over the region to infill before running."
            )
            return nil
        }
        guard let source = resolvedSubmitSourcePath(for: "infill") else {
            StyledMessageDialog.showWarning(title: "Infill", message: "Infill requires an active source image.")
            return nil
        }
        let pluginMax = (pluginsByFunction["infill"] ?? [])
            .first { ($0["plugin_id"] as? String) == selectedPluginID }?["max_generation_dimension"] as? Int ?? 1024
        let maxSide = ImageGenDimLimits.effectiveMaxGenerationDimension(
            pluginMax: pluginMax,
            settings: appState.config.rawSettings()
        )
        var exportMeta = try InfillExportService.persistPaintInfillExports(
            sourcePath: source,
            mask: mask,
            maxSide: maxSide,
            tempRoot: appState.config.temporaryFilesDirectory
        )
        if let doc = session.infillPixelmatorDocPath() ?? values["pixelmator_doc_path"] as? String,
           !doc.isEmpty {
            exportMeta["pixelmator_doc_path"] = doc
            exportMeta["pixelmator_doc_name"] = (doc as NSString).lastPathComponent
        }
        session.setInfillMaskPNGData(canvas.maskPNGData())
        return exportMeta
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
            if let path = resolvedSubmitSourcePath(for: selectedFunction) {
                out["source_image_path"] = path
                out["source_image_paths"] = [path]
                let tempRoot = appState.config.temporaryFilesDirectory.path
                if selectedFunction == "infill",
                   let canonical = infillCanonicalSourcePathForSubmit(values: out, tempRoot: tempRoot) {
                    out["_canonical_source_image_paths"] = [canonical]
                } else {
                    out["_canonical_source_image_paths"] = [path]
                }
            }
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

    private func restoreInfillSessionFromJobOrMask() {
        if let doc = values["pixelmator_doc_path"] as? String, !doc.isEmpty {
            session.setInfillPixelmatorDocPath(doc)
        }
        if session.infillMaskPNGData() == nil,
           let maskPath = values["pixelmator_mask_path"] as? String,
           FileManager.default.isReadableFile(atPath: maskPath),
           let paint = ImageGenInfillMath.pixelmatorMaskFileToPaintMask(maskPath) {
            let rep = NSBitmapImageRep(cgImage: paint)
            if let data = rep.representation(using: .png, properties: [:]) {
                session.setInfillMaskPNGData(data)
            }
        }
    }

    private func restoreInfillMaskFromJobValues(_ jobValues: [String: Any]) {
        if let doc = jobValues["pixelmator_doc_path"] as? String, !doc.isEmpty {
            session.setInfillPixelmatorDocPath(doc)
        }
        if let maskPath = jobValues["pixelmator_mask_path"] as? String,
           FileManager.default.isReadableFile(atPath: maskPath),
           let paint = ImageGenInfillMath.pixelmatorMaskFileToPaintMask(maskPath) {
            let rep = NSBitmapImageRep(cgImage: paint)
            if let data = rep.representation(using: .png, properties: [:]) {
                session.setInfillMaskPNGData(data)
            }
        }
    }

    private func submit(replace: Bool) async {
        errorMessage = ""
        if let plugin = (pluginsByFunction[selectedFunction] ?? []).first(where: {
            ($0["plugin_id"] as? String) == selectedPluginID
        }),
           plugin["available"] as? Bool == false {
            let reason = (plugin["unavailable_reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = reason?.isEmpty == false
                ? reason!
                : "The selected model is not available."
            return
        }
        let copies = JobStepQueue.normalizeCopies(values["copies"] ?? 1)
        var submitValues = prepareSubmitValues(values)
        submitValues["copies"] = copies
        if selectedFunction == "infill" {
            do {
                guard let exportMeta = try prepareInfillSubmitExports(submitValues: &submitValues) else {
                    return
                }
                submitValues.merge(exportMeta) { _, new in new }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
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
                let notice = ImageGenSubmitNotice.text(for: selectedFunction)
                submitNotice = notice
                appState.status.show(notice)
                appState.ensureJobsSurfaceVisible()
                if !appState.imageGen.isProcessing,
                   !appState.imageGen.queue.jobs.isEmpty,
                   !appState.imageGen.lastError.isEmpty {
                    errorMessage = appState.imageGen.lastError
                }
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
                dismissing = true
                skipWorkingFileCleanupOnClose = true
                persistVisitedFunctions()
                closeDialog()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
