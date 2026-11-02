import Foundation

enum ChatRole: String, Codable, Equatable {
    case user
    case assistant
}

enum ChatImageGenAutoMode: String, Codable, Equatable {
    case create
    case edit
}

struct ChatMessage: Identifiable, Equatable {
    var role: ChatRole
    var text: String
    var messageID: String
    var imagePaths: [String]
    var sourceImagePaths: [String]
    var imageGenAuto: ChatImageGenAutoMode?

    var id: String { messageID }

    init(
        role: ChatRole,
        text: String,
        messageID: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        imagePaths: [String] = [],
        sourceImagePaths: [String] = [],
        imageGenAuto: ChatImageGenAutoMode? = nil
    ) {
        self.role = role
        self.text = text
        self.messageID = messageID
        self.imagePaths = imagePaths
        self.sourceImagePaths = sourceImagePaths
        self.imageGenAuto = imageGenAuto
    }
}

@Observable
@MainActor
final class ChatSession {
    private(set) var messages: [ChatMessage] = []
    var systemPrompt: String

    init(systemPrompt: String = "") {
        self.systemPrompt = systemPrompt
    }

    func clear() {
        messages.removeAll()
    }

    func append(_ message: ChatMessage) {
        messages.append(message)
    }

    func indexOf(messageID: String) -> Int? {
        messages.firstIndex { $0.messageID == messageID }
    }

    @discardableResult
    func removeAt(_ index: Int) -> ChatMessage? {
        guard messages.indices.contains(index) else { return nil }
        return messages.remove(at: index)
    }

    func lastUserIndex() -> Int? {
        for idx in messages.indices.reversed() where messages[idx].role == .user {
            return idx
        }
        return nil
    }

    func userIndexForRedo(messageID: String) -> Int? {
        guard let idx = indexOf(messageID: messageID) else { return nil }
        if messages[idx].role == .user { return idx }
        for i in stride(from: idx - 1, through: 0, by: -1) where messages[i].role == .user {
            return i
        }
        return nil
    }

    var hasStarted: Bool { !messages.isEmpty }

    func updateText(messageID: String, text: String) {
        guard let idx = indexOf(messageID: messageID) else { return }
        messages[idx].text = text
    }

    func appendText(messageID: String, piece: String) {
        guard let idx = indexOf(messageID: messageID) else { return }
        messages[idx].text += piece
    }

    func clearAssistantImages() {
        for idx in messages.indices where messages[idx].role == .assistant {
            messages[idx].imagePaths = []
            messages[idx].sourceImagePaths = []
        }
    }

    func replaceMessage(at index: Int, with message: ChatMessage) {
        guard messages.indices.contains(index) else { return }
        messages[index] = message
    }

    func setAssistantImages(messageID: String, paths: [String]) {
        guard let idx = indexOf(messageID: messageID) else { return }
        guard messages[idx].role == .assistant else { return }
        messages[idx].imagePaths = paths
        messages[idx].sourceImagePaths = paths
    }
}
