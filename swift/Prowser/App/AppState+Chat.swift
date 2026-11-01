import Foundation

extension AppState {
    var isChatVisible: Bool {
        BundleCapabilities.chatUIEnabled
            && config.bool(forKey: "chat_visible", default: false)
    }

    /// Reserved for future finer-grained ⌘R routing; chat redo uses pane visibility today.

    func bindChatNotifications() {
        NotificationCenter.default.addObserver(
            forName: .prowserChatOpenImagePaths,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            Task { @MainActor in
                self.openChatImagePaths(note: note)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .prowserChatInsertUserPrompt,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            Task { @MainActor in
                self.chat.applyFavoriteUserPrompt(note: note)
            }
        }
    }

    func openChatImagePaths(note: Notification) {
        guard let paths = note.userInfo?["paths"] as? [String], !paths.isEmpty else { return }
        let readable = paths.filter { FileManager.default.isReadableFile(atPath: $0) }
        guard !readable.isEmpty else { return }
        if readable.count == 1 {
            let path = readable[0]
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            loadDirectory(dir, saveHistory: true)
            fileData.setCurrentImagePath(path)
            fileData.setViewMode(.browse)
            return
        }
        setSpecificFilesActive(true)
        fileData.setDisplayedImages(readable)
        fileData.setCurrentImagePath(readable[0])
        if let dir = note.userInfo?["directory"] as? String, !dir.isEmpty {
            fileData.setCurrentDirectory(dir)
        } else if let first = readable.first {
            fileData.setCurrentDirectory(URL(fileURLWithPath: first).deletingLastPathComponent().path)
        }
        if let dir = fileData.currentDirectory {
            eventBus.emit(.directoryLoaded, payload: .string(dir))
        }
    }

    func toggleChat() {
        guard BundleCapabilities.chatUIEnabled else { return }
        let visible = config.bool(forKey: "chat_visible", default: false)
        config.updateSetting("chat_visible", value: !visible)
        if !visible {
            revealSidebarColumn(.left)
        }
        noteSidebarLayoutChanged()
    }

    func setChatVisible(_ visible: Bool) {
        guard BundleCapabilities.chatUIEnabled else { return }
        let current = config.bool(forKey: "chat_visible", default: false)
        guard current != visible else { return }
        config.updateSetting("chat_visible", value: visible)
        if visible {
            revealSidebarColumn(.left)
        }
        noteSidebarLayoutChanged()
    }

    func openLmStudioOrShowInstallHelp() {
        LmStudioLauncher.openOrShowInstallHelp()
    }
}
