import AppKit
import SwiftUI

/// Full port of `browser_window/dialogs/edit_exif_usercomment_dialog.py`.
@MainActor
struct EditExifUserCommentSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.themeColors) private var colors

    @State private var thumbnail: NSImage?
    @State private var instructionsText = ""
    @State private var instructionsVisible = false
    @State private var captionInProgress = false
    @State private var textBeforeAI = ""
    @State private var dotPhase = 0
    @State private var streamingStarted = false
    @State private var captionError: String?
    @State private var speechController = SpeechController()
    @State private var createAvailable = false
    @State private var editAIAvailable = false
    @State private var dotTimer: Timer?

    private var path: String? { appState.editUserCommentPath }
    private var filename: String {
        guard let path else { return "" }
        return (path as NSString).lastPathComponent
    }

    private var trimmedComment: String {
        appState.editUserCommentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasComment: Bool { !trimmedComment.isEmpty }

    private var hasCaptionForGenerate: Bool {
        ExifService.initialPromptFromUserComment(appState.editUserCommentText) != nil
    }

    private var lmStudioUIEnabled: Bool { BundleCapabilities.lmStudioUIEnabled }

    private var lmStudioCaptionAvailable: Bool {
        lmStudioUIEnabled && appState.workers.modelTasks.isAvailable
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            editorSection
            footerRow
        }
        .padding(20)
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
            loadThumbnail()
            refreshImageGenAvailability()
        }
        .onDisappear {
            stopDotAnimation()
            speechController.stop()
            cancelCaptionIfNeeded()
            savePersistedInstructions()
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
                    .scaledToFit()
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
            if !BundleCapabilities.isMinBundle {
                assetActionButton(
                    "speak",
                    normal: "bullhorn",
                    hover: "bullhorn_hover",
                    tooltip: "Read aloud (click again to stop)",
                    enabled: hasComment,
                    highlighted: speechController.isSpeaking
                ) {
                    let text = ExifService.truncateUserCommentBeforePrompt(trimmedComment)
                    speechController.toggleSpeaking(text)
                }
            }
            if createAvailable {
                assetActionButton(
                    "create",
                    normal: "fromText",
                    hover: "fromText_hover",
                    tooltip: "Create image from this prompt",
                    enabled: hasCaptionForGenerate && !captionInProgress
                ) {
                    generateImageFromCaption()
                }
            }
            if editAIAvailable {
                assetActionButton(
                    "editai",
                    normal: "editAI",
                    hover: "editAI_hover",
                    tooltip: "Edit this image with AI"
                ) {
                    editWithAI()
                }
            }
            Spacer(minLength: 0)
            if lmStudioUIEnabled {
                if lmStudioCaptionAvailable {
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
                AppAssetIconButton(
                    normalName: "gear",
                    hoverName: "gear_hover",
                    fileExtension: "svg",
                    size: 26,
                    iconSize: 16,
                    tooltip: "Open Captioning settings",
                    action: { appState.openSettingsWindow(tab: .captioning) }
                )
                .accessibilityIdentifier("settings")
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
            if instructionsVisible, lmStudioCaptionAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Instructions")
                        .font(.caption)
                        .foregroundStyle(colors.dialogMutedText)
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

            ZStack(alignment: .bottomTrailing) {
                TextEditor(text: Binding(
                    get: { appState.editUserCommentText },
                    set: { appState.editUserCommentText = $0 }
                ))
                .font(.body)
                .frame(minHeight: 180)
                .scrollContentBackground(.hidden)
                .background(colors.dialogInputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .disabled(captionInProgress && !streamingStarted)

                if lmStudioCaptionAvailable {
                    recaptionButton
                        .padding(8)
                }
            }
        }
    }

    private var recaptionButton: some View {
        Button {
            startRecaption()
        } label: {
            Text(captionInProgress ? "…" : "Recaption")
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(colors.validationSuccessChipBackground)
                .foregroundStyle(colors.validationSuccessChipText)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(colors.validationSuccessChipText, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(captionInProgress)
        .help("Generate an AI caption using LMStudio\n(requires a vision model loaded in LMStudio)")
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 8) {
            Button("Reset") {
                resetToOriginal()
            }
            .help("Reset text to original value\n(stops AI captioning if in progress)")

            Spacer()

            Button("Cancel") {
                appState.cancelEditUserComment()
            }
            Button("Save (⌘↩)") {
                appState.saveEditUserComment()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Actions

    private func copyComment(full: Bool) {
        let text = ExifService.userCommentTextForClipboard(appState.editUserCommentText, copyFull: full)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appState.status.show("Copied to clipboard.")
    }

    private func generateImageFromCaption() {
        let prompt = ExifService.initialPromptFromUserComment(appState.editUserCommentText)
        appState.openImageGenDialog(function: "create", initialPrompt: prompt)
    }

    private func editWithAI() {
        guard let path else { return }
        let prompt = ExifService.initialPromptFromUserComment(appState.editUserCommentText)
        appState.openImageGenDialog(
            function: "edit",
            initialPrompt: prompt,
            autoImportEXIF: true,
            editSourcePaths: [path]
        )
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
        let bridge = appState.workers.modelTasks
        guard bridge.isAvailable else {
            captionError = "LMStudio captioning is not available."
            return
        }
        if bridge.isBusy || appState.imageGen.isProcessing {
            captionError = "Wait for the job queue to finish or cancel queued jobs before starting AI caption."
            return
        }

        captionInProgress = true
        streamingStarted = false
        textBeforeAI = appState.editUserCommentText
        startDotAnimation()

        let override = instructionsVisible
            ? instructionsText.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        bridge.onCaptionChunk = { chunk in
            Task { @MainActor in
                guard !chunk.isEmpty else { return }
                if !streamingStarted {
                    streamingStarted = true
                    stopDotAnimation()
                    appState.editUserCommentText = chunk
                } else {
                    appState.editUserCommentText += chunk
                }
            }
        }
        bridge.onCaptionReady = { caption in
            Task { @MainActor in
                stopDotAnimation()
                appState.editUserCommentText = caption
                finishCaption(success: true)
            }
        }
        bridge.onJobFinished = { kind, success, error in
            guard kind == "caption" else { return }
            Task { @MainActor in
                if !success {
                    if !error.isEmpty, error != "Cancelled" {
                        captionError = error
                    }
                    if !streamingStarted {
                        appState.editUserCommentText = textBeforeAI
                    }
                }
                finishCaption(success: success)
            }
        }

        do {
            _ = try bridge.startCaption(
                filePath: path,
                userPromptOverride: override.isEmpty ? nil : override
            )
        } catch {
            stopDotAnimation()
            appState.editUserCommentText = textBeforeAI
            captionError = error.localizedDescription
            finishCaption(success: false)
        }
    }

    private func finishCaption(success: Bool) {
        _ = success
        captionInProgress = false
        streamingStarted = false
        clearCaptionCallbacks()
    }

    private func cancelCaptionIfNeeded() {
        guard captionInProgress else { return }
        stopDotAnimation()
        appState.workers.modelTasks.cancel()
        if !streamingStarted {
            appState.editUserCommentText = textBeforeAI
        }
        finishCaption(success: false)
    }

    private func clearCaptionCallbacks() {
        let bridge = appState.workers.modelTasks
        bridge.onCaptionChunk = nil
        bridge.onCaptionReady = nil
        bridge.onJobFinished = nil
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

    private func loadThumbnail() {
        guard let path else { return }
        Task {
            if let cg = await appState.thumbnailCache.generateThumbnail(for: path, size: 256) {
                thumbnail = NSImage(cgImage: cg, size: NSSize(width: 128, height: 128))
            }
        }
    }

    private func refreshImageGenAvailability() {
        guard BundleCapabilities.imageGenUIEnabled, appState.imageGen.isEnabled else {
            createAvailable = false
            editAIAvailable = false
            return
        }
        Task {
            do {
                let createPlugins = try await appState.workers.imageGenRegistry.listPlugins(function: "create")
                let editPlugins = try await appState.workers.imageGenRegistry.listPlugins(function: "edit")
                createAvailable = createPlugins.contains { ($0["available"] as? Bool) == true }
                editAIAvailable = editPlugins.contains { ($0["available"] as? Bool) == true }
            } catch {
                createAvailable = appState.imageGen.isEnabled
                editAIAvailable = appState.imageGen.isEnabled
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

@MainActor
@Observable
final class SpeechController: NSObject, NSSpeechSynthesizerDelegate {
    private var synthesizer: NSSpeechSynthesizer?
    private(set) var isSpeaking = false

    func toggleSpeaking(_ text: String) {
        if isSpeaking {
            stop()
            return
        }
        guard !text.isEmpty else { return }
        let synth = NSSpeechSynthesizer()
        synth.delegate = self
        synthesizer = synth
        synth.startSpeaking(text)
        isSpeaking = true
    }

    func stop() {
        synthesizer?.stopSpeaking()
        synthesizer = nil
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        Task { @MainActor in
            isSpeaking = false
            synthesizer = nil
        }
    }
}

private extension ThemeColors {
    var validationSuccessChipText: Color { buttonBorderHover }
    var validationSuccessChipBackground: Color { buttonBgDefault.opacity(0.35) }
}
