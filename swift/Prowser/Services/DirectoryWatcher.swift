import Foundation

/// Watches the current directory for changes and debounces refresh. Port of `directory_watch_manager.py`.
@MainActor
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var watchedPath: String?
    private var debounceTask: Task<Void, Never>?
    private let debounceNanos: UInt64 = 300_000_000
    var onRefresh: (() -> Void)?

    func watch(directory: String?) {
        guard let directory else {
            stop()
            return
        }
        let path = URL(fileURLWithPath: directory).standardizedFileURL.path
        if watchedPath == path, source != nil {
            return
        }
        stop()
        let fd = open(path, O_EVTONLY)
        if fd < 0 { return }

        watchedFD = fd
        watchedPath = path
        let queue = DispatchQueue.main
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .link, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        source?.cancel()
        source = nil
        watchedFD = -1
        watchedPath = nil
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: debounceNanos)
            guard !Task.isCancelled else { return }
            onRefresh?()
        }
    }

    deinit {
        source?.cancel()
    }
}
