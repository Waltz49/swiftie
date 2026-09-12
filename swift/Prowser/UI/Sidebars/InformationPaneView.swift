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
            themeRevision += 1
            rebuildHTML()
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserInformationAction)) { notification in
            guard let action = notification.userInfo?["action"] as? String else { return }
            switch action {
            case "edit":
                appState.beginEditUserComment()
            case "copy":
                let full = notification.userInfo?["full"] as? Bool ?? false
                appState.copyInformationComment(full: full, preferredText: overlayData.speakablePlainText)
            case "speak":
                speakComment()
            case "delete":
                deleteComment()
            case "create":
                Task {
                    let prompt = await appState.importPromptForActiveImageAsync()
                    appState.openImageGenDialog(initialPrompt: prompt, autoImportEXIF: true)
                }
            case "editai":
                editWithAI()
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
        metadataRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(260))
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
        record = await ExifService.loadRecord(for: path, preferPythonDescription: true)
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
            activeJobHeading: appState.fileData.currentImagePath.map {
                appState.imageGen.activeJobRelationHeading(for: $0)
            } ?? nil,
            contentWidth: max(160, Int(appState.rightSidebarWidth) - 36)
        )
    }

    @MainActor
    private func handleLink(_ action: InformationPaneLinkAction) {
        switch action {
        case .copySeed(let seed):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(seed, forType: .string)
            appState.status.show("Copied seed to clipboard")
        case .toggleSection(let key, let expandAll):
            sectionState.toggleSection(key, expandAll: expandAll)
            rebuildHTML()
        case .refLevel:
            appState.showReferenceGraph()
        case .speak:
            speakComment()
        case .copy(let full):
            appState.copyInformationComment(full: full, preferredText: overlayData.speakablePlainText)
        case .edit:
            appState.beginEditUserComment()
        case .create:
            Task {
                let prompt = await appState.importPromptForActiveImageAsync()
                appState.openImageGenDialog(initialPrompt: prompt, autoImportEXIF: true)
            }
        case .editAI:
            editWithAI()
        case .delete:
            deleteComment()
        case .cancelGeneration:
            appState.confirmCancelGeneration()
        }
    }

    /// Python ``InformationSidebar._on_edit_with_ai`` → ``open_imagegen_edit_dialog``: the unified
    /// dialog opens on Edit for this image, prompt primed from the pane's user comment (an empty
    /// comment clears the prompt), and Import Rest applied automatically.
    @MainActor
    private func editWithAI() {
        guard let path = appState.fileData.currentImagePath,
              FileManager.default.isReadableFile(atPath: path) else {
            appState.status.show("No image selected")
            return
        }
        appState.openImageGenDialog(
            function: "edit",
            initialPrompt: overlayData.speakablePlainText ?? "",
            autoImportEXIF: true,
            editSourcePaths: [path]
        )
    }

    @MainActor
    private func speakComment() {
        let text = overlayData.speakablePlainText ?? ""
        let spoken = ExifService.truncateUserCommentBeforePrompt(text)
        appState.commentSpeaker.speakOrStop(spoken, settings: appState.config.rawSettings())
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
