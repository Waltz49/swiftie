import AppKit
import SwiftUI

/// Full port of `browser_window/dialogs/edit_exif_usercomment_dialog.py` (LM Studio captioning native in Swift).
@MainActor
struct EditExifUserCommentSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.themeColors) private var colors

    @State private var thumbnail: NSImage?
    @FocusState private var editorFocused: Bool

    @State private var instructionsText = ""
    @State private var instructionsVisible = false
    @State private var captionInProgress = false
    @State private var textBeforeAI = ""
    @State private var dotPhase = 0
    @State private var streamingStarted = false
    @State private var captionError: String?
    @State private var dotTimer: Timer?
    @State private var speakHighlighted = false
    @State private var serverSettingsExpanded = false

    @State private var captionHost = ""
    @State private var captionSystemPrompt = ""
    @State private var captionUserPrompt = ""
    @State private var captionMaxWords = 200
    @State private var captionTemperature = 0.7

    @State private var lmStudioProbeSucceeded = false
    @State private var activeCaptionSessionID: UUID?

    private let captionService = LmStudioCaptionService.shared

    private var path: String? { appState.editUserCommentPath }
    private var filename: String {
        guard let path else { return "" }
        return (path as NSString).lastPathComponent
    }

    private var trimmedComment: String {
        appState.editUserCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasComment: Bool { !trimmedComment.isEmpty }

    private var lmStudioCaptionAvailable: Bool {
        lmStudioProbeSucceeded
    }

    private var showLmStudioCaptionControls: Bool { true }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    editorSection
                    serverSettingsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footerRow
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minWidth: 520, minHeight: 420)
        .themeDialogStyle()
        .persistedDialogGeometry(
            DialogGeometryKey.editExifUserComment,
            defaultWidth: 520,
            defaultHeight: 420,
            minWidth: 480,
            minHeight: 320
        )
        .onAppear {
            loadPersistedInstructions()
            loadCaptionSettingsDraft()
            loadThumbnail()
            speakHighlighted = SpeechReader.isSpeaking
            Task {
                await captionService.probeServices(config: appState.config)
                lmStudioProbeSucceeded = captionService.isUIAvailable
            }
            DispatchQueue.main.async { editorFocused = true }
        }
        .onDisappear {
            stopDotAnimation()
            cancelCaptionIfNeeded()
            savePersistedInstructions()
            persistCaptionSettingsDraft()
        }
        .onChange(of: instructionsText) { _, _ in
            savePersistedInstructions()
        }
        .onChange(of: instructionsVisible) { _, _ in
            savePersistedInstructions()
        }
        .onChange(of: captionHost) { _, _ in
            persistCaptionSettingsDraft()
            captionService.resetSessionState()
            Task {
                await captionService.probeServices(config: appState.config)
                lmStudioProbeSucceeded = captionService.isUIAvailable
            }
        }
        .alert("AI Caption Error", isPresented: Binding(
            get: { captionError != nil },
            set: { if !$0 { captionError = nil } }
        )) {
            Button("OK", role: .cancel) { captionError = nil }
        } message: {
            Text(captionError ?? "")
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnailView
            VStack(alignment: .leading, spacing: 6) {
                Text(filename)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(3)
                actionBarRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var thumbnailView: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 128, maxHeight: 128)
            } else {
                Rectangle()
                    .fill(colors.dialogMutedText.opacity(0.15))
            }
        }
        .frame(width: 128, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(colors.defaultBorder, lineWidth: 1)
        )
        .help("Click to open in browse mode")
        .onTapGesture {
            guard let path else { return }
            appState.openImageInBrowse(path: path)
        }
    }

    private var actionBarRow: some View {
        HStack(spacing: 4) {
            assetActionButton(
                "copy",
                normal: "copy",
                hover: "copy_hover",
                tooltip: copyTooltip,
                enabled: hasComment
            ) {
                copyComment(full: NSEvent.modifierFlags.contains(.option))
            }
            assetActionButton(
                "speak",
                normal: "bullhorn",
                hover: "bullhorn_hover",
                tooltip: "Read aloud (click again to stop)",
                enabled: hasComment,
                highlighted: speakHighlighted
            ) {
                readAloud()
            }
            Spacer(minLength: 0)
            if showLmStudioCaptionControls {
                assetActionButton(
                    "instructions",
                    normal: aiInfoIconName,
                    hover: aiInfoIconName,
                    tooltip: "Show/hide Instructions field (override AI user prompt)",
                    highlighted: instructionsVisible
                ) {
                    instructionsVisible.toggle()
                }
            }
            assetActionButton(
                "delete",
                normal: "trash_icon",
                hover: "trash_icon_hover",
                tooltip: "Clear comment text",
                enabled: hasComment
            ) {
                clearCommentText()
            }
        }
    }

    private var aiInfoIconName: String {
        appState.theme.themeID == "light" ? "ai_icon_info_light" : "ai_icon_info_dark"
    }

    private var copyTooltip: String {
        "Copy prompt to clipboard.\n⌥+click to copy full user comment."
    }

    // MARK: - Editor

    private var editorSection: some View {
        VStack(spacing: 0) {
            if instructionsVisible, showLmStudioCaptionControls {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Instructions")
                        .font(.caption)
                        .foregroundStyle(colors.dialogText)
                    TextEditor(text: $instructionsText)
                        .font(.body)
                        .frame(minHeight: 72, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .background(colors.dialogInputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.bottom, 8)
                Divider()
                    .padding(.bottom, 8)
            }

            TextEditor(text: Binding(
                get: { appState.editUserCommentText },
                set: { appState.editUserCommentText = $0 }
            ))
            .font(.body)
            .frame(minHeight: 180)
            .scrollContentBackground(.hidden)
            .background(colors.dialogInputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .focused($editorFocused)
            .disabled(captionInProgress && !streamingStarted)
        }
    }

    private var recaptionHelp: String {
        lmStudioCaptionAvailable
            ? "Generate an AI caption using LMStudio\n(requires a vision model loaded in LMStudio)"
            : "LM Studio server not detected at the configured host.\nExpand Server Settings to set the host, or start LM Studio."
    }

    // MARK: - Server settings (inline; not in app Settings dialog)

    private var serverSettingsSection: some View {
        CollapsibleSettingsSection(
            title: "Server Settings",
            stateKey: "edit_exif_server_settings",
            isExpanded: $serverSettingsExpanded
        ) {
            SettingsPreferencePanel {
                SettingsPreferenceFormRow(
                    label: "LMS host:",
                    subtitle: "LMStudio API host and port (e.g. localhost:1234)",
                    tooltip: "LMStudio API host and port (e.g. localhost:1234)"
                ) {
                    TextField("localhost:1234", text: $captionHost)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                SettingsPreferenceFormRow(
                    label: "Caption max words:",
                    tooltip: "Target word count for the caption (used in prompts)"
                ) {
                    TextField("", value: $captionMaxWords, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                SettingsPreferenceFormRow(
                    label: "Temperature (0–3):",
                    tooltip: "Model temperature (0=deterministic, higher=more creative)"
                ) {
                    TextField("", value: $captionTemperature, format: .number.precision(.fractionLength(1)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("System prompt:")
                        .font(.system(size: 13))
                        .foregroundStyle(SettingsDialogChrome.rowTitle)
                    TextEditor(text: $captionSystemPrompt)
                        .font(.body)
                        .frame(minHeight: 72, maxHeight: 100)
                        .scrollContentBackground(.hidden)
                        .background(colors.dialogInputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                VStack(alignment: .leading, spacing: 6) {
                    Text("User prompt:")
                        .font(.system(size: 13))
                        .foregroundStyle(SettingsDialogChrome.rowTitle)
                    TextEditor(text: $captionUserPrompt)
                        .font(.body)
                        .frame(minHeight: 72, maxHeight: 100)
                        .scrollContentBackground(.hidden)
                        .background(colors.dialogInputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: - Footer

    private var footerRow: some View {
        DialogButtonRow(
            footerTrailingButtons,
            leadingButtons: [
                DialogButton("Reset", help: "Reset text to original value\n(stops AI captioning if in progress)") {
                    resetToOriginal()
                },
            ]
        )
        .background(
            Button("") {
                savePersistedInstructions()
                appState.saveEditUserComment()
            }
                .keyboardShortcut(.return, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    private var footerTrailingButtons: [DialogButton] {
        var buttons: [DialogButton] = [
            DialogButton("Cancel", isCancel: true) {
                savePersistedInstructions()
                if captionInProgress || captionService.isCaptionInProgress {
                    cancelCaptionIfNeeded()
                } else {
                    appState.cancelEditUserComment()
                }
            },
        ]
        if showLmStudioCaptionControls {
            buttons.append(
                DialogButton(
                    captionInProgress ? "…" : "Recaption",
                    id: "Recaption",
                    isEnabled: !captionInProgress,
                    help: recaptionHelp
                ) {
                    savePersistedInstructions()
                    startRecaption()
                }
            )
        }
        buttons.append(
            DialogButton("Save (⌘↩)", isDefault: true) {
                savePersistedInstructions()
                appState.saveEditUserComment()
            }
        )
        return buttons
    }

    // MARK: - Actions

    private func copyComment(full: Bool) {
        let text = ExifService.userCommentTextForClipboard(appState.editUserCommentText, copyFull: full)
        appState.copyTextToClipboard(text)
    }

    private func readAloud() {
        let text = ExifService.truncateUserCommentBeforePrompt(appState.editUserCommentText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        SpeechReader.speakOrStop(text) {
            speakHighlighted = SpeechReader.isSpeaking
        }
    }

    private func clearCommentText() {
        cancelCaptionIfNeeded()
        appState.editUserCommentText = ""
    }

    private func resetToOriginal() {
        cancelCaptionIfNeeded()
        appState.editUserCommentText = appState.editUserCommentOriginalText
    }

    // MARK: - AI Caption

    private func startRecaption() {
        guard let path else { return }
        persistCaptionSettingsDraft()
        if captionService.isCaptionInProgress {
            captionError = "Wait for captioning to finish before starting AI caption."
            return
        }

        captionInProgress = true
        streamingStarted = false
        textBeforeAI = appState.editUserCommentText
        let sessionID = UUID()
        activeCaptionSessionID = sessionID
        startDotAnimation()

        let override = instructionsVisible
            ? instructionsText.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        captionService.startCaption(
            imagePath: path,
            userPromptOverride: override.isEmpty ? nil : override,
            config: appState.config,
            onChunk: { chunk in
                guard activeCaptionSessionID == sessionID, captionInProgress else { return }
                guard !chunk.isEmpty else { return }
                if !streamingStarted {
                    streamingStarted = true
                    stopDotAnimation()
                    appState.editUserCommentText = chunk
                } else {
                    appState.editUserCommentText += chunk
                }
            },
            onFinished: { result in
                guard activeCaptionSessionID == sessionID else { return }
                switch result {
                case .success(let caption):
                    stopDotAnimation()
                    appState.editUserCommentText = caption
                    lmStudioProbeSucceeded = true
                    finishCaption()
                case .failure(let error):
                    if let captionErr = error as? LmStudioCaptionService.CaptionError,
                       captionErr == .cancelled {
                        appState.editUserCommentText = textBeforeAI
                        finishCaption()
                        return
                    }
                    if !streamingStarted {
                        appState.editUserCommentText = textBeforeAI
                    }
                    captionError = error.localizedDescription
                    finishCaption()
                }
            }
        )
    }

    private func finishCaption() {
        activeCaptionSessionID = nil
        captionInProgress = false
        streamingStarted = false
        stopDotAnimation()
    }

    private func cancelCaptionIfNeeded() {
        guard captionInProgress || captionService.isCaptionInProgress else { return }
        activeCaptionSessionID = nil
        captionService.cancelCaption()
        stopDotAnimation()
        appState.editUserCommentText = textBeforeAI
        finishCaption()
    }

    private func startDotAnimation() {
        stopDotAnimation()
        dotPhase = 0
        dotTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in
                dotPhase = (dotPhase + 1) % 4
                appState.editUserCommentText = String(repeating: ".", count: dotPhase + 1)
            }
        }
    }

    private func stopDotAnimation() {
        dotTimer?.invalidate()
        dotTimer = nil
    }

    // MARK: - Persistence / loading

    private func loadPersistedInstructions() {
        instructionsText = appState.config.string(
            forKey: "edit_exif_usercomment_instructions",
            default: ""
        )
        instructionsVisible = appState.config.bool(
            forKey: "edit_exif_usercomment_instructions_visible",
            default: false
        )
    }

    private func savePersistedInstructions() {
        appState.config.updateSetting("edit_exif_usercomment_instructions", value: instructionsText)
        appState.config.updateSetting(
            "edit_exif_usercomment_instructions_visible",
            value: instructionsVisible
        )
    }

    private func loadCaptionSettingsDraft() {
        let settings = captionService.captionSettings(config: appState.config)
        captionHost = settings.host
        captionSystemPrompt = settings.systemPrompt
        captionUserPrompt = settings.userPrompt
        captionMaxWords = settings.maxWords
        captionTemperature = settings.temperature
    }

    private func persistCaptionSettingsDraft() {
        let settings = LmStudioCaptionService.CaptionSettings(
            host: captionHost.trimmingCharacters(in: .whitespacesAndNewlines),
            systemPrompt: captionSystemPrompt,
            userPrompt: captionUserPrompt,
            maxWords: min(max(captionMaxWords, 10), 2000),
            temperature: min(max(captionTemperature, 0), 3)
        )
        captionService.saveCaptionSettings(settings, config: appState.config)
    }

    private func loadThumbnail() {
        guard let path else { return }
        Task {
            if let cg = await appState.thumbnailCache.generateThumbnail(for: path, size: 256) {
                thumbnail = NSImage(
                    cgImage: cg,
                    size: NSSize(width: cg.width, height: cg.height)
                )
            }
        }
    }

    // MARK: - UI helpers

    private func assetActionButton(
        _ id: String,
        normal: String,
        hover: String,
        tooltip: String,
        enabled: Bool = true,
        highlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        SidebarAssetIconButton(
            normalName: normal,
            hoverName: hover,
            tooltip: tooltip,
            selected: highlighted,
            enabled: enabled,
            action: action
        )
        .accessibilityIdentifier(id)
    }
}
