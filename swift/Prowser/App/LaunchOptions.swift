import Foundation

struct LaunchOptions: Sendable {
    var paths: [String] = []
    var filterPattern: String?
    var profilePath: String?
    var forceFullscreen: Bool = false
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
            case "-h", "--help":
                printUsage()
                exit(0)
            case "-f", "--filter":
                index += 1
                if index < args.count { options.filterPattern = args[index] }
            case "-p", "--profile":
                index += 1
                if index < args.count { options.profilePath = args[index] }
            case "--fullscreen":
                options.forceFullscreen = true
            case "--no-fullscreen":
                options.noFullscreen = true
            case "--debug":
                options.debug = true
            case "--min":
                options.minBundle = true
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

    static func printUsage() {
        let name = (CommandLine.arguments.first as NSString?)?.lastPathComponent ?? "Prowser"
        let text = """
        Prowser - Browse images with thumbnails and fullscreen view

        usage: \(name) [-h] [-f PATTERN] [-p DIR] [--fullscreen] [--no-fullscreen] [--debug] [--min] [paths ...]

        positional arguments:
          paths                 Directory or image files to open

        options:
          -h, --help            Show this help message and exit
          -f, --filter PATTERN  Filter images using glob pattern (e.g. "image*", "*.jpg")
          -p, --profile DIR     Use a custom profile directory instead of ~/.prowser
          --fullscreen          Launch in macOS Space fullscreen (overrides saved window mode)
          --no-fullscreen       Launch windowed (overrides default fullscreen)
          --debug               Enable debug mode
          --min                 Minimal UI (hide generation-related features)

        Examples:
          \(name) /path/to/images
          \(name) /path/to/images --filter "image*"
          \(name) /path/to/image.jpg --fullscreen
          \(name) /path/to/images -p ~/.prowser-test

        Environment:
          PROWSER_PROFILE       Profile directory (same as -p/--profile)
        """
        print(text)
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
