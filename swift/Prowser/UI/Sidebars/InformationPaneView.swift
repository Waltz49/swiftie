import SwiftUI

struct InformationPaneView: View {
    @Environment(AppState.self) private var appState
    @State private var record: ExifRecord = .empty
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.fileData.currentImagePath == nil {
                Text("No image selected")
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        section("File") {
                            infoRow("Name", record.fileName)
                            infoRow("Directory", (record.directory as NSString).abbreviatingWithTildeInPath)
                            infoRow("Size", record.fileSize)
                            infoRow("File Date", record.fileDate)
                            infoRow("Image Size", record.imageSize)
                        }

                        if hasExifSection {
                            section("EXIF") {
                                if let exifDate = record.exifDate { infoRow("EXIF Date", exifDate) }
                                if let camera = record.camera { infoRow("Camera", camera) }
                                if let lens = record.lens { infoRow("Lens", lens) }
                                if let orientation = record.orientation { infoRow("Orientation", orientation) }
                                if let location = record.location { infoRow("Location", location) }
                                if let exposure = record.exposure { infoRow("Exposure", exposure) }
                                if let aperture = record.aperture { infoRow("Aperture", aperture) }
                                if let iso = record.iso { infoRow("ISO", iso) }
                                if let focal = record.focalLength { infoRow("Focal Length", focal) }
                                if let software = record.software { infoRow("Software", software) }
                                if let artist = record.artist { infoRow("Artist", artist) }
                            }
                        }

                        if let description = record.description, !description.isEmpty {
                            section("Description") {
                                Text(description)
                                    .font(.body)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if appState.imageGen.isProcessing {
                            HStack {
                                Text(appState.imageGen.progressMessage.isEmpty ? "Generation in progress…" : appState.imageGen.progressMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Cancel generation") {
                                    appState.confirmCancelGeneration()
                                }
                                .font(.caption)
                            }
                        }

                        if !appState.informationMenuBarVisible {
                            HStack {
                                Button("Edit Comment") { appState.beginEditUserComment() }
                                Button("Copy Comment") { copyComment() }
                                Button("Delete Comment") { deleteComment() }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .onChange(of: appState.fileData.currentImagePath) { _, newPath in
            Task { await reload(path: newPath) }
        }
        .onAppear {
            Task { await reload(path: appState.fileData.currentImagePath) }
        }
        .onChange(of: appState.showEditUserCommentSheet) { _, showing in
            if !showing {
                Task { await reload(path: appState.fileData.currentImagePath) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserInformationAction)) { notification in
            guard let action = notification.userInfo?["action"] as? String else { return }
            switch action {
            case "edit":
                appState.beginEditUserComment()
            case "copy":
                copyComment()
            case "delete":
                deleteComment()
            case "create":
                Task {
                    let prompt = await appState.importPromptForActiveImageAsync()
                    appState.openImageGenDialog(initialPrompt: prompt, autoImportEXIF: true)
                }
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

    private var hasExifSection: Bool {
        record.exifDate != nil || record.camera != nil || record.lens != nil
            || record.orientation != nil || record.location != nil || record.exposure != nil
            || record.aperture != nil || record.iso != nil || record.focalLength != nil
            || record.software != nil || record.artist != nil
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
    }

    @MainActor
    private func reload(path: String?) async {
        guard let path else {
            record = .empty
            return
        }
        record = await ExifService.loadRecord(for: path, preferPythonDescription: true)
    }

    private func copyComment() {
        guard let text = record.description else { return }
        let clipboard = ExifService.userCommentTextForClipboard(text)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clipboard, forType: .string)
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
