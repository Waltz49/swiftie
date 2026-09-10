import Darwin
import Foundation

/// Listens on the Python-compatible named pipe for second-instance open requests.
final class NamedPipeListener: @unchecked Sendable {
    private let pipePath: String
    private var thread: Thread?
    private var running = false
    private let queue = DispatchQueue(label: "prowser.named-pipe", qos: .utility)

    var onMessage: (@MainActor ([String: Any]) -> Void)?

    init(pipePath: String) {
        self.pipePath = pipePath
    }

    func start() {
        guard thread == nil else { return }
        running = true
        let thread = Thread { [weak self] in
            self?.listenLoop()
        }
        thread.name = "NamedPipeListener"
        thread.start()
        self.thread = thread
    }

    func stop() {
        running = false
        thread = nil
    }

    private func listenLoop() {
        while running {
            ensureFIFO()
            let fd = open(pipePath, O_RDONLY | O_NONBLOCK)
            if fd < 0 {
                Thread.sleep(forTimeInterval: 0.2)
                continue
            }

            defer { close(fd) }

            var buffer = ""
            while running {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let readCount = read(fd, &chunk, chunk.count)
                if readCount > 0 {
                    buffer += String(bytes: chunk.prefix(readCount), encoding: .utf8) ?? ""
                    while let newline = buffer.firstIndex(of: "\n") {
                        let line = String(buffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
                        buffer = String(buffer[buffer.index(after: newline)...])
                        guard !line.isEmpty else { continue }
                        handleLine(line)
                    }
                } else if readCount == 0 {
                    break
                } else {
                    let errno = errno
                    if errno == EAGAIN || errno == EINTR {
                        Thread.sleep(forTimeInterval: 0.1)
                        continue
                    }
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func ensureFIFO() {
        if FileManager.default.fileExists(atPath: pipePath) { return }
        _ = pipePath.withCString { path in
            mkfifo(path, 0o600)
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let message = object as? [String: Any] else {
            return
        }
        let handler = onMessage
        Task { @MainActor in
            handler?(message)
        }
    }
}
