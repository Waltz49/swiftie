import AppKit
import SwiftUI

struct ManageModelsDetailView: View {
    @Environment(\.themeColors) private var colors
    @Environment(AppState.self) private var appState

    let entry: ImageGenModelDownloadCatalogEntry
    var installed: Bool
    var onClose: () -> Void
    var onCatalogChanged: () -> Void

    @State private var hfToken = ""
    @State private var scriptText = ""
    @State private var busy = false

    private var resolvedToken: String {
        let typed = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return (ProcessInfo.processInfo.environment["HF_TOKEN"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var tokenPlaceholder: String {
        if !(ProcessInfo.processInfo.environment["HF_TOKEN"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "(HF_TOKEN is set in environment)"
        }
        return "Optional if already logged in"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Repository: \(entry.repoID)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(colors.dialogMutedText)
                .textSelection(.enabled)

            if installed {
                installedPanel
            } else {
                installPanel
            }

            DialogButtonRow(
                [DialogButton("Close", isDefault: true, isCancel: true, action: onClose)],
                focusDefaultOnAppear: true,
                layout: .evenlySpaced
            )
            .padding(.top, 4)
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: installed ? 220 : 420)
        .themeDialogStyle()
        .onAppear { refreshScript() }
        .onChange(of: hfToken) { _, _ in refreshScript() }
    }

    @ViewBuilder
    private var installedPanel: some View {
        Text("This model is installed on your machine.")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Color(red: 0.35, green: 0.78, blue: 0.45))

        if entry.gated {
            Text("Gated model — accept the license on Hugging Face and provide a token to reinstall.")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.85, green: 0.72, blue: 0.35))
        }

        if entry.gated {
            hfTokenRow
        }

        DialogButtonRow(
            [
                DialogButton("Reinstall…", isEnabled: !busy) {
                    Task { @MainActor in startDownload(force: true, proceedLabel: "Reinstall") }
                },
                DialogButton("Delete model…", isEnabled: !busy) {
                    Task { @MainActor in confirmDelete() }
                },
            ],
            layout: .inline
        )
    }

    @ViewBuilder
    private var installPanel: some View {
        Text("Estimated download size: \(entry.formattedSizeEstimate())")
            .font(.system(size: 13))

        if entry.gated {
            Text("Gated model — accept the license on Hugging Face and provide a token.")
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.85, green: 0.72, blue: 0.35))
        }

        hfTokenRow

        HStack(spacing: 8) {
            DialogButtonRow(
                [
                    DialogButton("Download", isEnabled: !busy) {
                        Task { @MainActor in startDownload(force: false, proceedLabel: "Download") }
                    },
                    DialogButton("Full download", isEnabled: !busy) {
                        Task { @MainActor in startDownload(force: true, proceedLabel: "Full download") }
                    },
                ],
                layout: .inline
            )
            Button {
                Task { @MainActor in copyScript() }
            } label: {
                Image(systemName: "square.on.square")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.bordered)
            .help("Copy script to clipboard")
            .disabled(busy)
        }

        ScrollView([.vertical, .horizontal]) {
            Text(scriptText)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.buttonBgDefault.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var hfTokenRow: some View {
        HStack(spacing: 8) {
            Text("HF token:")
                .foregroundStyle(colors.dialogMutedText)
            SecureField(tokenPlaceholder, text: $hfToken)
                .textFieldStyle(.roundedBorder)
        }
    }

    @MainActor
    private func refreshScript() {
        scriptText = ImageGenModelDownloadScriptBuilder.buildSingleModelDownloadScript(
            repoID: entry.repoID,
            imagegenPythonPath: appState.config.imagegenVenvPythonPath(),
            hfToken: resolvedToken.isEmpty ? nil : resolvedToken,
            forceDownload: false
        )
    }

    @MainActor
    private func copyScript() {
        let text = ImageGenModelDownloadScriptBuilder.buildSingleModelDownloadScript(
            repoID: entry.repoID,
            imagegenPythonPath: appState.config.imagegenVenvPythonPath(),
            hfToken: resolvedToken.isEmpty ? nil : resolvedToken,
            forceDownload: false
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    private func confirmDownload(force: Bool, proceedLabel: String) -> Bool {
        let sizeText = entry.formattedSizeEstimate()
        let modelURL = "https://huggingface.co/\(entry.repoID)"
        var message = """
        \(entry.displayName) may be large (estimated \(sizeText)).

        The model may no longer be available on Hugging Face, or its license terms may have changed. Check the model page before proceeding.

        \(entry.repoID)
        \(modelURL)

        """
        if force {
            message += "All cached files will be re-downloaded (--force-download).\n\n"
        }
        message += """
        The download runs in the background so Prowser stays responsive. A progress window will appear and you can cancel if needed. Partial downloads resume later.

        Proceed with \(proceedLabel.lowercased())?
        """
        return StyledMessageDialog.showOkCancel(
            title: "\(proceedLabel) model?",
            message: message,
            defaultCancel: true
        )
    }

    @MainActor
    private func startDownload(force: Bool, proceedLabel: String) {
        guard confirmDownload(force: force, proceedLabel: proceedLabel) else { return }
        if entry.gated, resolvedToken.isEmpty {
            StyledMessageDialog.showWarning(
                title: "HF token required",
                message: "This gated model needs a Hugging Face token. Enter one in the HF token field or set HF_TOKEN in your environment."
            )
            return
        }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await ImageGenModelDownloadRunner.download(
                    entry: entry,
                    config: appState.config,
                    hfToken: hfToken,
                    forceDownload: force,
                    parentWindow: nil
                )
                StyledMessageDialog.showInformation(
                    title: "Download complete",
                    message: "\(entry.displayName) was downloaded to your Hugging Face cache."
                )
                onCatalogChanged()
                onClose()
            } catch ImageGenModelDownloadError.cancelled {
                return
            } catch {
                StyledMessageDialog.showCritical(
                    title: "Download failed",
                    message: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                )
            }
        }
    }

    @MainActor
    private func confirmDelete() {
        let size = entry.formattedSizeEstimate()
        guard StyledMessageDialog.showQuestion(
            title: "Delete model?",
            message: "Delete \(entry.displayName) from your Hugging Face cache?\n\nThis frees about \(size) of disk space.",
            defaultNo: true
        ) else { return }
        guard StyledMessageDialog.showQuestion(
            title: "Confirm delete",
            message: "Are you sure you want to permanently delete \(entry.displayName)? You will need to download it again to use it.",
            defaultNo: true
        ) else { return }

        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let deleted = try await ImageGenModelDownloadRunner.deleteFromHFCache(
                    repoID: entry.repoID,
                    config: appState.config
                )
                ImageGenHFModelLocality.invalidateCache(repoID: entry.repoID, pipelineID: entry.pipelineID)
                if !deleted {
                    StyledMessageDialog.showWarning(
                        title: "Delete failed",
                        message: "No cached files were found for \(entry.repoID)."
                    )
                    return
                }
                StyledMessageDialog.showInformation(
                    title: "Model deleted",
                    message: "\(entry.displayName) was removed from the Hugging Face cache."
                )
                onCatalogChanged()
                onClose()
            } catch {
                StyledMessageDialog.showCritical(
                    title: "Delete failed",
                    message: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                )
            }
        }
    }
}
