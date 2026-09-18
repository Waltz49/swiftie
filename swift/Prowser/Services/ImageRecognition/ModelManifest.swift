import Foundation

/// Bundled catalog of downloadable Core ML search models.
enum ModelManifest {
    enum ModelKind: String, Codable, Sendable {
        case resnetCNN
        case clipImage
        case clipText
    }

    struct Artifact: Codable, Sendable {
        let fileName: String
        let sha256: String
        let byteSize: Int64
    }

    struct ModelEntry: Codable, Sendable, Identifiable {
        let id: String
        let displayName: String
        let kind: ModelKind
        let downloadURL: String
        let approximateDownloadBytes: Int64
        let artifacts: [Artifact]
        let recommendedBatchSize: Int
        let performanceNote: String?
    }

    struct Catalog: Codable, Sendable {
        let version: Int
        let models: [ModelEntry]
    }

    static let catalog: Catalog = {
        if let loaded = loadBundledCatalog() {
            return loaded
        }
        return embeddedFallbackCatalog
    }()

    static func entry(id: String) -> ModelEntry? {
        catalog.models.first { $0.id == id }
    }

    /// True when the manifest points at a real HTTPS host (not placeholder `example.invalid`).
    static func isRemoteDownloadAvailable(for entry: ModelEntry) -> Bool {
        guard let url = URL(string: entry.downloadURL),
              url.scheme == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty else { return false }
        if host == "example.invalid" || host.hasSuffix(".invalid") { return false }
        return true
    }

    static func isRemoteDownloadAvailable(modelIDs: [String]) -> Bool {
        let entries = modelIDs.compactMap { entry(id: $0) }
        guard entries.count == modelIDs.count, !entries.isEmpty else { return false }
        return entries.allSatisfy { isRemoteDownloadAvailable(for: $0) }
    }

    static func resnetBundleIDs(for resnetModel: String) -> [String] {
        switch resnetModel {
        case "resnet50": return ["resnet50_feature"]
        case "resnet101": return ["resnet101_feature"]
        default: return ["resnet18_feature"]
        }
    }

    static func clipBundleIDs(for clipModelName: String) -> [String] {
        if clipModelName.contains("large-patch14") {
            return ["clip_vit_l14_image", "clip_vit_l14_text"]
        }
        return ["clip_vit_b32_image", "clip_vit_b32_text"]
    }

    private static func loadBundledCatalog() -> Catalog? {
        guard let url = Bundle.main.url(forResource: "image_recognition_models", withExtension: "json") else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Catalog.self, from: data)
    }

    /// Used when the JSON resource is missing (e.g. tests); URLs are placeholders until hosting is configured.
    private static let embeddedFallbackCatalog = Catalog(
        version: 1,
        models: [
            ModelEntry(
                id: "resnet18_feature",
                displayName: "ResNet18 (image similarity)",
                kind: .resnetCNN,
                downloadURL: "https://example.invalid/prowser/models/resnet18_feature.zip",
                approximateDownloadBytes: 48_000_000,
                artifacts: [Artifact(fileName: "ResNet18Feature.mlpackage", sha256: "", byteSize: 0)],
                recommendedBatchSize: 16,
                performanceNote: nil
            ),
            ModelEntry(
                id: "resnet50_feature",
                displayName: "ResNet50 (image similarity)",
                kind: .resnetCNN,
                downloadURL: "https://example.invalid/prowser/models/resnet50_feature.zip",
                approximateDownloadBytes: 98_000_000,
                artifacts: [Artifact(fileName: "ResNet50Feature.mlpackage", sha256: "", byteSize: 0)],
                recommendedBatchSize: 12,
                performanceNote: "Slower than ResNet18; better quality on difficult matches."
            ),
            ModelEntry(
                id: "resnet101_feature",
                displayName: "ResNet101 (image similarity)",
                kind: .resnetCNN,
                downloadURL: "https://example.invalid/prowser/models/resnet101_feature.zip",
                approximateDownloadBytes: 170_000_000,
                artifacts: [Artifact(fileName: "ResNet101Feature.mlpackage", sha256: "", byteSize: 0)],
                recommendedBatchSize: 8,
                performanceNote: "Slowest ResNet option; use on capable machines."
            ),
            ModelEntry(
                id: "clip_vit_b32_image",
                displayName: "CLIP ViT-B/32 (image tower)",
                kind: .clipImage,
                downloadURL: "https://example.invalid/prowser/models/clip_vit_b32_image.zip",
                approximateDownloadBytes: 180_000_000,
                artifacts: [Artifact(fileName: "CLIPViTB32Image.mlpackage", sha256: "", byteSize: 0)],
                recommendedBatchSize: 16,
                performanceNote: nil
            ),
            ModelEntry(
                id: "clip_vit_b32_text",
                displayName: "CLIP ViT-B/32 (text tower)",
                kind: .clipText,
                downloadURL: "https://example.invalid/prowser/models/clip_vit_b32_text.zip",
                approximateDownloadBytes: 120_000_000,
                artifacts: [Artifact(fileName: "CLIPViTB32Text.mlpackage", sha256: "", byteSize: 0)],
                recommendedBatchSize: 1,
                performanceNote: nil
            ),
            ModelEntry(
                id: "clip_vit_l14_image",
                displayName: "CLIP ViT-L/14 (image tower)",
                kind: .clipImage,
                downloadURL: "https://example.invalid/prowser/models/clip_vit_l14_image.zip",
                approximateDownloadBytes: 900_000_000,
                artifacts: [Artifact(fileName: "CLIPViTL14Image.mlpackage", sha256: "", byteSize: 0)],
                recommendedBatchSize: 8,
                performanceNote: "Large download and higher memory use; slower on 16 GB Macs."
            ),
            ModelEntry(
                id: "clip_vit_l14_text",
                displayName: "CLIP ViT-L/14 (text tower)",
                kind: .clipText,
                downloadURL: "https://example.invalid/prowser/models/clip_vit_l14_text.zip",
                approximateDownloadBytes: 450_000_000,
                artifacts: [Artifact(fileName: "CLIPViTL14Text.mlpackage", sha256: "", byteSize: 0)],
                recommendedBatchSize: 1,
                performanceNote: "Large download; pair with ViT-L/14 image tower."
            ),
        ]
    )
}
