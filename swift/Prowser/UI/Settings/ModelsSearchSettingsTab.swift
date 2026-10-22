import AppKit
import SwiftUI

@MainActor
struct ModelsSearchSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var metric = "cosine"
    @State private var resnetModel = "resnet18"
    @State private var clipModel = "openai/clip-vit-base-patch32"
    @State private var statusMessage = ""
    @State private var modelDownloadBaseURL = ""

    private var usingDefaultDownloadURL: Bool {
        appState.config.imageRecognitionModelDownloadBaseURLOverride == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Models for Search").font(.title2)

                SettingsSection(title: "Image Similarity Settings") {
                    Picker("Similarity Metric", selection: $metric) {
                        Text("Cosine").tag("cosine")
                        Text("Euclidean").tag("euclidean")
                        Text("Manhattan").tag("manhattan")
                    }
                    .pickerStyle(.menu)

                    Text("ResNet Model").font(.subheadline.weight(.semibold))
                    RadioRow(title: "ResNet18 (fastest)", tag: "resnet18", selection: $resnetModel)
                    RadioRow(title: "ResNet50 (balanced)", tag: "resnet50", selection: $resnetModel)
                    RadioRow(title: "ResNet101 (best quality)", tag: "resnet101", selection: $resnetModel)
                }

                SettingsSection(title: "Search by Text Settings") {
                    RadioRow(
                        title: "openai/clip-vit-base-patch32 — smaller, faster",
                        tag: "openai/clip-vit-base-patch32",
                        selection: $clipModel
                    )
                    RadioRow(
                        title: "openai/clip-vit-large-patch14 — slower, higher quality",
                        tag: "openai/clip-vit-large-patch14",
                        selection: $clipModel
                    )
                    Text("Larger model uses more memory and time, but is recommended.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsSection(title: "Model delivery") {
                    Text("Download base URL")
                        .font(.subheadline.weight(.semibold))
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        TextField("https://…", text: $modelDownloadBaseURL)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            resetDownloadBaseURLToDefault()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Reset to default download URL")
                        .disabled(usingDefaultDownloadURL && modelDownloadBaseURL == ImageRecognitionDownloadDefaults.defaultBaseURL)
                    }
                    Text(
                        "Search models download automatically on first use (after you approve). "
                            + "\nDefault: \(ImageRecognitionDownloadDefaults.defaultBaseURL). "
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Button("Open models folder in Finder") {
                        openModelsFolder()
                    }
                }

                if !statusMessage.isEmpty {
                    Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .onAppear { loadFromConfig() }
        .onChange(of: metric) { _, new in appState.config.updateSetting("similarity_metric", value: new) }
        .onChange(of: resnetModel) { _, new in
            appState.config.updateSetting("resnet_model", value: new)
            appState.refreshImageRecognitionForCurrentSettings()
            promptDownloadIfNeeded(resnet: new, clip: nil)
        }
        .onChange(of: clipModel) { _, new in
            appState.config.updateSetting("clip_model_name", value: new)
            appState.refreshImageRecognitionForCurrentSettings()
            promptDownloadIfNeeded(resnet: nil, clip: new)
        }
        .onChange(of: modelDownloadBaseURL) { _, new in
            let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == ImageRecognitionDownloadDefaults.defaultBaseURL {
                appState.config.clearImageRecognitionModelDownloadBaseURLOverride()
            } else {
                appState.config.updateSetting(
                    ImageRecognitionDownloadDefaults.settingsOverrideKey,
                    value: trimmed
                )
            }
        }
    }

    private static var preferencesWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "prowser.settings" }
    }

    private func loadFromConfig() {
        metric = appState.config.string(forKey: "similarity_metric", default: "cosine")
        resnetModel = appState.config.string(forKey: "resnet_model", default: "resnet18")
        clipModel = appState.config.string(forKey: "clip_model_name", default: "openai/clip-vit-base-patch32")
        modelDownloadBaseURL = appState.config.imageRecognitionModelDownloadBaseURL()
        ModelManifest.loadUserCatalog(profile: appState.config.profilePaths)
    }

    private func resetDownloadBaseURLToDefault() {
        appState.config.clearImageRecognitionModelDownloadBaseURLOverride()
        modelDownloadBaseURL = ImageRecognitionDownloadDefaults.defaultBaseURL
        statusMessage = "Download URL reset to default."
    }

    private func openModelsFolder() {
        let url = ImageRecognitionPaths.modelsRoot(profile: appState.config.profilePaths)
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent("_mirror", isDirectory: true),
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(url)
    }

    private func promptDownloadIfNeeded(resnet: String?, clip: String?) {
        Task {
            do {
                if let resnet {
                    let ids = ModelManifest.resnetBundleIDs(for: resnet)
                    try await ModelDownloadService.ensureModelsInstalled(
                        profile: appState.config.profilePaths,
                        config: appState.config,
                        modelIDs: ids,
                        purpose: "Download the selected ResNet model for image similarity search.",
                        parentWindow: Self.preferencesWindow
                    )
                }
                if let clip {
                    let ids = ModelManifest.clipBundleIDs(for: clip)
                    try await ModelDownloadService.ensureModelsInstalled(
                        profile: appState.config.profilePaths,
                        config: appState.config,
                        modelIDs: ids,
                        purpose: "Download the selected CLIP model for text search.",
                        parentWindow: Self.preferencesWindow
                    )
                    statusMessage = "CLIP (Search by text) model ready."
                }
                appState.refreshImageRecognitionForCurrentSettings()
            } catch ModelDownloadError.userDeclined {
                statusMessage = "Download cancelled."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private struct RadioRow: View {
        let title: String
        let tag: String
        @Binding var selection: String

        var body: some View {
            Button {
                selection = tag
            } label: {
                HStack {
                    Image(systemName: selection == tag ? "largecircle.fill.circle" : "circle")
                    Text(title)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
    }
}
