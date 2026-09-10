import Darwin
import Foundation

/// Single-instance lock compatible with Python `instance_lock.py`.
final class InstanceLock {
    private let lockURL: URL
    private var fileDescriptor: Int32 = -1

    init(lockURL: URL) {
        self.lockURL = lockURL
    }

    func tryAcquire() -> Bool {
        let path = lockURL.path
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fd = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if fd < 0 { return false }

        var lock = flock()
        lock.l_type = Int16(F_WRLCK)
        lock.l_whence = Int16(SEEK_SET)
        lock.l_start = 0
        lock.l_len = 0

        if fcntl(fd, F_SETLK, &lock) == -1 {
            close(fd)
            return false
        }

        ftruncate(fd, 0)
        let pidLine = "\(getpid())\n"
        _ = pidLine.withCString { write(fd, $0, strlen($0)) }
        fileDescriptor = fd
        return true
    }

    deinit {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }

    static func forwardToRunningInstance(
        message: [String: Any],
        pipePath: String,
        deadline: TimeInterval = 2.0
    ) -> Bool {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else {
            return false
        }

        let payload = (json + "\n").data(using: .utf8)!
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if writeToPipe(pipePath: pipePath, payload: payload) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private static func writeToPipe(pipePath: String, payload: Data) -> Bool {
        guard FileManager.default.fileExists(atPath: pipePath) else { return false }
        let fd = open(pipePath, O_WRONLY | O_NONBLOCK)
        if fd < 0 { return false }
        defer { close(fd) }
        return payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return write(fd, base, raw.count) == raw.count
        }
    }
}
