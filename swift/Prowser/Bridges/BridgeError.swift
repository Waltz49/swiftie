import Foundation

enum BridgeError: Error, LocalizedError {
    case pythonUnavailable
    case workerNotRunning
    case encodingFailed
    case busy
    case notReady
    case workerMessage(String)

    var errorDescription: String? {
        switch self {
        case .pythonUnavailable: return "Python worker environment not found."
        case .workerNotRunning: return "Worker process is not running."
        case .encodingFailed: return "Failed to encode bridge command."
        case .busy: return "Worker is busy."
        case .notReady: return "Worker is not ready."
        case .workerMessage(let text): return text
        }
    }
}
