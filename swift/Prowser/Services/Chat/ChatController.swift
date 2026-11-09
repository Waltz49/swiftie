import AppKit
import Foundation

/// Sidebar chat state and LM Studio streaming (port of ``chat_pane_widget.py``).
@Observable
@MainActor
final class ChatController {
    private unowned let appState: AppState
    private let session = ChatSession()
    private var imageStore: ChatImageStore
    private var streamTask: Task<Void, Never>?
    private var streamingMessageID: String?
    private var lmAvailableOnShow = true
    private var chatStarted = false

    var sessionSettings: ChatPersistence.SessionSettings
    var systemPromptConfig: ChatSystemPromptStore.Config
    var showToolbar: Bool
    var showUnavailableOnly = false
    var scrollToBottomToken = 0
    var showSystemPromptLibrary = false {
        didSet { publishDialogVisibilityChange(from: oldValue, to: showSystemPromptLibrary) }
    }
    var showUserPromptLibrary = false {
        didSet { publishDialogVisibilityChange(from: oldValue, to: showUserPromptLibrary) }
    }
    var showTips = false
    var showPrefixPostfixLibrary = false {
        didSet { publishDialogVisibilityChange(from: oldValue, to: showPrefixPostfixLibrary) }
    }
    var showExitScripts = false {
        didSet { publishDialogVisibilityChange(from: oldValue, to: showExitScripts) }
    }
    var showReadAloudExit = false {
        didSet { publishDialogVisibilityChange(from: oldValue, to: showReadAloudExit) }
    }
    var showRejectedPhrases = false {
        didSet { publishDialogVisibilityChange(from: oldValue, to: showRejectedPhrases) }
    }

    /// Unsaved script command while the read-aloud exit dialog is open (survives view re-creation).
    var readAloudExitCommandDraft = ""
    private var readAloudExitDialogPrepared = false
    var textAIExitDraft = ""
    var imageAIExitDraft = ""
    private var exitScriptsDialogPrepared = false

    enum UserPromptLibraryApplyMode: Equatable {
        case chatCompose
        case imageGenAppend
        case manageOnly
    }

    struct UserPromptSaveDraft: Equatable {
        var defaultName: String
        var text: String
        var imagePaths: [String]
    }

    var userPromptLibraryApplyMode: UserPromptLibraryApplyMode = .chatCompose
    var userPromptLibrarySuggestionText = ""
    var userPromptLibrarySuggestionImages: [String] = []
    private var imageGenAppendExistingPrompt = ""
    var userPromptLibraryImageGenOnApplied: ((String) -> Void)?

    var composePromptText = ""
    var composeAttachmentPaths: [String] = []

    var showUserPromptSave = false {
        didSet { publishDialogVisibilityChange(from: oldValue, to: showUserPromptSave) }
    }
    var userPromptSaveDraft: UserPromptSaveDraft?

    var editingMessageID: String?
    private var pendingEditText = ""
    var messageEditImagePaths: [String] = []

    var messages: [ChatMessage] { session.messages }
    var systemPromptLabel: String {
        ChatSystemPromptStore.activeLabel(sessionText: session.systemPrompt, config: systemPromptConfig)
    }
    var isStreaming: Bool { streamTask != nil }
    var streamingAssistantMessageID: String? { streamingMessageID }
    /// Compose area editable when chat is active (LM up or prior messages). Stays on during prediction.
    var composeFieldEnabled: Bool {
        lmAvailableOnShow || chatStarted
    }

    var canSubmitUserMessage: Bool {
        !isStreaming && composeFieldEnabled
    }

    init(appState: AppState) {
        self.appState = appState
        let dataDir = appState.config.dataDirectory
        let loadedSettings = ChatPersistence.loadSettings(dataDirectory: dataDir)
        let loadedSystemPrompt = ChatSystemPromptStore.load(dataDirectory: dataDir)
        sessionSettings = loadedSettings
        systemPromptConfig = loadedSystemPrompt
        showToolbar = appState.config.bool(forKey: "chat_show_toolbar", default: true)
        let tempRoot = appState.config.string(forKey: "temporary_files_directory")
        let tempURL: URL
        if tempRoot.isEmpty {
            tempURL = FileManager.default.temporaryDirectory
        } else {
            tempURL = URL(fileURLWithPath: (tempRoot as NSString).expandingTildeInPath, isDirectory: true)
        }
        imageStore = ChatImageStore(
            persistent: loadedSettings.preserveAcrossSessions,
            dataDirectory: dataDir,
            temporaryFilesDirectory: tempURL
        )
        session.systemPrompt = ChatSystemPromptStore.activePromptText(config: loadedSystemPrompt)
        if loadedSettings.preserveAcrossSessions {
            restorePersistedSession()
        }
        if !loadedSettings.copyImagesToAssistant {
            clearAssistantMessageImages(refreshUI: false)
        }
    }

    func onPaneAppear() {
        Task { await refreshLmStudioAvailability() }
    }

    func refreshLmStudioAvailability() async {
        let ok = await LmStudioCaptionService.shared.probeServicesIfNeeded(
            config: appState.config,
            forceRefresh: true
        )
        lmAvailableOnShow = ok
        if !ok, !chatStarted {
            showUnavailableOnly = true
        } else {
            showUnavailableOnly = false
        }
    }

    func refreshConnection() {
        Task { await refreshLmStudioAvailability() }
    }

    func openLmStudioAndPollAvailability() {
        appState.openLmStudioOrShowInstallHelp()
        Task {
            let delaysSeconds: [Double] = [2, 4, 8]
            for delay in delaysSeconds {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                await refreshLmStudioAvailability()
                if lmAvailableOnShow { break }
            }
        }
    }

    func refreshComposeAttachmentsForSelectionTrigger(in text: String) {
        guard ChatSelectionImageTrigger.hasSelectionTrigger(text) else { return }
        let selected = ChatSelectionImageTrigger.selectedImagesForChat(appState: appState)
        guard !selected.isEmpty else { return }
        composeAttachmentPaths = Array(selected.prefix(ChatSelectionImageTrigger.maxChatImages))
    }

    func prepareUserMessage(
        text: String,
        imagePaths: [String],
        keepSelectionTrigger: Bool = false
    ) -> (text: String, imagePaths: [String], mode: ChatImageGenTrigger.Mode?) {
        let applied = ChatSelectionImageTrigger.applySelectionTrigger(
            text: text,
            imagePaths: imagePaths,
            appState: appState,
            keepTriggerInText: keepSelectionTrigger
        )
        var storedText = applied.text
        let storedPaths = applied.imagePaths
        let mode: ChatImageGenTrigger.Mode?
        if sessionSettings.automaticCreate {
            storedText = ChatImageGenTrigger.stripCreateCommands(storedText)
            mode = storedPaths.isEmpty ? .create : .edit
        } else {
            mode = ChatImageGenTrigger.classifyMode(text: storedText, hasUserImages: !storedPaths.isEmpty)
        }
        return (storedText, storedPaths, mode)
    }

    func submitUserMessage(text: String, imagePaths: [String]) {
        guard canSubmitUserMessage else { return }
        let prepared = prepareUserMessage(text: text, imagePaths: imagePaths)
        guard !prepared.text.isEmpty || !prepared.imagePaths.isEmpty else { return }
        showUnavailableOnly = false
        chatStarted = true
        var msg = ChatMessage(role: .user, text: prepared.text, imageGenAuto: prepared.mode.map {
            $0 == .create ? .create : .edit
        })
        if !prepared.imagePaths.isEmpty {
            let refs = ChatImagePaths.pathsReferencedByMessages(session.messages)
            let sources = ChatImagePaths.sourcesForNewAttachments(newPaths: prepared.imagePaths)
            msg.imagePaths = imageStore.storeImages(prepared.imagePaths, messageID: msg.messageID, referencedElsewhere: refs)
            msg.sourceImagePaths = ChatImagePaths.alignSourceImagePaths(storedPaths: msg.imagePaths, sourcePaths: sources)
        }
        session.append(msg)
        bumpScroll()
        maybePersistSession()
        requestAssistantResponse()
    }

    func requestAssistantResponse() {
        let placeholder = ChatMessage(role: .assistant, text: "…")
        let assistantID = placeholder.messageID
        streamingMessageID = assistantID
        session.append(placeholder)
        bumpScroll()

        streamTask?.cancel()
        let history = session.messages.filter { $0.messageID != placeholder.messageID }
        streamTask = Task { @MainActor in
            ChatLMStudioActivity.setPredictionActive(true)
            defer {
                ChatLMStudioActivity.setPredictionActive(false)
                streamTask = nil
                streamingMessageID = nil
            }
            do {
                let outcome = try await ChatRejectedPhraseStreamRetry.runWithRejectionRetry(
                    config: appState.config,
                    onChunk: { [weak self] piece in
                        guard let self, let sid = self.streamingMessageID else { return }
                        self.session.appendText(messageID: sid, piece: piece)
                        self.bumpScroll()
                    },
                    onRestarted: { [weak self] in
                        guard let self, let sid = self.streamingMessageID else { return }
                        self.session.updateText(messageID: sid, text: "…")
                    },
                    streamOnce: { emit in
                        _ = try await LmStudioCaptionService.shared.streamChatSessionTurn(
                            messages: history,
                            systemPrompt: self.session.systemPrompt,
                            config: self.appState.config,
                            onChunk: emit
                        )
                    }
                )
                let final = LmStudioCaptionService.finalizeChatResponse(outcome.accumulated)
                guard !final.isEmpty else {
                    throw LmStudioCaptionService.CaptionError.runtime("The model returned an empty response.")
                }
                if let sid = streamingMessageID {
                    session.updateText(messageID: sid, text: final)
                }
                bumpScroll()
                maybePersistSession()
                handleAutoImageGenAfterReply(
                    assistantMessageID: assistantID,
                    assistantText: final,
                    suppress: outcome.suppressAutoImageGen
                )
            } catch is CancellationError {
                finalizeCancelledStream()
                maybePersistSession()
            } catch {
                removeStreamingPlaceholder()
                maybePersistSession()
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                StyledMessageDialog.showWarning(title: "Chat Error", message: message)
            }
        }
    }

    func stopGeneration() {
        streamTask?.cancel()
        streamTask = nil
        ChatLMStudioActivity.setPredictionActive(false)
    }

    func clearChat() {
        stopGeneration()
        session.clear()
        chatStarted = false
        if sessionSettings.preserveAcrossSessions {
            ChatPersistence.clearPersistedFiles(dataDirectory: appState.config.dataDirectory)
        }
        imageStore.resetSession(
            persistent: sessionSettings.preserveAcrossSessions,
            dataDirectory: appState.config.dataDirectory,
            temporaryFilesDirectory: temporaryFilesDirectory()
        )
        bumpScroll()
        if !lmAvailableOnShow, !chatStarted {
            showUnavailableOnly = true
        }
    }

    func setCopyImagesToAssistant(_ enabled: Bool) {
        sessionSettings.copyImagesToAssistant = enabled
        ChatPersistence.saveSettings(sessionSettings, dataDirectory: appState.config.dataDirectory)
        if !enabled {
            clearAssistantMessageImages(refreshUI: true)
        }
    }

    func setAutomaticCreate(_ enabled: Bool) {
        sessionSettings.automaticCreate = enabled
        ChatPersistence.saveSettings(sessionSettings, dataDirectory: appState.config.dataDirectory)
    }

    func setPreserveAcrossSessions(_ enabled: Bool) {
        guard enabled != sessionSettings.preserveAcrossSessions else { return }
        sessionSettings.preserveAcrossSessions = enabled
        ChatPersistence.saveSettings(sessionSettings, dataDirectory: appState.config.dataDirectory)
        imageStore.resetSession(
            persistent: enabled,
            dataDirectory: appState.config.dataDirectory,
            temporaryFilesDirectory: temporaryFilesDirectory()
        )
        if !enabled {
            ChatPersistence.clearPersistedFiles(dataDirectory: appState.config.dataDirectory)
        } else {
            maybePersistSession()
        }
    }

    func setShowToolbar(_ visible: Bool) {
        showToolbar = visible
        appState.config.updateSetting("chat_show_toolbar", value: visible)
    }

    func editSystemPrompt() {
        showSystemPromptLibrary = true
    }

    func openExitScripts() {
        prepareExitScriptsDialogIfNeeded()
        showExitScripts = true
    }

    func openReadAloudExit() {
        prepareReadAloudExitDialogIfNeeded()
        showReadAloudExit = true
    }

    func prepareReadAloudExitDialogIfNeeded() {
        guard !readAloudExitDialogPrepared else { return }
        readAloudExitCommandDraft = SettingsPathValidation.normalizedExitScriptCommandDisplay(
            appState.config.string(forKey: ExitScriptUtils.settingSayExit)
        )
        readAloudExitDialogPrepared = true
    }

    func resetReadAloudExitDialog() {
        readAloudExitDialogPrepared = false
        readAloudExitCommandDraft = ""
    }

    func prepareExitScriptsDialogIfNeeded() {
        guard !exitScriptsDialogPrepared else { return }
        textAIExitDraft = SettingsPathValidation.normalizedExitScriptCommandDisplay(
            appState.config.string(forKey: ExitScriptUtils.settingTextAIExit)
        )
        imageAIExitDraft = SettingsPathValidation.normalizedExitScriptCommandDisplay(
            appState.config.string(forKey: ExitScriptUtils.settingImageAIExit)
        )
        exitScriptsDialogPrepared = true
    }

    func resetExitScriptsDialog() {
        exitScriptsDialogPrepared = false
        textAIExitDraft = ""
        imageAIExitDraft = ""
    }

    func openRejectedPhrases() {
        showRejectedPhrases = true
    }

    private func publishDialogVisibilityChange(from oldValue: Bool, to newValue: Bool) {
        guard oldValue != newValue else { return }
        appState.syncAuxiliaryDialogs()
    }

    func applySystemPromptSelection(_ config: ChatSystemPromptStore.Config) {
        var updated = config
        ChatSystemPromptStore.validateActiveNamedPromptID(&updated)
        systemPromptConfig = updated
        session.systemPrompt = ChatSystemPromptStore.activePromptText(config: updated)
        ChatSystemPromptStore.save(systemPromptConfig, dataDirectory: appState.config.dataDirectory)
    }

    /// Approximate fit height for sidebar “expand chat pane” (Python ``ChatPaneWidget.preferred_content_height``).
    func preferredSidebarContentHeight() -> CGFloat {
        if showUnavailableOnly { return 240 }
        let rows = max(1, messages.count)
        return min(520, max(200, CGFloat(rows) * 52 + 180))
    }

    func saveSystemPromptText(_ text: String) {
        systemPromptConfig.systemPrompt = text
        session.systemPrompt = text
        ChatSystemPromptStore.save(systemPromptConfig, dataDirectory: appState.config.dataDirectory)
    }

    func openFavoriteUserPrompts(mode: UserPromptLibraryApplyMode? = nil) {
        let resolvedMode = mode ?? (BundleCapabilities.chatUIEnabled ? .chatCompose : .manageOnly)
        userPromptLibraryApplyMode = resolvedMode
        switch resolvedMode {
        case .chatCompose:
            userPromptLibrarySuggestionText = composePromptText
            userPromptLibrarySuggestionImages = composeAttachmentPaths
        case .imageGenAppend:
            userPromptLibrarySuggestionText = imageGenAppendExistingPrompt
            userPromptLibrarySuggestionImages = []
        case .manageOnly:
            userPromptLibrarySuggestionText = ""
            userPromptLibrarySuggestionImages = []
        }
        showUserPromptLibrary = true
    }

    func openFavoriteUserPromptsForImageGen(
        existingPrompt: String,
        onApplied: @escaping (String) -> Void
    ) {
        imageGenAppendExistingPrompt = existingPrompt
        userPromptLibraryImageGenOnApplied = onApplied
        openFavoriteUserPrompts(mode: .imageGenAppend)
    }

    func userPromptLibraryDidDismiss(cancelled: Bool) {
        _ = cancelled
        showUserPromptLibrary = false
        userPromptLibraryImageGenOnApplied = nil
        userPromptLibraryApplyMode = .chatCompose
        imageGenAppendExistingPrompt = ""
    }

    func finishUserPromptLibraryOK(config: ChatUserPromptStore.Config, selectedEntry: ChatFavoritePrompt?) {
        var updated = config
        if let selectedEntry {
            updated.selectedFavoriteID = selectedEntry.id
        }
        ChatUserPromptStore.save(updated, dataDirectory: appState.config.dataDirectory)

        switch userPromptLibraryApplyMode {
        case .chatCompose:
            if let entry = selectedEntry {
                composePromptText = entry.text
                composeAttachmentPaths = ChatUserPromptFavoriteImages.existingImagePaths(entry.imagePaths)
            }
        case .imageGenAppend:
            if let entry = selectedEntry {
                let combined = ChatUserPromptAppendLogic.append(
                    existing: imageGenAppendExistingPrompt,
                    addition: entry.text
                )
                if combined != imageGenAppendExistingPrompt {
                    userPromptLibraryImageGenOnApplied?(combined)
                }
            }
        case .manageOnly:
            break
        }
        userPromptLibraryDidDismiss(cancelled: false)
    }

    func saveUserMessageAsFavorite(messageID: String) {
        guard let idx = session.indexOf(messageID: messageID),
              session.messages[idx].role == .user else { return }
        let msg = session.messages[idx]
        var paths = msg.imagePaths
        if paths.isEmpty, editingMessageID == messageID {
            paths = messageEditImagePaths
        }
        userPromptSaveDraft = UserPromptSaveDraft(defaultName: "", text: msg.text, imagePaths: paths)
        showUserPromptSave = true
    }

    func commitSaveUserPrompt(name: String, text: String, imagePaths: [String]) {
        let id = ChatUserPromptStore.newEntryID()
        let stored = ChatUserPromptFavoriteImages.persistFavoriteImagePaths(
            favoriteID: id,
            sourcePaths: imagePaths,
            dataDirectory: appState.config.dataDirectory,
            imageExtensions: appState.config.imageExtensions
        )
        var config = ChatUserPromptStore.load(dataDirectory: appState.config.dataDirectory)
        let entry = ChatFavoritePrompt(id: id, label: name, text: text, imagePaths: stored)
        config.favoritePrompts.append(entry)
        config.selectedFavoriteID = id
        ChatUserPromptStore.save(config, dataDirectory: appState.config.dataDirectory)
        showUserPromptSave = false
        userPromptSaveDraft = nil
    }

    func openPrefixPostfixLibrary() {
        showPrefixPostfixLibrary = true
    }

    func deleteMessage(messageID: String) {
        guard let idx = session.indexOf(messageID: messageID) else { return }
        session.removeAt(idx)
        maybePersistSession()
        bumpScroll()
    }

    func redoMessage(messageID: String) {
        commitPendingMessageEditIfNeeded()
        guard let userIdx = session.userIndexForRedo(messageID: messageID) else { return }
        stopGeneration()
        removeStreamingPlaceholder()
        while session.messages.count > userIdx + 1 {
            session.removeAt(session.messages.count - 1)
        }
        let userMsg = session.messages[userIdx]
        refreshUserMessageSelectionTriggerOnRedo(messageID: userMsg.messageID)
        maybePersistSession()
        bumpScroll()
        requestAssistantResponse()
    }

    /// Re-apply ``{}`` on redo so images match the current browser selection (Python ``_refresh_user_message_selection_trigger``).
    private func refreshUserMessageSelectionTriggerOnRedo(messageID: String) {
        guard let idx = session.indexOf(messageID: messageID) else { return }
        let msg = session.messages[idx]
        guard msg.role == .user, ChatSelectionImageTrigger.hasSelectionTrigger(msg.text) else { return }
        let prepared = prepareUserMessage(
            text: msg.text,
            imagePaths: msg.imagePaths,
            keepSelectionTrigger: true
        )
        if prepared.text == msg.text,
           Set(prepared.imagePaths) == Set(msg.imagePaths) {
            return
        }
        updateMessage(messageID: messageID, text: prepared.text, imagePaths: prepared.imagePaths)
    }

    func redoLastUserMessage() {
        commitPendingMessageEditIfNeeded()
        guard let idx = session.lastUserIndex() else { return }
        let msg = session.messages[idx]
        redoMessage(messageID: msg.messageID)
    }

    func beginMessageEdit(messageID: String, text: String, imagePaths: [String]) {
        if let current = editingMessageID, current != messageID {
            commitPendingMessageEditIfNeeded()
        }
        editingMessageID = messageID
        pendingEditText = text
        messageEditImagePaths = imagePaths
    }

    func syncPendingEditText(_ text: String) {
        guard editingMessageID != nil else { return }
        pendingEditText = text
    }

    /// Applies inline message edit draft to the session (e.g. before ⌘R redo).
    func commitPendingMessageEditIfNeeded() {
        guard let messageID = editingMessageID else { return }
        let text = pendingEditText
        let paths = messageEditImagePaths
        cancelMessageEdit()
        updateMessage(messageID: messageID, text: text, imagePaths: paths)
    }

    func cancelMessageEdit() {
        editingMessageID = nil
        pendingEditText = ""
        messageEditImagePaths = []
    }

    func updateMessage(messageID: String, text: String, imagePaths: [String]) {
        guard let idx = session.indexOf(messageID: messageID) else { return }
        var msg = session.messages[idx]
        if msg.role == .user {
            let prepared = prepareUserMessage(
                text: text,
                imagePaths: imagePaths,
                keepSelectionTrigger: true
            )
            msg.text = prepared.text
            msg.imageGenAuto = prepared.mode.map { $0 == .create ? .create : .edit }
            let refs = ChatImagePaths.pathsReferencedByMessages(session.messages, exceptMessageID: messageID)
            let sources = ChatImagePaths.sourcesForNewAttachments(
                newPaths: prepared.imagePaths,
                oldStoredPaths: msg.imagePaths,
                oldSourcePaths: msg.sourceImagePaths
            )
            msg.imagePaths = imageStore.storeImages(prepared.imagePaths, messageID: msg.messageID, referencedElsewhere: refs)
            msg.sourceImagePaths = ChatImagePaths.alignSourceImagePaths(storedPaths: msg.imagePaths, sourcePaths: sources)
        } else {
            msg.text = text
            msg.imagePaths = ChatAssistantImagePaths.normalize(imagePaths)
        }
        session.replaceMessage(at: idx, with: msg)
        maybePersistSession()
        bumpScroll()
    }

    func persistOnQuitIfNeeded() {
        maybePersistSession()
    }

    private func handleAutoImageGenAfterReply(
        assistantMessageID: String,
        assistantText: String,
        suppress: Bool
    ) {
        guard !suppress else { return }
        guard let userIdx = session.lastUserIndex() else { return }
        let userMsg = session.messages[userIdx]
        let userPaths = ChatImagePaths.pathsForImageGen(userMsg)
        var mode = ChatImageGenTrigger.effectiveMode(
            text: userMsg.text,
            hasUserImages: !userMsg.imagePaths.isEmpty,
            automaticCreate: sessionSettings.automaticCreate
        )
        let wantsSources = ChatImageGenTrigger.wantsAssistantSources(
            text: userMsg.text,
            hasUserImages: !userMsg.imagePaths.isEmpty
        )
        let attachSources = wantsSources
            || (sessionSettings.copyImagesToAssistant && mode == .edit && !userPaths.isEmpty)
        if mode == .edit, !attachSources {
            mode = .create
        }
        guard mode != nil else { return }

        var editPaths: [String] = []
        if attachSources, !userPaths.isEmpty {
            editPaths = ChatAssistantImagePaths.normalize(userPaths)
            session.setAssistantImages(messageID: assistantMessageID, paths: editPaths)
            bumpScroll()
            maybePersistSession()
        }

        let prompt = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        switch mode {
        case .edit:
            appState.openImageGenDialog(
                function: "infill",
                initialPrompt: prompt,
                autoGenerate: true,
                editSourcePaths: editPaths.isEmpty ? userPaths : editPaths
            )
        case .create:
            appState.openImageGenDialog(
                function: "create",
                initialPrompt: prompt,
                autoGenerate: true
            )
        case .none:
            break
        }
    }

    private func finalizeCancelledStream() {
        guard let sid = streamingMessageID, let idx = session.indexOf(messageID: sid) else {
            removeStreamingPlaceholder()
            return
        }
        let text = session.messages[idx].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "…" {
            session.removeAt(idx)
        }
    }

    private func removeStreamingPlaceholder() {
        guard let sid = streamingMessageID, let idx = session.indexOf(messageID: sid) else { return }
        session.removeAt(idx)
    }

    private func restorePersistedSession() {
        let loaded = ChatPersistence.loadMessages(dataDirectory: appState.config.dataDirectory)
        for msg in loaded {
            session.append(msg)
        }
        if session.hasStarted {
            chatStarted = true
            showUnavailableOnly = false
        }
    }

    private func maybePersistSession() {
        guard sessionSettings.preserveAcrossSessions else { return }
        ChatPersistence.saveMessages(session.messages, dataDirectory: appState.config.dataDirectory)
    }

    private func clearAssistantMessageImages(refreshUI: Bool) {
        session.clearAssistantImages()
        if refreshUI { bumpScroll() }
        maybePersistSession()
    }

    private func bumpScroll() {
        scrollToBottomToken += 1
    }

    private func temporaryFilesDirectory() -> URL {
        let tempRoot = appState.config.string(forKey: "temporary_files_directory")
        if tempRoot.isEmpty {
            return FileManager.default.temporaryDirectory
        }
        return URL(fileURLWithPath: (tempRoot as NSString).expandingTildeInPath, isDirectory: true)
    }
}
