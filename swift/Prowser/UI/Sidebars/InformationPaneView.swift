import SwiftUI

struct InformationPaneView: View {
    @Environment(AppState.self) private var appState
    @State private var record: ExifRecord = .empty
    @State private var showEditComment = false
    @State private var editCommentText = ""
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

                        if !appState.informationMenuBarVisible {
                            HStack {
                                Button("Edit Comment") { beginEditComment() }
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
            reload(path: newPath)
        }
        .onAppear {
            reload(path: appState.fileData.currentImagePath)
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserEditUserCommentRequested)) { _ in
            Task { @MainActor in beginEditComment() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .prowserInformationAction)) { notification in
            guard let action = notification.userInfo?["action"] as? String else { return }
            switch action {
            case "edit":
                beginEditComment()
            case "copy":
                copyComment()
            case "delete":
                deleteComment()
            case "create":
                appState.showImageGenCreateSheet = true
            default:
                break
            }
        }
        .sheet(isPresented: $showEditComment) {
            EditUserCommentSheet(
                text: $editCommentText,
                onSave: { saveComment() },
                onCancel: { showEditComment = false }
            )
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

    private func reload(path: String?) {
        guard let path else {
            record = .empty
            return
        }
        record = ExifService.loadRecord(for: path)
    }

    @MainActor
    private func beginEditComment() {
        guard let path = appState.fileData.currentImagePath else { return }
        editCommentText = ExifService.userComment(path: path) ?? ""
        showEditComment = true
    }

    @MainActor
    private func saveComment() {
        guard let path = appState.fileData.currentImagePath else { return }
        do {
            try ExifService.writeUserComment(path: path, text: editCommentText)
            showEditComment = false
            reload(path: path)
            appState.refreshDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyComment() {
        guard let text = record.description else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    private func deleteComment() {
        guard let path = appState.fileData.currentImagePath else { return }
        do {
            try ExifService.deleteUserComment(path: path)
            reload(path: path)
            appState.refreshDirectory()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct EditUserCommentSheet: View {
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit EXIF User Comment")
                .font(.headline)
            TextEditor(text: $text)
                .font(.body)
                .frame(minWidth: 420, minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }
}
