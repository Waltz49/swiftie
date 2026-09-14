import Foundation

enum AboutBuildInfo {
    static func packageVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    static func buildDate() -> String {
        if let url = Bundle.main.executableURL,
           let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
           let date = values.contentModificationDate {
            return formatted(date: date)
        }
        return formattedNow()
    }

    private static func formattedNow() -> String {
        formatted(date: Date())
    }

    private static func formatted(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
