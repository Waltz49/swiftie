import Foundation

enum CheckLorasPreviousReport {
    struct SavedPresentation: Equatable {
        let body: String
        var cancelledBanner: String?
    }

    /// Exact text shown in Test LoRAs — Results (written when a run finishes in Swift).
    static func resultsBodyURL(profilePaths: ProfilePaths) -> URL {
        logsDirectory(profilePaths: profilePaths)
            .appendingPathComponent("check_loras_last_results.txt")
    }

    static func cancelledBannerURL(profilePaths: ProfilePaths) -> URL {
        logsDirectory(profilePaths: profilePaths)
            .appendingPathComponent("check_loras_last_results_banner.txt")
    }

    static func persist(
        profilePaths: ProfilePaths,
        body: String,
        cancelledBanner: String?
    ) {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return }
        _ = logsDirectory(profilePaths: profilePaths)
        let bodyURL = resultsBodyURL(profilePaths: profilePaths)
        let bannerURL = cancelledBannerURL(profilePaths: profilePaths)
        do {
            try body.write(to: bodyURL, atomically: true, encoding: .utf8)
            if let cancelledBanner,
               !cancelledBanner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try cancelledBanner.write(to: bannerURL, atomically: true, encoding: .utf8)
            } else if FileManager.default.fileExists(atPath: bannerURL.path) {
                try FileManager.default.removeItem(at: bannerURL)
            }
        } catch {
            print("[Check LoRAs] Could not save previous results snapshot: \(error)")
        }
    }

    static func load(profilePaths: ProfilePaths) -> SavedPresentation? {
        let bodyURL = resultsBodyURL(profilePaths: profilePaths)
        guard FileManager.default.fileExists(atPath: bodyURL.path),
              let body = try? String(contentsOf: bodyURL, encoding: .utf8),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        let bannerURL = cancelledBannerURL(profilePaths: profilePaths)
        var banner: String?
        if FileManager.default.fileExists(atPath: bannerURL.path),
           let text = try? String(contentsOf: bannerURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            banner = text
        }
        return SavedPresentation(body: body, cancelledBanner: banner)
    }

    private static func logsDirectory(profilePaths: ProfilePaths) -> URL {
        let url = profilePaths.dataDirectory.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
