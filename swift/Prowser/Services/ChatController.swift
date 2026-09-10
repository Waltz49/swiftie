import Foundation

/// Manages chat session state and `ChatBridge` streaming.
@Observable
@MainActor
final class ChatController {
    private let chatBridge: ChatBridge
    private let dataDirectory: URL
    private weak var appState: AppState?

    private(set) var preserveAcrossSessions = false
    private(set) var copyImagesToAssistant = false
    private(set) var automaticCreate = false
    private(set) var systemPrompt = ""
    private(set) var systemPromptLabel = "System default"

    private(set) var messages: [ChatMessage] = []
    var draft = ""
    var draftImagePaths: [String] = []
    private(set) var isStreaming = false
    private(set) var lastError = ""
    var editingMessageID: UUID?
    var showSystemPromptSheet = false

    private var streamingPlaceholderID: UUID?
    private var promptStore = ChatPromptConfig.SystemPromptStore(
        systemPrompt: ChatPromptConfig.defaultSystemPrompt,
        activeNamedPromptID: nil,
        namedPrompts: []
    )

    var isEnabled: Bool { BundleCapabilities.chatUIEnabled && chatBridge.isAvailable }

    init(chatBridge: ChatBridge, dataDirectory: URL) {
        self.chatBridge = chatBridge
        self.dataDirectory = dataDirectory
        wireBridgeCallbacks()
        reloadPromptLibrary()
        reloadPersistenceSettings()
        restorePersistedSessionIfNeeded()
    }

    func bind(_ appState: AppState) {
        self.appState = appState
    }

    func reloadPromptLibrary() {
        promptStore = ChatPromptConfig.SystemPromptStore.load(dataDirectory: dataDirectory)
        systemPrompt = promptStore.activePromptText()
        refreshSystemPromptLabel()
    }

    func reloadPersistenceSettings() {
        let settings = ChatPersistence.loadSettings(dataDirectory: dataDirectory)
        preserveAcrossSessions = settings["preserve_across_sessions"] as? Bool ?? false
        copyImagesToAssistant = settings["copy_images_to_assistant"] as? Bool ?? false
        automaticCreate = settings["automatic_create"] as? Bool ?? false
    }

    func refreshSystemPromptLabel() {
        systemPromptLabel = promptStore.activeLabel(sessionText: systemPrompt)
    }

    func setPreserveAcrossSessions(_ enabled: Bool) {
        guard preserveAcrossSessions != enabled else { return }
        preserveAcrossSessions = enabled
        persistSettings()
        if preserveAcrossSessions {
            persistIfNeeded()
        } else {
            ChatPersistence.clearPersistedFiles(dataDirectory: dataDirectory)
        }
    }

    func setCopyImagesToAssistant(_ enabled: Bool) {
        guard copyImagesToAssistant != enabled else { return }
        copyImagesToAssistant = enabled
        persistSettings()
    }

    func setAutomaticCreate(_ enabled: Bool) {
        guard automaticCreate != enabled else { return }
        automaticCreate = enabled
        persistSettings()
    }

    func requestSystemPromptEdit() {
        showSystemPromptSheet = true
    }

    func applySystemPromptSelection(_ store: ChatPromptConfig.SystemPromptStore) {
        promptStore = store
        promptStore.save(dataDirectory: dataDirectory)
        systemPrompt = store.activePromptText()
        refreshSystemPromptLabel()
    }

    func addDraftImagePaths(_ paths: [String]) {
        var merged = draftImagePaths
        for path in paths {
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { continue }
            let abs = URL(fileURLWithPath: path).path
            if !merged.contains(abs) {
                merged.append(abs)
            }
            if merged.count >= ChatImageStore.maxImages { break }
        }
        draftImagePaths = merged
    }

    func removeDraftImage(at index: Int) {
        guard draftImagePaths.indices.contains(index) else { return }
        draftImagePaths.remove(at: index)
    }

    func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !draftImagePaths.isEmpty else { return }
        submitUserMessage(text: trimmed, imagePaths: draftImagePaths)
        draft = ""
        draftImagePaths = []
    }

    func submitUserMessage(text: String, imagePaths: [String]) {
        guard isEnabled else {
            lastError = "Chat requires Python workers (LM Studio)."
            return
        }
        guard !isStreaming else { return }

        let selected = selectedImagePaths()
        let prepared = ChatImageGenTrigger.prepareForStorage(
            text: text,
            imagePaths: imagePaths,
            selectedPaths: selected,
            automaticCreate: automaticCreate
        )
        guard !prepared.text.isEmpty || !prepared.imagePaths.isEmpty else { return }

        var message = ChatMessage(
            role: "user",
            text: prepared.text,
            imageGenAuto: prepared.mode?.rawValue
        )
        if !prepared.imagePaths.isEmpty {
            let sources = prepared.imagePaths
            let stored = ChatImageStore.storeImages(
                prepared.imagePaths,
                messageID: message.id,
                dataDirectory: dataDirectory
            )
            message.imagePaths = stored
            message.sourceImagePaths = ChatImageStore.alignSourcePaths(
                storedPaths: stored,
                sourcePaths: sources
            )
        }

        messages.append(message)
        lastError = ""
        persistIfNeeded()
        requestAssistantResponse()
    }

    func cancel() {
        chatBridge.cancel()
        finalizeCancelledStream()
    }

    func clear() {
        cancel()
        messages.removeAll()
        draft = ""
        draftImagePaths = []
        editingMessageID = nil
        lastError = ""
        if preserveAcrossSessions {
            ChatPersistence.clearPersistedFiles(dataDirectory: dataDirectory)
        }
    }

    func beginEditing(_ messageID: UUID) {
        editingMessageID = messageID
    }

    func endEditing() {
        editingMessageID = nil
    }

    func saveEditedMessage(_ messageID: UUID, text: String, imagePaths: [String]) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let selected = selectedImagePaths()
        let prepared = ChatImageGenTrigger.prepareForStorage(
            text: text,
            imagePaths: imagePaths,
            selectedPaths: selected,
            automaticCreate: automaticCreate,
            keepSelectionTrigger: true
        )
        var updated = messages[index]
        updated.text = prepared.text
        updated.imageGenAuto = prepared.mode?.rawValue
        if prepared.imagePaths != updated.imagePaths {
            let stillReferenced = ChatImageStore.referencedPaths(
                in: messages.enumerated().compactMap { idx, msg in
                    idx == index ? nil : msg
                }
            )
            ChatImageStore.removeMessageImages(
                updated.imagePaths,
                stillReferenced: stillReferenced,
                dataDirectory: dataDirectory
            )
            if prepared.imagePaths.isEmpty {
                updated.imagePaths = []
                updated.sourceImagePaths = []
            } else {
                let stored = ChatImageStore.storeImages(
                    prepared.imagePaths,
                    messageID: updated.id,
                    dataDirectory: dataDirectory
                )
                updated.imagePaths = stored
                updated.sourceImagePaths = ChatImageStore.alignSourcePaths(
                    storedPaths: stored,
                    sourcePaths: prepared.imagePaths
                )
            }
        }
        messages[index] = updated
        editingMessageID = nil
        persistIfNeeded()
    }

    func deleteMessage(_ messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        let removed = messages.remove(at: index)
        let stillReferenced = ChatImageStore.referencedPaths(in: messages)
        ChatImageStore.removeMessageImages(
            removed.imagePaths,
            stillReferenced: stillReferenced,
            dataDirectory: dataDirectory
        )
        if editingMessageID == messageID {
            editingMessageID = nil
        }
        persistIfNeeded()
    }

    func redoMessage(_ messageID: UUID) {
        guard !isStreaming else { return }
        guard let userIndex = userIndexForRedo(messageID: messageID) else { return }
        messages.removeSubrange((userIndex + 1)...)
        persistIfNeeded()
        requestAssistantResponse()
    }

    func createFromAssistantText(_ text: String, sourcePaths: [String] = [], autoGenerate: Bool = false) {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        let paths = sourcePaths.filter { FileManager.default.fileExists(atPath: $0) }
        if !paths.isEmpty {
            appState?.openImageGenDialog(
                function: "edit",
                initialPrompt: prompt,
                autoGenerate: autoGenerate,
                editSourcePaths: paths
            )
        } else {
            appState?.openImageGenDialog(
                function: "create",
                initialPrompt: prompt,
                autoGenerate: autoGenerate
            )
        }
    }

    private func userIndexForRedo(messageID: UUID) -> Int? {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        if messages[index].isUser { return index }
        for idx in stride(from: index - 1, through: 0, by: -1) where messages[idx].isUser {
            return idx
        }
        return nil
    }

    private func selectedImagePaths() -> [String] {
        guard let appState else { return [] }
        if !appState.selection.selectedFiles.isEmpty {
            return ChatSelectionImageTrigger.normalizedSelection(Array(appState.selection.selectedFiles))
        }
        if let current = appState.fileData.currentImagePath {
            return ChatSelectionImageTrigger.normalizedSelection([current])
        }
        return []
    }

    private func requestAssistantResponse() {
        let placeholder = ChatMessage(role: "assistant", text: "…")
        streamingPlaceholderID = placeholder.id
        messages.append(placeholder)
        isStreaming = true
        lastError = ""

        let history = messages.filter { $0.id != placeholder.id }
        let payload = history.map { message in
            var item: [String: Any] = [
                "role": message.role,
                "text": message.text,
            ]
            if !message.imagePaths.isEmpty {
                item["image_paths"] = message.imagePaths
            }
            return item
        }

        do {
            try chatBridge.submitChat(messages: payload, systemPrompt: systemPrompt)
        } catch {
            isStreaming = false
            lastError = error.localizedDescription
            removeStreamingPlaceholderIfEmpty()
        }
    }

    private func wireBridgeCallbacks() {
        chatBridge.onChunk = { [weak self] chunk in
            guard let self else { return }
            self.updateStreamingText { $0 + chunk }
        }
        chatBridge.onRestarted = { [weak self] in
            self?.updateStreamingText { _ in "…" }
        }
        chatBridge.onFinished = { [weak self] text, suppressAutoImageGen in
            guard let self else { return }
            self.finishStreaming(finalText: text)
            if !suppressAutoImageGen {
                self.handleAutoImageGeneration(assistantMessageID: self.streamingPlaceholderID)
            }
            self.streamingPlaceholderID = nil
            self.isStreaming = false
            self.persistIfNeeded()
        }
        chatBridge.onError = { [weak self] error in
            guard let self else { return }
            self.lastError = error
            self.removeStreamingPlaceholderIfEmpty()
            self.streamingPlaceholderID = nil
            self.isStreaming = false
            self.persistIfNeeded()
        }
        chatBridge.onCancelled = { [weak self] in
            guard let self else { return }
            self.finalizeCancelledStream()
            self.persistIfNeeded()
        }
    }

    private func updateStreamingText(_ transform: (String) -> String) {
        guard let placeholderID = streamingPlaceholderID,
              let index = messages.firstIndex(where: { $0.id == placeholderID }) else { return }
        messages[index].text = transform(messages[index].text)
    }

    private func finishStreaming(finalText: String) {
        guard let placeholderID = streamingPlaceholderID,
              let index = messages.firstIndex(where: { $0.id == placeholderID }) else { return }
        if messages[index].text.isEmpty || messages[index].text == "…" {
            messages[index].text = finalText
        }
    }

    private func removeStreamingPlaceholderIfEmpty() {
        guard let placeholderID = streamingPlaceholderID,
              let index = messages.firstIndex(where: { $0.id == placeholderID }) else { return }
        let text = messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "…" {
            messages.remove(at: index)
        }
    }

    private func finalizeCancelledStream() {
        guard let placeholderID = streamingPlaceholderID,
              let index = messages.firstIndex(where: { $0.id == placeholderID }) else {
            isStreaming = false
            return
        }
        let text = messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "…" {
            messages.remove(at: index)
        }
        streamingPlaceholderID = nil
        isStreaming = false
    }

    private func handleAutoImageGeneration(assistantMessageID: UUID?) {
        guard BundleCapabilities.imageGenUIEnabled else { return }
        guard let userMessage = messages.last(where: { $0.isUser }) else { return }
        let userPaths = ChatImageGenTrigger.pathsForImageGen(userMessage)
        var mode: ChatImageGenTrigger.Mode?
        if let stored = userMessage.imageGenAuto {
            mode = stored == ChatImageGenTrigger.Mode.edit.rawValue ? .edit : .create
        } else {
            mode = ChatImageGenTrigger.effectiveMode(
                text: userMessage.text,
                hasUserImages: !userMessage.imagePaths.isEmpty,
                automaticCreate: automaticCreate
            )
        }
        let attachSources = ChatImageGenTrigger.wantsAssistantSources(
            text: userMessage.text,
            hasUserImages: !userMessage.imagePaths.isEmpty
        ) || (copyImagesToAssistant && mode == .edit && !userPaths.isEmpty)
        var editSourcePaths: [String] = []
        if attachSources, !userPaths.isEmpty, let assistantMessageID,
           let index = messages.firstIndex(where: { $0.id == assistantMessageID }) {
            messages[index].imagePaths = userPaths
            messages[index].sourceImagePaths = userPaths
            editSourcePaths = userPaths
        }
        if mode == .edit, !attachSources {
            mode = .create
        }
        guard let assistantMessageID,
              let index = messages.firstIndex(where: { $0.id == assistantMessageID }) else { return }
        let responseText = messages[index].text
        switch mode {
        case .create:
            createFromAssistantText(responseText, autoGenerate: true)
        case .edit:
            if editSourcePaths.isEmpty {
                createFromAssistantText(responseText, autoGenerate: true)
            } else {
                createFromAssistantText(
                    responseText,
                    sourcePaths: editSourcePaths,
                    autoGenerate: true
                )
            }
        case .none:
            break
        }
    }

    private func restorePersistedSessionIfNeeded() {
        guard preserveAcrossSessions else { return }
        messages = ChatPersistence.loadMessages(dataDirectory: dataDirectory)
    }

    private func persistIfNeeded() {
        guard preserveAcrossSessions, !messages.isEmpty else {
            if preserveAcrossSessions {
                ChatPersistence.clearPersistedFiles(dataDirectory: dataDirectory)
            }
            return
        }
        ChatPersistence.saveMessages(messages, dataDirectory: dataDirectory)
    }

    private func persistSettings() {
        ChatPersistence.saveSettings(
            dataDirectory: dataDirectory,
            preserveAcrossSessions: preserveAcrossSessions,
            copyImagesToAssistant: copyImagesToAssistant,
            automaticCreate: automaticCreate
        )
    }
}
