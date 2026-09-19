import Foundation

/// Default HTTPS folder for search-model zip archives (see `IMAGE_RECOGNITION_MODELS.md`).
enum ImageRecognitionDownloadDefaults {
    static let defaultBaseURL = "https://waltzremote.com/swift-prowser/search-models/v1"

    static let settingsOverrideKey = "image_recognition_model_download_base_url"
}
