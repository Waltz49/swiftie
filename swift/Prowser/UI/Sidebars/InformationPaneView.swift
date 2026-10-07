import SwiftUI

struct InformationPaneView: View {
    @Environment(AppState.self) private var appState
    @State private var record: ExifRecord = .empty
    @State private var overlayData = InformationOverlayData(filename: "", fieldValuePairs: [])
    @State private var content: InformationPaneContent?
    @State private var errorMessage: String?
    @State private var metadataRefreshTask: Task<Void, Never>?
    @State private var fileMetadataToken: UUID?
    @State private var scrollCoordinator = InformationPaneScrollCoordinator()

    private var sectionState: InformationSectionState {
        appState.informationSectionState
    }

    var body: some View {
        Group {
            if appState.fileData.currentImagePath == nil {
                Text("No image selected")
                    .foregroundStyle(appState.theme.colors.sidebarMutedText)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 15)
                Spacer()
            } else if content == nil {
                Spacer()
            } else if let content {
                InformationPaneContentView(
                    content: content,
                    colors: appState.theme.colors,
                    onToggleSection: { key, expandAll in
                        handleLink(.toggleSection(key, expandAll: expandAll))
                    },
                    onCopySeed: { seed in
                        handleLink(.copySeed(seed))
                    },
                    onReferenceLevel: { optionHeld in
                        handleLink(.refLevel(optionHeld: optionHeld))
                    }
                )
                .environment(\.informationPaneScrollCoordinator, scrollCoordinator)
            }
        }
        .onChange(of: appState.fileData.currentImagePath) { _, newPath in
            scheduleReload(path: newPath)
        }
        .onAppear {
            fileMetadataToken = appState.eventBus.subscribe(.fileMetadataChanged) { event in
                guard case .string(let path) = event.payload else { return }
                guard let current = appState.fileData.currentImagePath else { return }
                if URL(fileURLWithPath: path).standardizedFileURL.path
                    == URL(fileURLWithPath: current).standardizedFileURL.path {
                    scheduleReload(path: current)
                }
            }
            scheduleReload(path: appState.fileData.currentImagePath)
        }
        .onDisappear {
            if let fileMetadataToken {
                appState.eventBus.unsubscribe(.fileMetadataChanged, token: fileMetadataToken)
            }
        }
        .onChange(of: appState.showEditUserCommentSheet) { _, showing in
            if !showing {
                scheduleReload(path: appState.fileData.currentImagePath)
            }
        }
        .onChange(of: appState.theme.colors) { _, _ in
            rebuildContent()
        }
        .onChange(of: appState.imageGenUIRevision) { _, _ in
            rebuildContent()
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserInformationAction)) { notification in
            guard let action = notification.userInfo?["action"] as? String else { return }
            switch action {
            case "edit":
                appState.beginEditUserComment()
            case "copy":
                let full = notification.userInfo?["full"] as? Bool ?? false
                appState.copyInformationComment(full: full, preferredText: overlayData.speakablePlainText)
            case "delete":
                deleteComment()
            default:
                break
            }
        }
        .alert("EXIF Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func scheduleReload(path: String?) {
        metadataRefreshTask?.cancel()
        metadataRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(TimingConstants.metadataOverlayRefreshDebounceMs))
            guard !Task.isCancelled else { return }
            await reload(path: path)
        }
    }

    @MainActor
    private func reload(path: String?) async {
        guard let path else {
            record = .empty
            overlayData = InformationOverlayData(filename: "", fieldValuePairs: [])
            content = nil
            return
        }
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let current = appState.fileData.currentImagePath.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }
        guard current == normalizedPath else { return }
        record = await ExifService.loadRecord(for: path, preferPythonDescription: true)
        guard !Task.isCancelled,
              appState.fileData.currentImagePath.map({
                  URL(fileURLWithPath: $0).standardizedFileURL.path
              }) == normalizedPath else { return }
        overlayData = InformationOverlayBuilder.buildOverlayData(
            from: record,
            imageDirectory: (path as NSString).deletingLastPathComponent,
            imagePath: path
        )
        rebuildContent()
    }

    @MainActor
    private func rebuildContent() {
        guard appState.fileData.currentImagePath != nil else {
            content = nil
            return
        }
        let activeJobHeading = appState.fileData.currentImagePath.flatMap {
            appState.imageGen.activeJobRelationHeading(for: $0)
        }
        content = InformationPaneLayoutBuilder.buildContent(
            data: overlayData,
            sectionState: sectionState,
            activeJobHeading: activeJobHeading,
            contentWidth: max(160, Int(appState.rightSidebarWidth) - 36)
        )
        scrollCoordinator.restoreOffset()
    }

    @MainActor
    private func handleLink(_ action: InformationPaneLinkAction) {
        switch action {
        case .copySeed(let seed):
            appState.copyTextToClipboard(seed)
        case .toggleSection(let key, let expandAll):
            scrollCoordinator.captureOffset()
            sectionState.toggleSection(key, expandAll: expandAll)
            rebuildContent()
        case .refLevel(let optionHeld):
            appState.handleInformationReferenceLevelClick(optionHeld: optionHeld)
        case .copy(let full):
            appState.copyInformationComment(full: full, preferredText: overlayData.speakablePlainText)
        case .edit:
            appState.beginEditUserComment()
        case .delete:
            deleteComment()
        }
    }

    @MainActor
    private func deleteComment() {
        guard let path = appState.fileData.currentImagePath else { return }
        Task {
            do {
                try await ExifService.deleteUserComment(path: path)
                await reload(path: path)
                appState.refreshDirectory()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
