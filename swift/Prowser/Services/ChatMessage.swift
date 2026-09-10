import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: String
    var text: String
    var imagePaths: [String]
    var sourceImagePaths: [String]
    var imageGenAuto: String?

    init(
        id: UUID = UUID(),
        role: String,
        text: String,
        imagePaths: [String] = [],
        sourceImagePaths: [String] = [],
        imageGenAuto: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.imagePaths = imagePaths
        self.sourceImagePaths = sourceImagePaths
        self.imageGenAuto = imageGenAuto
    }

    var isUser: Bool { role == "user" }
    var isAssistant: Bool { role == "assistant" }
}
