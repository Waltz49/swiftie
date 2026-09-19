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
        /// Optional absolute `https://` or `file://` URL. When empty, use `downloadFile` + base URL or `_mirror/`.
        let downloadURL: String
        /// Zip file name on the download server or in `models/_mirror/`.
        let downloadFile: String?
        let approximateDownloadBytes: Int64
        let artifacts: [Artifact]
        let recommendedBatchSize: Int
        let performanceNote: String?
    }

    struct Catalog: Codable, Sendable {
        let version: Int
        let models: [ModelEntry]
    }

    static var bundledCatalog: Catalog {
        if let loaded = loadBundledCatalog() {
            return loaded
        }
        return embeddedFallbackCatalog
    }

    static func entry(id: String) -> ModelEntry? {
        activeCatalog().models.first { $0.id == id }
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

    /// Joint CLIP embedding size (`projection_dim`); must match cached features and both towers.
    static func clipFeatureDimension(for clipModelName: String) -> Int {
        clipModelName.contains("large-patch14") ? 768 : 512
    }

    /// Avg-pool embedding size for installed ResNet feature models.
    static func resnetFeatureDimension(for resnetModel: String) -> Int {
        switch resnetModel {
        case "resnet50", "resnet101": return 2048
        default: return 512
        }
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
                downloadURL: "",
                downloadFile: "resnet18_feature.zip",
                approximateDownloadBytes: 48_000_000,
                artifacts: [Artifact(fileName: "ResNet18Feature.mlpackage", sha256: "", byteSize: 0)],
                recommendedBatchSize: 16,
                performanceNote: nil
            ),
            ModelEntry(
                id: "resnet50_feature",
                displayName: "ResNet50 (image similarity)",
                kind: .resnetCNN,
                downloadURL: "",
                downloadFile: "resnet50_feature.zip",
                approximateDownloadBytes: 98_000_000,
                artifacts: [Artifact(fileName: "ResNet50Feature.mlpackage", sha256: "", byteSize: 0)],
                recommendedBatchSize: 12,
                performanceNote: "Slower than ResNet18; better quality on difficult matches."
            ),
            ModelEntry(
                id: "resnet101_feature",
                displayName: "ResNet101 (image similarity)",
                kind: .resnetCNN,
                downloadURL: "",
                downloadFile: "resnet101_feature.zip",
                approximateDownloadBytes: 170_000_000,
                artifacts: [Artifact(fileName: "ResNet101Feature.mlpackage", sha256: "", byteSize: 0)],
                recommendedBatchSize: 8,
                performanceNote: "Slowest ResNet option; use on capable machines."
            ),
            ModelEntry(
                id: "clip_vit_b32_image",
                displayName: "CLIP ViT-B/32 (image tower)",
                kind: .clipImage,
                downloadURL: "",
                downloadFile: "clip_vit_b32_image.zip",
                approximateDownloadBytes: 180_000_000,
                artifacts: [Artifact(fileName: "CLIPViTB32Image.mlpackage", sha256: "", byteSize: 0)],
                recommendedBatchSize: 16,
                performanceNote: nil
            ),
            ModelEntry(
                id: "clip_vit_b32_text",
                displayName: "CLIP ViT-B/32 (text tower)",
                kind: .clipText,
                downloadURL: "",
                downloadFile: "clip_vit_b32_text.zip",
                approximateDownloadBytes: 120_000_000,
                artifacts: [
                    Artifact(fileName: "CLIPViTB32Text.mlpackage", sha256: "", byteSize: 0),
                    Artifact(fileName: "clip_vocab.json", sha256: "", byteSize: 0),
                    Artifact(fileName: "clip_merges.txt", sha256: "", byteSize: 0),
                ],
                recommendedBatchSize: 1,
                performanceNote: nil
            ),
            ModelEntry(
                id: "clip_vit_l14_image",
                displayName: "CLIP ViT-L/14 (image tower)",
                kind: .clipImage,
                downloadURL: "",
                downloadFile: "clip_vit_l14_image.zip",
                approximateDownloadBytes: 900_000_000,
                artifacts: [Artifact(fileName: "CLIPViTL14Image.mlpackage", sha256: "", byteSize: 0)],
                recommendedBatchSize: 8,
                performanceNote: "Large download and higher memory use; slower on 16 GB Macs."
            ),
            ModelEntry(
                id: "clip_vit_l14_text",
                displayName: "CLIP ViT-L/14 (text tower)",
                kind: .clipText,
                downloadURL: "",
                downloadFile: "clip_vit_l14_text.zip",
                approximateDownloadBytes: 450_000_000,
                artifacts: [
                    Artifact(fileName: "CLIPViTL14Text.mlpackage", sha256: "", byteSize: 0),
                    Artifact(fileName: "clip_vocab.json", sha256: "", byteSize: 0),
                    Artifact(fileName: "clip_merges.txt", sha256: "", byteSize: 0),
                ],
                recommendedBatchSize: 1,
                performanceNote: "Large download; pair with ViT-L/14 image tower."
            ),
        ]
    )
}
