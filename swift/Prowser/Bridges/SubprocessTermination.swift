import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// SIGTERM with optional wait and SIGKILL — port of Python ``terminate_worker_pid`` / Qt ``force_terminate_worker``.
enum SubprocessTermination {
    static let graceSeconds: TimeInterval = 2.0
    static let forceWaitSeconds: TimeInterval = 3.0
    private static let pollInterval: TimeInterval = 0.05

    static func terminateSynchronously(_ process: Process, force: Bool) {
        terminate(process, force: force) { Thread.sleep(forTimeInterval: $0) }
    }

    static func terminate(_ process: Process, force: Bool) async {
        await terminate(process, force: force) { interval in
            let nanos = UInt64(max(0, interval) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
        }
    }

    private static func terminate(
        _ process: Process,
        force: Bool,
        sleep: (TimeInterval) -> Void
    ) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        guard force else { return }
        waitThenKillIfNeeded(process: process, pid: pid, sleep: sleep)
    }

    private static func terminate(
        _ process: Process,
        force: Bool,
        sleep: (TimeInterval) async -> Void
    ) async {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        guard force else { return }
        await waitThenKillIfNeeded(process: process, pid: pid, sleep: sleep)
    }

    private static func waitThenKillIfNeeded(
        process: Process,
        pid: Int32,
        sleep: (TimeInterval) -> Void
    ) {
        let deadline = Date().addingTimeInterval(graceSeconds)
        while process.isRunning, Date() < deadline {
            sleep(pollInterval)
        }
        if process.isRunning {
            #if canImport(Darwin)
            kill(pid, SIGKILL)
            #endif
            let killDeadline = Date().addingTimeInterval(forceWaitSeconds)
            while process.isRunning, Date() < killDeadline {
                sleep(pollInterval)
            }
        }
    }

    private static func waitThenKillIfNeeded(
        process: Process,
        pid: Int32,
        sleep: (TimeInterval) async -> Void
    ) async {
        let deadline = Date().addingTimeInterval(graceSeconds)
        while process.isRunning, Date() < deadline {
            await sleep(pollInterval)
        }
        if process.isRunning {
            #if canImport(Darwin)
            kill(pid, SIGKILL)
            #endif
            let killDeadline = Date().addingTimeInterval(forceWaitSeconds)
            while process.isRunning, Date() < killDeadline {
                await sleep(pollInterval)
            }
        }
    }
}
