import Darwin
import Foundation

enum UnixSocketError: Error {
    case connectFailed
    case sendFailed
    case bindFailed
    case listenFailed
}

/// Minimal Unix domain socket helpers for CLIP control/status IPC.
enum UnixSocket {
    static func sendJSON(path: String, payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw UnixSocketError.connectFailed
        }
        withUnsafeMutablePointer(to: &address.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (index, byte) in pathBytes.enumerated() {
                    dest[index] = byte
                }
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.connectFailed }
        defer { close(fd) }

        let connectResult = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else { throw UnixSocketError.connectFailed }

        let sent = data.withUnsafeBytes { rawBuffer in
            send(fd, rawBuffer.baseAddress, data.count, 0)
        }
        guard sent == data.count else { throw UnixSocketError.sendFailed }
    }

    static func removeSocketFile(at path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Accepts short-lived status connections from the CLIP worker.
final class UnixStatusSocketServer {
    private var serverFD: Int32 = -1
    private let path: String
    private(set) var latestStatus: [String: Any] = [:]

    init(path: String) {
        self.path = path
    }

    func start() throws {
        stop()
        UnixSocket.removeSocketFile(at: path)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &address.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (index, byte) in pathBytes.enumerated() {
                    dest[index] = byte
                }
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.bindFailed }
        let bindResult = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw UnixSocketError.bindFailed
        }
        guard listen(fd, 5) == 0 else {
            close(fd)
            throw UnixSocketError.listenFailed
        }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        serverFD = fd
    }

    func poll() {
        guard serverFD >= 0 else { return }
        let clientFD = accept(serverFD, nil, nil)
        guard clientFD >= 0 else { return }
        defer { close(clientFD) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let received = recv(clientFD, &buffer, buffer.count, 0)
        guard received > 0 else { return }
        let data = Data(buffer.prefix(received))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        latestStatus = json
    }

    func stop() {
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        UnixSocket.removeSocketFile(at: path)
    }

    deinit {
        stop()
    }
}
