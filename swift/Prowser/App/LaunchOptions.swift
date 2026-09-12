import Foundation

struct LaunchOptions: Sendable {
    var paths: [String] = []
    var filterPattern: String?
    var profilePath: String?
    var noFullscreen: Bool = false
    var debug: Bool = false
    var minBundle: Bool = false

    static func parse() -> LaunchOptions {
        var options = LaunchOptions()
        let args = Array(CommandLine.arguments.dropFirst())
        var index = 0

        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-f", "--filter":
                index += 1
                if index < args.count { options.filterPattern = args[index] }
            case "-p", "--profile":
                index += 1
                if index < args.count { options.profilePath = args[index] }
            case "--no-fullscreen":
                options.noFullscreen = true
            case "--debug":
                options.debug = true
            case "--min":
                options.minBundle = true
            case "--fullscreen":
                break
            case let path where path.hasPrefix("-"):
                break
            default:
                options.paths.append(arg)
            }
            index += 1
        }

        if let envProfile = ProcessInfo.processInfo.environment["PROWSER_PROFILE"], !envProfile.isEmpty {
            options.profilePath = envProfile
        }

        return options
    }
}

struct LaunchMessage: Codable {
    var type: String
    var paths: [String]?
    var filter: String?

    static func from(launchOptions: LaunchOptions, extraPaths: [String] = []) -> [String: Any] {
        var paths = extraPaths.filter { !$0.isEmpty }
        if paths.isEmpty {
            paths = launchOptions.paths
        } else if !launchOptions.paths.isEmpty {
            let seen = Set(paths)
            paths.append(contentsOf: launchOptions.paths.filter { !seen.contains($0) })
        }
        if !paths.isEmpty {
            return [
                "type": "open",
                "files": paths,
                "paths": paths,
            ]
        }
        return ["type": "activate"]
    }
}
