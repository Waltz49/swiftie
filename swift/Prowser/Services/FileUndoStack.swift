import Foundation

struct DeletedFileUndoEntry: Sendable {
    let originalPath: String
    var trashPath: String?
    let originalIndex: Int?
    let fileSize: Int64?
    let fileInode: UInt64?
    let modificationDate: Date?
}

struct MovedFileUndoEntry: Sendable {
    let sourcePath: String
    let targetPath: String
    let originalPosition: Int?
}

enum FileUndoOperation: Sendable {
    case delete([DeletedFileUndoEntry])
    case move([MovedFileUndoEntry])
}

/// Chronological undo stack for file delete (port of Python `file_undo_stack`).
@MainActor
final class FileUndoStack {
    private var stack: [FileUndoOperation] = []

    var canUndo: Bool { !stack.isEmpty }

    func pushDelete(_ entries: [DeletedFileUndoEntry]) {
        guard !entries.isEmpty else { return }
        stack.append(.delete(entries))
    }

    func pushMove(_ entries: [MovedFileUndoEntry]) {
        guard !entries.isEmpty else { return }
        stack.append(.move(entries))
    }

    func backfillTrashPath(originalPath: String, trashPath: String) {
        guard let last = stack.last, case .delete(var entries) = last else { return }
        for index in entries.indices where entries[index].originalPath == originalPath {
            entries[index].trashPath = trashPath
        }
        stack[stack.count - 1] = .delete(entries)
    }

    func pop() -> FileUndoOperation? {
        stack.popLast()
    }

    func clear() {
        stack.removeAll()
    }
}
