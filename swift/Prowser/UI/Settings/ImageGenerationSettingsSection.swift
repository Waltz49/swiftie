import AppKit
import SwiftUI

@MainActor
struct ImageGenerationSettingsSection: View {
    @Environment(AppState.self) private var appState
    @Binding var promptModificationExpanded: Bool
    @Binding var cooldownTimesExpanded: Bool
    @Binding var miscellaneousExpanded: Bool
    @Binding var pythonEnvironmentExpanded: Bool
    @State private var imageOutputEnabled = false
    @State private var imageOutputPath = ""
    @State private var imagegenVenvPath = ""
    @State private var venvInstallMessage = ""
    @State private var venvInstallInProgress = false

    var body: some View {
        let _ = appState.config.settingsEditRevision
        Group {
            imageCreationDirectorySection()

            CollapsibleSettingsSection(
                title: "Prompt Modification",
                stateKey: "imagegen_prompt_modification",
                isExpanded: $promptModificationExpanded
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    gearToggleRow(
                        title: "Add prefix/postfix strings",
                        subtitle: "Apply prefix/postfix rules to chat and image prompts.",
                        key: "imagegen_add_chat_prefix_postfix",
                        defaultValue: true,
                        onGear: { appState.chat.openPrefixPostfixLibrary() }
                    )

                    gearToggleRow(
                        title: "Use prompt filter exits",
                        subtitle: "Use exit scripts to modify prompt data before model calls.",
                        key: "use_prompt_filter_exits",
                        gearHelp: "Configure text and image prompt exit scripts",
                        onGear: { appState.chat.openExitScripts() }
                    )

                    gearToggleRow(
                        title: "Use read aloud exit",
                        subtitle: "External script for speak buttons instead of built-in speech.",
                        key: ExitScriptUtils.useReadAloudExitKey,
                        gearHelp: "Configure read aloud exit script",
                        onGear: { appState.chat.openReadAloudExit() }
                    )

                    gearToggleRow(
                        title: "Reject forbidden LM Studio phrases",
                        subtitle: "Restart chat when the model response contains configured refusal phrases.",
                        key: ChatRejectedResponsePhrasesStore.settingsEnableKey,
                        defaultValue: true,
                        onGear: { appState.chat.openRejectedPhrases() }
                    )
                }
                .padding(.horizontal, 20)
            }

            CollapsibleSettingsSection(
                title: "Cooldown times",
                stateKey: "imagegen_cooldown_times",
                isExpanded: $cooldownTimesExpanded
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    cooldownSlider(
                        title: "Inter-job cooldown time",
                        key: "imagegen_job_cooldown_seconds",
                        defaultValue: ImageGenDimLimits.jobCooldownSecondsDefault
                    )
                    cooldownSlider(
                        title: "Inter copy cooldown",
                        key: "imagegen_inter_copy_cooldown_seconds",
                        defaultValue: ImageGenDimLimits.interCopyCooldownSecondsDefault
                    )
                }
                .padding(.horizontal, 20)
            }

            CollapsibleSettingsSection(
                title: "Miscellaneous",
                stateKey: "imagegen_miscellaneous",
                isExpanded: $miscellaneousExpanded
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Max generation dimension")
                            .preferencesScanRecordsLabel("Max generation dimension")
                        AppMiniSlider(
                            value: dimensionSliderBinding,
                            in: 0...Double(ImageGenDimLimits.sliderMaxIndex),
                            step: 1
                        )
                        Text("\(currentDimension) px")
                            .monospacedDigit()
                            .frame(width: 72, alignment: .trailing)
                    }

                    Toggle("Include triggers in final exif data", isOn: boolBinding("imagegen_include_triggers_in_exif"))
                        .preferencesScanRecordsLabel("Include triggers in final exif data")
                    Toggle("Unload image Models when queue is held", isOn: boolBinding("imagegen_unload_models_when_queue_held"))
                        .preferencesScanRecordsLabel("Unload image Models when queue is held")
                    if BundleCapabilities.lmStudioUIEnabled {
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(
                                "Unload LMStudio models before generation",
                                isOn: boolBinding("imagegen_unload_lmstudio_models_before_generation", default: true)
                            )
                            .preferencesScanRecordsLabel("Unload LMStudio models before generation")
                            Text(
                                "Frees memory for image models before each generation job. "
                                    + "LM Studio can reload the saved caption model on next use."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Output format")
                            .font(.headline)
                            .preferencesScanRecordsLabel("Output format")
                        Picker("Output format", selection: stringBinding("imagegen_output_format", default: "png")) {
                            ForEach(ImageGenDimLimits.outputFormats, id: \.self) { format in
                                Text(format.uppercased()).tag(format)
                            }
                        }
                        .preferencesScanRecordsLabel("Output format")
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        .padding(.leading, 40)
                    }

                    jobCardHoverPromptRow()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("MFLUX generation backend")
                            .font(.headline)
                            .preferencesScanRecordsLabel("MFLUX generation backend")
                        Picker("MFLUX generation backend", selection: stringBinding("imagegen_execution_backend", default: "optimized")) {
                            Text("Optimized").tag("optimized")
                            Text("MFLUX CLI").tag("mflux_cli")
                        }
                        .preferencesScanRecordsLabel("MFLUX generation backend")
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        .padding(.leading, 40)
                        Text(
                            "Optimized runs pipelines in the imagegen venv and reuses loaded models between jobs. "
                                + "MFLUX CLI starts a separate tool per job (compatibility or debugging)."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle("Low RAM mode", isOn: boolBinding("imagegen_low_ram", default: true))
                        .preferencesScanRecordsLabel("Low RAM mode")
                }
                .padding(.horizontal, 20)
            }

            CollapsibleSettingsSection(
                title: "Python Environment",
                stateKey: "python_environment",
                isExpanded: $pythonEnvironmentExpanded
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    imagegenVenvSection()
                    pathField(
                        title: "Python executable",
                        subtitle: "Optional override; defaults to imagegen venv python3.",
                        key: "python_executable"
                    )
                    pathField(
                        title: "MFLUX venv path",
                        subtitle: "Optional; defaults to imagegen venv for mflux-generate-* CLIs.",
                        key: "mflux_venv_path"
                    )
                }
                .padding(.horizontal, 20)
            }
        }
        .onAppear {
            loadImageCreationDirectory()
            imagegenVenvPath = appState.config.imagegenVenvURL().path
        }
    }

    @ViewBuilder
    private func imagegenVenvSection() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Bundled imagegen modules ship inside the app. Install dependencies into a venv under your profile "
                    + "(mflux, torch, diffusers, peft, sdnq, and related libraries). Model weights are downloaded separately."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Venv directory", text: $imagegenVenvPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { persistImagegenVenvPath() }
                Button("Choose…") { chooseImagegenVenvDirectory() }
                Button(venvInstallInProgress ? "Installing…" : "Install dependencies…") {
                    installImagegenVenv()
                }
                .disabled(venvInstallInProgress)
            }
            if !venvInstallMessage.isEmpty {
                Text(venvInstallMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func persistImagegenVenvPath() {
        let trimmed = imagegenVenvPath.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.config.updateSetting("imagegen_venv_path", value: trimmed.isEmpty ? nil : trimmed)
        settingsChanged()
    }

    private func chooseImagegenVenvDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !imagegenVenvPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (imagegenVenvPath as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        imagegenVenvPath = url.path
        persistImagegenVenvPath()
    }

    private func installImagegenVenv() {
        persistImagegenVenvPath()
        let dialog = ImageGenVenvInstallOutputDialogController.beginNewSession(appState: appState)
        let venvPath = appState.config.imagegenVenvURL().path
        dialog.append("Installing imagegen dependencies into:\n\(venvPath)\n\n")
        venvInstallInProgress = true
        venvInstallMessage = ""
        Task {
            let result = await ImageGenVenvInstaller.install(config: appState.config) { chunk in
                Task { @MainActor in
                    dialog.append(chunk)
                }
            }
            venvInstallInProgress = false
            venvInstallMessage = result.message
            dialog.append("\n--- \(result.success ? "Success" : "Failed") ---\n\(result.message)\n")
            if result.success {
                imagegenVenvPath = appState.config.imagegenVenvURL().path
                settingsChanged()
            }
        }
    }

    @ViewBuilder
    private func imageCreationDirectorySection() -> some View {
        let defaultDir = ImageGenPathNaming.defaultImageCreationDirectory()
        VStack(alignment: .leading, spacing: 6) {
            Text("Generated images folder")
                .font(.headline)
                .preferencesScanRecordsLabel("Generated images folder")
            Text(
                "When enabled, new images are saved in the folder below. "
                    + "When disabled, images are saved to \(defaultDir)."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                SettingsPreferenceSwitch(isOn: $imageOutputEnabled)
                    .onChange(of: imageOutputEnabled) { _, _ in persistImageCreationDirectory() }
                TextField("Directory for generated images", text: $imageOutputPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { persistImageCreationDirectory() }
                Button("Choose…") { chooseImageOutputDirectory() }
            }
        }
    }

    private func loadImageCreationDirectory() {
        let (path, enabled) = appState.config.imageCreationDirectory()
        imageOutputEnabled = enabled
        imageOutputPath = path ?? ""
    }

    private func persistImageCreationDirectory() {
        let trimmed = imageOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.config.setImageCreationDirectory(
            path: trimmed.isEmpty ? nil : trimmed,
            enabled: imageOutputEnabled
        )
        settingsChanged()
    }

    private func chooseImageOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !imageOutputPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (imageOutputPath as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        imageOutputPath = url.path
        persistImageCreationDirectory()
    }

    private var currentDimension: Int {
        ImageGenDimLimits.alignGenerationDimension(
            appState.config.int(forKey: "imagegen_max_generation_dimension", default: ImageGenDimLimits.maxGenerationDimensionDefault)
        )
    }

    private var dimensionSliderBinding: Binding<Double> {
        Binding(
            get: {
                Double(ImageGenDimLimits.sliderIndexFromDimension(
                    appState.config.int(forKey: "imagegen_max_generation_dimension", default: ImageGenDimLimits.maxGenerationDimensionDefault)
                ))
            },
            set: { newValue in
                let px = ImageGenDimLimits.dimensionFromSliderIndex(Int(newValue))
                appState.config.setValue(px, forKey: "imagegen_max_generation_dimension")
                settingsChanged()
            }
        )
    }

    @ViewBuilder
    private func jobCardHoverPromptRow() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Job card hover shows")
                .font(.headline)
                .preferencesScanRecordsLabel("Job card hover shows")
            Picker(
                "Job card hover shows",
                selection: stringBinding(
                    JobCardHoverPromptMode.settingsKey,
                    default: JobCardHoverPromptMode.originalValue
                )
            ) {
                Text("Original Prompt").tag(JobCardHoverPromptMode.originalValue)
                Text("Modified prompt").tag(JobCardHoverPromptMode.modifiedValue)
            }
            .preferencesScanRecordsLabel("Job card hover shows")
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .padding(.leading, 40)
        }
    }

    @ViewBuilder
    private func gearToggleRow(
        title: String,
        subtitle: String,
        key: String,
        defaultValue: Bool = false,
        gearHelp: String = "Edit settings",
        onGear: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle(title, isOn: boolBinding(key, default: defaultValue))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onGear()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help(gearHelp)
        }
        .preferencesScanRecordsLabel(title)
    }

    private func cooldownSlider(title: String, key: String, defaultValue: Int) -> some View {
        HStack {
            Text(title)
            AppMiniSlider(
                value: Binding(
                    get: { Double(appState.config.int(forKey: key, default: defaultValue)) },
                    set: { newValue in
                        let clamped = max(ImageGenDimLimits.seriesCooldownSecondsMin, min(ImageGenDimLimits.seriesCooldownSecondsMax, Int(newValue)))
                        appState.config.setValue(clamped, forKey: key)
                        settingsChanged()
                    }
                ),
                in: Double(ImageGenDimLimits.seriesCooldownSecondsMin)...Double(ImageGenDimLimits.seriesCooldownSecondsMax),
                step: 1
            )
            Text("\(appState.config.int(forKey: key, default: defaultValue))s")
                .monospacedDigit()
                .frame(width: 40)
        }
        .preferencesScanRecordsLabel(title)
    }

    private func boolBinding(_ key: String, default defaultValue: Bool = false) -> Binding<Bool> {
        SettingsSupport.boolBinding(config: appState.config, key: key, default: defaultValue, onChange: settingsChanged)
    }

    private func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        SettingsSupport.stringBinding(config: appState.config, key: key, default: defaultValue, onChange: settingsChanged)
    }

    private func settingsChanged() {
        appState.config.applySettingsChange(emit: appState.eventBus)
        MfluxToolchain.shared.bind(config: appState.config)
        appState.workers.reloadSettings(config: appState.config)
        appState.imageGen.reloadEnvironment()
        appState.imageGen.refreshJobCardTooltipPreference()
        appState.bumpMenuCommandsRevision()
    }

    @ViewBuilder
    private func pathField(title: String, subtitle: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("", text: stringBinding(key, default: ""))
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    choosePath(into: key)
                }
            }
        }
        .preferencesScanRecordsLabel(title)
    }

    private func choosePath(into key: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = key == "python_executable"
        panel.canChooseDirectories = key != "python_executable"
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appState.config.updateSetting(key, value: url.path)
        settingsChanged()
    }
}
