import Foundation

/// Port of `chat_plugins/chat_lmstudio_activity.py`.
@MainActor
enum ChatLMStudioActivity {
    private(set) static var predictionActive = false

    static func setPredictionActive(_ active: Bool) {
        predictionActive = active
    }
}
