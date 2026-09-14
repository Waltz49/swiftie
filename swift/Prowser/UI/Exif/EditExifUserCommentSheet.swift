import AppKit
import SwiftUI

/// Full port of `browser_window/dialogs/edit_exif_usercomment_dialog.py` (browser features only).
@MainActor
struct EditExifUserCommentSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.themeColors) private var colors

    @State private var thumbnail: NSImage?

    private var path: String? { appState.editUserCommentPath }
    private var filename: String {
        guard let path else { return "" }
        return (path as NSString).lastPathComponent
    }

    private var hasComment: Bool {
        !appState.editUserCommentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            editorSection
            footerRow
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
        .themeDialogStyle()
        .persistedDialogGeometry(
            DialogGeometryKey.editExifUserComment,
            defaultWidth: 520,
            defaultHeight: 420,
            minWidth: 480,
            minHeight: 320
        )
        .onAppear { loadThumbnail() }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnailView
            VStack(alignment: .leading, spacing: 6) {
                Text(filename)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(3)
                actionBarRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var thumbnailView: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle()
                    .fill(colors.dialogMutedText.opacity(0.15))
            }
        }
        .frame(width: 128, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(colors.defaultBorder, lineWidth: 1)
        )
        .help("Click to open in browse mode")
        .onTapGesture {
            guard let path else { return }
            appState.openImageInBrowse(path: path)
        }
    }

    private var actionBarRow: some View {
        HStack(spacing: 4) {
            assetActionButton(
                "copy",
                normal: "copy",
                hover: "copy_hover",
                tooltip: "Copy prompt to clipboard.\n⌥+click to copy full user comment.",
                enabled: hasComment
            ) {
                copyComment(full: NSEvent.modifierFlags.contains(.option))
            }
            Spacer(minLength: 0)
            assetActionButton(
                "delete",
                normal: "trash_icon",
                hover: "trash_icon_hover",
                tooltip: "Clear comment text",
                enabled: hasComment
            ) {
                appState.editUserCommentText = ""
            }
        }
    }

    private var editorSection: some View {
        TextEditor(text: Binding(
            get: { appState.editUserCommentText },
            set: { appState.editUserCommentText = $0 }
        ))
        .font(.body)
        .frame(minHeight: 180)
        .scrollContentBackground(.hidden)
        .background(colors.dialogInputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var footerRow: some View {
        DialogButtonRow([
            DialogButton("Cancel", isCancel: true) { appState.cancelEditUserComment() },
            DialogButton("Save (⌘↩)", isDefault: true) { appState.saveEditUserComment() },
        ], leadingButtons: [
            DialogButton("Reset", help: "Reset text to original value") {
                appState.editUserCommentText = appState.editUserCommentOriginalText
            },
        ])
        .background(
            Button("") { appState.saveEditUserComment() }
                .keyboardShortcut(.return, modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    private func copyComment(full: Bool) {
        let text = ExifService.userCommentTextForClipboard(appState.editUserCommentText, copyFull: full)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appState.status.show("Copied to clipboard.")
    }

    private func loadThumbnail() {
        guard let path else { return }
        Task {
            if let cg = await appState.thumbnailCache.generateThumbnail(for: path, size: 256) {
                thumbnail = NSImage(cgImage: cg, size: NSSize(width: 128, height: 128))
            }
        }
    }

    private func assetActionButton(
        _ id: String,
        normal: String,
        hover: String,
        tooltip: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        SidebarAssetIconButton(
            normalName: normal,
            hoverName: hover,
            tooltip: tooltip,
            enabled: enabled,
            action: action
        )
        .accessibilityIdentifier(id)
    }
}
