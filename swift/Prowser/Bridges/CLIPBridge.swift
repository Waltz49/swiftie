import Foundation

/// Swift port of `browser_window/managers/background_clip_controller.py`.
@Observable
@MainActor
final class CLIPBridge {
    private let dataDirectory: URL
    private let environment: PythonLocator.Environment?
    private var workerProcess: Process?
    private var statusServer: UnixStatusSocketServer?
    private var statusTimer: Timer?

    private(set) var enabled = false
    private(set) var status: String = "stopped"
    private(set) var lastStatus: [String: Any] = [:]

    private var commandSocketPath: String {
        dataDirectory.appendingPathComponent("background_clip_control.sock").path
    }

    private var statusSocketPath: String {
        dataDirectory.appendingPathComponent("background_clip_status.sock").path
    }

    init(profilePath: String?) {
        let paths = ProfilePaths(profilePath: profilePath)
        dataDirectory = paths.dataDirectory
        environment = PythonLocator.resolve(profilePath: profilePath)
    }

    var isAvailable: Bool { environment != nil }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value {
            sendControl(command: "stop")
            stopWorker()
        }
    }

    func reloadSettings(from config: AppConfig) {
        enabled = config.bool(forKey: "background_clip_enabled")
        if !enabled {
            sendControl(command: "stop")
            stopWorker()
        }
    }

    func restartWithPriorityDirectory(_ directory: String?) {
        guard enabled, let directory, !directory.isEmpty else { return }
        let directories = targetDirectories(priority: directory)
        if workerProcess?.isRunning == true {
            sendControl(command: "resume", directories: directories)
        } else {
            startWorker(directories: directories)
        }
    }

    func shutdown() {
        sendControl(command: "stop")
        stopWorker()
    }

    private func targetDirectories(priority: String?) -> [String] {
        var dirs: [String] = []
        if let priority { dirs.append(priority) }
        return Array(Set(dirs))
    }

    private func startWorker(directories: [String]) {
        guard let environment else { return }
        stopWorker()

        do {
            let server = UnixStatusSocketServer(path: statusSocketPath)
            try server.start()
            statusServer = server
        } catch {
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: environment.executable)
        process.arguments = [
            "-u",
            environment.repoRoot.appendingPathComponent("workers/background_clip_worker.py").path,
        ]
        process.currentDirectoryURL = environment.repoRoot
        var env = ProcessInfo.processInfo.environment
        env["PROWSER_PYTHON_ROOT"] = environment.repoRoot.path
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        do {
            try process.run()
            workerProcess = process
        } catch {
            stopWorker()
            return
        }

        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollStatus()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.sendControl(command: "start", directories: directories)
        }
    }

    private func pollStatus() {
        statusServer?.poll()
        if let latest = statusServer?.latestStatus, !latest.isEmpty {
            lastStatus = latest
            status = latest["status"] as? String ?? status
        }
        if let process = workerProcess, !process.isRunning {
            status = "stopped"
        }
    }

    private func sendControl(command: String, directories: [String] = []) {
        let payload: [String: Any] = [
            "command": command,
            "foreground_busy": false,
            "directories": directories,
            "debug_mode": false,
            "last_update": Date().timeIntervalSince1970,
            "status_socket_path": statusSocketPath,
        ]
        try? UnixSocket.sendJSON(path: commandSocketPath, payload: payload)
    }

    private func stopWorker() {
        statusTimer?.invalidate()
        statusTimer = nil
        if let process = workerProcess, process.isRunning {
            process.terminate()
        }
        workerProcess = nil
        statusServer?.stop()
        statusServer = nil
        UnixSocket.removeSocketFile(at: commandSocketPath)
        status = "stopped"
    }
}
