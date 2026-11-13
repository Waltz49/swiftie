import Foundation

/// Debounces ``job_queue.json`` writes during burst queue edits.
@MainActor
final class QueuePersistenceCoalescer {
    typealias SaveHandler = (ImageGenQueueFile, AppConfig) -> Void

    private var dirtyFile: ImageGenQueueFile?
    private var dirtyConfig: AppConfig?
    private var flushTask: Task<Void, Never>?
    private var suppressDepth = 0
    private let saveHandler: SaveHandler

    #if DEBUG
    private(set) static var saveInvocationCountForTesting = 0

    static func resetSaveInvocationCountForTesting() {
        saveInvocationCountForTesting = 0
    }
    #endif

    init(saveHandler: @escaping SaveHandler) {
        self.saveHandler = saveHandler
    }

    convenience init() {
        self.init(saveHandler: { file, config in
            JobStepPersistence.saveQueue(file, config: config)
        })
    }

    var isSuppressed: Bool { suppressDepth > 0 }

    func incrementSuppress() {
        suppressDepth += 1
    }

    func decrementSuppress() {
        suppressDepth = max(0, suppressDepth - 1)
    }

    func schedule(file: ImageGenQueueFile, config: AppConfig) {
        guard suppressDepth == 0 else { return }
        dirtyFile = file
        dirtyConfig = config
        flushTask?.cancel()
        flushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 32_000_000)
            guard !Task.isCancelled else { return }
            flushIfDirty()
        }
    }

    func flushNow(file: ImageGenQueueFile, config: AppConfig) {
        guard suppressDepth == 0 else { return }
        flushTask?.cancel()
        flushTask = nil
        dirtyFile = nil
        dirtyConfig = nil
        performSave(file: file, config: config)
    }

    func cancelPending() {
        flushTask?.cancel()
        flushTask = nil
        dirtyFile = nil
        dirtyConfig = nil
    }

    private func flushIfDirty() {
        guard let file = dirtyFile, let config = dirtyConfig else { return }
        dirtyFile = nil
        dirtyConfig = nil
        flushTask = nil
        performSave(file: file, config: config)
    }

    private func performSave(file: ImageGenQueueFile, config: AppConfig) {
        #if DEBUG
        Self.saveInvocationCountForTesting += 1
        #endif
        saveHandler(file, config)
    }
}
