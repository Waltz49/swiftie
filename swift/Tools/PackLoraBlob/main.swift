import Foundation
import LoRABlobCodec

enum PackLoraBlobError: Error, CustomStringConvertible {
    case missingPassword
    case missingOutput
    case readFailed(String)
    case writeFailed(String)

    var description: String {
        switch self {
        case .missingPassword:
            return "Set LORABLOB_PASSWORD in the environment (do not pass on the command line)."
        case .missingOutput:
            return "Missing --output path."
        case let .readFailed(path):
            return "Could not read input: \(path)"
        case let .writeFailed(path):
            return "Could not write output: \(path)"
        }
    }
}

struct Options {
    var inputPath: String?
    var outputPath: String?
}

func parseOptions() -> Options {
    var opts = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--input":
            guard let next = args.first else { break }
            args.removeFirst()
            opts.inputPath = next
        case "--output":
            guard let next = args.first else { break }
            args.removeFirst()
            opts.outputPath = next
        case "-h", "--help":
            fputs(
                """
                pack_lorablob — encrypt JSON stdin or --input into a LORB v1 blob.

                Environment:
                  LORABLOB_PASSWORD   encryption password (required)

                Options:
                  --input PATH        JSON file (default: stdin)
                  --output PATH       blob destination (required)

                """,
                stderr
            )
            exit(0)
        default:
            fputs("Unknown argument: \(arg)\n", stderr)
            exit(2)
        }
    }
    return opts
}

func main() throws {
    let opts = parseOptions()
    guard let password = ProcessInfo.processInfo.environment["LORABLOB_PASSWORD"],
          !password.isEmpty else {
        throw PackLoraBlobError.missingPassword
    }
    guard let outputPath = opts.outputPath, !outputPath.isEmpty else {
        throw PackLoraBlobError.missingOutput
    }

    let jsonData: Data
    if let inputPath = opts.inputPath {
        let url = URL(fileURLWithPath: inputPath)
        do {
            jsonData = try Data(contentsOf: url)
        } catch {
            throw PackLoraBlobError.readFailed(inputPath)
        }
    } else {
        let stdin = FileHandle.standardInput
        jsonData = stdin.readDataToEndOfFile()
    }

    guard !jsonData.isEmpty else {
        fputs("error: empty JSON input\n", stderr)
        exit(1)
    }

    let blob = try LoRABlobCodec.encrypt(jsonUTF8: jsonData, password: password)
    let outURL = URL(fileURLWithPath: outputPath)
    do {
        try FileManager.default.createDirectory(
            at: outURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try blob.write(to: outURL, options: .atomic)
    } catch {
        throw PackLoraBlobError.writeFailed(outputPath)
    }
}

do {
    try main()
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}