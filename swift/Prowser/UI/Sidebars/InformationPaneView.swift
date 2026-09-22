import SwiftUI

struct InformationPaneView: View {
    @Environment(AppState.self) private var appState
    @State private var record: ExifRecord = .empty
    @State private var overlayData = InformationOverlayData(filename: "", fieldValuePairs: [])
    @State private var html = ""
    @State private var errorMessage: String?
    @State private var metadataRefreshTask: Task<Void, Never>?
    @State private var fileMetadataToken: UUID?
    @State private var themeRevision = 0

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
            } else if html.isEmpty {
                Spacer()
            } else {
                InformationPaneWebView(html: html) { action, _ in
                    handleLink(action)
                }
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
            Task { @MainActor in
                themeRevision += 1
                rebuildHTML()
            }
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
            html = ""
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
        overlayData = InformationPaneHTMLBuilder.buildOverlayData(
            from: record,
            imageDirectory: (path as NSString).deletingLastPathComponent,
            imagePath: path
        )
        rebuildHTML()
    }

    @MainActor
    private func rebuildHTML() {
        guard appState.fileData.currentImagePath != nil else {
            html = ""
            return
        }
            html = InformationPaneHTMLBuilder.buildHTML(
            data: overlayData,
            colors: appState.theme.colors,
            sectionState: sectionState,
            activeJobHeading: nil,
            contentWidth: max(160, Int(appState.rightSidebarWidth) - 36)
        )
    }

    @MainActor
    private func handleLink(_ action: InformationPaneLinkAction) {
        switch action {
        case .copySeed(let seed):
            appState.copyTextToClipboard(seed)
        case .toggleSection(let key, let expandAll):
            sectionState.toggleSection(key, expandAll: expandAll)
            rebuildHTML()
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
