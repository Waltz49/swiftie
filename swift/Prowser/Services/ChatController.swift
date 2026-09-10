import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: String
    var text: String

    init(id: UUID = UUID(), role: String, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// Manages chat session state and `ChatBridge` streaming.
@Observable
@MainActor
final class ChatController {
    private let chatBridge: ChatBridge
    private let dataDirectory: URL
    private(set) var preserveAcrossSessions = false
    private(set) var copyImagesToAssistant = false

    private(set) var messages: [ChatMessage] = []
    var draft = ""
    private(set) var isStreaming = false
    private(set) var lastError = ""

    var isEnabled: Bool { BundleCapabilities.chatUIEnabled && chatBridge.isAvailable }

    init(chatBridge: ChatBridge, dataDirectory: URL) {
        self.chatBridge = chatBridge
        self.dataDirectory = dataDirectory
        wireBridgeCallbacks()
        restorePersistedSessionIfNeeded()
    }

    func reloadPersistenceSettings() {
        let settings = ChatPersistence.loadSettings(dataDirectory: dataDirectory)
        preserveAcrossSessions = settings["preserve_across_sessions"] as? Bool ?? false
        copyImagesToAssistant = settings["copy_images_to_assistant"] as? Bool ?? false
    }

    func setPreserveAcrossSessions(_ enabled: Bool) {
        guard preserveAcrossSessions != enabled else { return }
        preserveAcrossSessions = enabled
        ChatPersistence.saveSettings(
            dataDirectory: dataDirectory,
            preserveAcrossSessions: enabled,
            copyImagesToAssistant: copyImagesToAssistant
        )
        if preserveAcrossSessions {
            persistIfNeeded()
        } else {
            ChatPersistence.clearPersistedFiles(dataDirectory: dataDirectory)
        }
    }

    func setCopyImagesToAssistant(_ enabled: Bool) {
        guard copyImagesToAssistant != enabled else { return }
        copyImagesToAssistant = enabled
        ChatPersistence.saveSettings(
            dataDirectory: dataDirectory,
            preserveAcrossSessions: preserveAcrossSessions,
            copyImagesToAssistant: enabled
        )
    }

    func requestSystemPromptEdit() {
        lastError = "System prompt editor is not available in the Swift build yet."
    }

    private func restorePersistedSessionIfNeeded() {
        reloadPersistenceSettings()
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

    func send() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard isEnabled else {
            lastError = "Chat requires Python workers (LM Studio)."
            return
        }
        guard !isStreaming else { return }

        messages.append(ChatMessage(role: "user", text: trimmed))
        draft = ""
        messages.append(ChatMessage(role: "assistant", text: ""))
        isStreaming = true
        lastError = ""

        let payload = messages.dropLast().map { message in
            ["role": message.role, "text": message.text]
        }

        do {
            try chatBridge.submitChat(messages: payload)
        } catch {
            isStreaming = false
            lastError = error.localizedDescription
            if messages.last?.role == "assistant", messages.last?.text.isEmpty == true {
                messages.removeLast()
            }
        }
    }

    func cancel() {
        chatBridge.cancel()
        isStreaming = false
    }

    func clear() {
        cancel()
        messages.removeAll()
        lastError = ""
        if preserveAcrossSessions {
            ChatPersistence.clearPersistedFiles(dataDirectory: dataDirectory)
        }
    }

    private func wireBridgeCallbacks() {
        chatBridge.onChunk = { [weak self] chunk in
            guard let self else { return }
            guard let index = self.messages.indices.last,
                  self.messages[index].role == "assistant" else { return }
            self.messages[index].text += chunk
        }
        chatBridge.onFinished = { [weak self] text, _ in
            guard let self else { return }
            if let index = self.messages.indices.last,
               self.messages[index].role == "assistant" {
                if self.messages[index].text.isEmpty {
                    self.messages[index].text = text
                }
            }
            self.isStreaming = false
            self.persistIfNeeded()
        }
        chatBridge.onError = { [weak self] error in
            guard let self else { return }
            self.lastError = error
            if let index = self.messages.indices.last,
               self.messages[index].role == "assistant",
               self.messages[index].text.isEmpty {
                self.messages.remove(at: index)
            }
            self.isStreaming = false
            self.persistIfNeeded()
        }
    }
}
