import SwiftUI

@MainActor
struct ModelsSearchSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var metric = "cosine"
    @State private var resnetModel = "resnet18"
    @State private var clipModel = "openai/clip-vit-base-patch32"
    @State private var statusMessage = ""

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
                    Text("Larger CLIP uses more memory and time on 16 GB Macs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            appState.imageRecognition.rebind(config: appState.config)
            promptDownloadIfNeeded(resnet: new, clip: nil)
        }
        .onChange(of: clipModel) { _, new in
            appState.config.updateSetting("clip_model_name", value: new)
            appState.imageRecognition.rebind(config: appState.config)
            promptDownloadIfNeeded(resnet: nil, clip: new)
        }
    }

    private func loadFromConfig() {
        metric = appState.config.string(forKey: "similarity_metric", default: "cosine")
        resnetModel = appState.config.string(forKey: "resnet_model", default: "resnet18")
        clipModel = appState.config.string(forKey: "clip_model_name", default: "openai/clip-vit-base-patch32")
    }

    private func promptDownloadIfNeeded(resnet: String?, clip: String?) {
        Task {
            do {
                if let resnet {
                    let ids = ModelManifest.resnetBundleIDs(for: resnet)
                    try await ModelDownloadService.ensureModelsInstalled(
                        profile: appState.config.profilePaths,
                        modelIDs: ids,
                        purpose: "Download the selected ResNet model for image similarity search."
                    )
                }
                if let clip {
                    let ids = ModelManifest.clipBundleIDs(for: clip)
                    try await ModelDownloadService.ensureModelsInstalled(
                        profile: appState.config.profilePaths,
                        modelIDs: ids,
                        purpose: "Download the selected CLIP model for text search."
                    )
                    statusMessage = "CLIP model ready."
                }
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
