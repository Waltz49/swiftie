import Foundation
import XCTest
@testable import Prowser

final class LoRAEntryMetadataTests: XCTestCase {
    func testLoadLegacyEntryWithoutNewKeys() {
        let raw: [String: Any] = [
            "host_id": "flux1_t2i",
            "lora_id": "user_test",
            "display_name": "Test",
            "repo_id": "",
            "filename": "",
            "scale": 1.0,
            "best_guess": 0.8,
            "local_path": "/tmp/user_test/lora.safetensors",
            "base_hf_model_id": "black-forest-labs/FLUX.1-dev",
            "min_steps": 2,
            "trigger_word": "tok",
            "legacy_extra": "keep-me",
        ]
        let entry = LoRAEntry.fromDictionary(raw)
        XCTAssertNotNil(entry)
        XCTAssertNil(entry?.safetensorsOrigin)
        XCTAssertNil(entry?.webPageURL)
        XCTAssertEqual(entry?.triggerWord, "tok")
    }

    func testRoundTripNewURLFields() {
        let entry = LoRAEntry(
            hostID: "flux1_t2i",
            loraID: "user_x",
            displayName: "X",
            repoID: "",
            filename: "",
            scale: 1,
            bestGuess: 1,
            localPath: "/tmp/x.safetensors",
            baseHFModelID: "black-forest-labs/FLUX.1-dev",
            minSteps: 2,
            mfluxCompatible: nil,
            triggerWord: nil,
            comment: nil,
            referencePrompt: "Ref.",
            sourcePath: "/tmp/original.safetensors",
            safetensorsOrigin: "https://civitai.com/api/download/models/1",
            webPageURL: "https://civitai.com/models/1"
        )
        let dict = entry.toDictionary()
        XCTAssertEqual(dict["safetensors_origin"] as? String, "https://civitai.com/api/download/models/1")
        XCTAssertEqual(dict["web_page_url"] as? String, "https://civitai.com/models/1")
        let loaded = LoRAEntry.fromDictionary(dict)
        XCTAssertEqual(loaded?.safetensorsOrigin, entry.safetensorsOrigin)
        XCTAssertEqual(loaded?.webPageURL, entry.webPageURL)
    }

    func testMergePreservesUnknownKeys() {
        let raw: [String: Any] = [
            "host_id": "flux1_t2i",
            "lora_id": "user_merge",
            "display_name": "Old",
            "repo_id": "",
            "filename": "",
            "scale": 1.0,
            "best_guess": 1.0,
            "local_path": "/tmp/a.safetensors",
            "base_hf_model_id": "black-forest-labs/FLUX.1-dev",
            "min_steps": 2,
            "legacy_extra": "preserve",
        ]
        guard var entry = LoRAEntry.fromDictionary(raw) else {
            XCTFail("expected entry")
            return
        }
        entry.displayName = "New"
        entry.webPageURL = "https://example.com/model"
        let merged = LoRAEntry.mergedUserEntryDictionary(entry: entry, preserving: raw)
        XCTAssertEqual(merged["legacy_extra"] as? String, "preserve")
        XCTAssertEqual(merged["display_name"] as? String, "New")
        XCTAssertEqual(merged["web_page_url"] as? String, "https://example.com/model")
    }

    func testMergeClearsOptionalURLFieldsWhenNil() {
        let raw: [String: Any] = [
            "host_id": "flux1_t2i",
            "lora_id": "user_merge",
            "display_name": "X",
            "repo_id": "",
            "filename": "",
            "scale": 1.0,
            "best_guess": 1.0,
            "local_path": "/tmp/a.safetensors",
            "base_hf_model_id": "black-forest-labs/FLUX.1-dev",
            "min_steps": 2,
            "safetensors_origin": "https://example.com/old.bin",
            "web_page_url": "https://example.com/old",
        ]
        guard var entry = LoRAEntry.fromDictionary(raw) else {
            XCTFail("expected entry")
            return
        }
        entry.safetensorsOrigin = nil
        entry.webPageURL = nil
        var merged = LoRAEntry.mergedUserEntryDictionary(entry: entry, preserving: raw)
        merged["trigger_word"] = ""
        merged["comment"] = ""
        merged["reference_prompt"] = ""
        merged["safetensors_origin"] = entry.safetensorsOrigin ?? ""
        merged["web_page_url"] = entry.webPageURL ?? ""
        XCTAssertEqual(merged["safetensors_origin"] as? String, "")
        XCTAssertEqual(merged["web_page_url"] as? String, "")
    }

    func testURLValidation() {
        XCTAssertEqual(
            LoRAURLValidation.normalizedHTTPURL(" https://civitai.com/models/1 "),
            "https://civitai.com/models/1"
        )
        XCTAssertNil(LoRAURLValidation.normalizedHTTPURL("not-a-url"))
        XCTAssertTrue(LoRAURLValidation.isValidOrEmpty(""))
        XCTAssertFalse(LoRAURLValidation.isValidOrEmpty("ftp://x.com"))
    }

    func testSafetensorsTriggerMetadata() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("meta.safetensors")
        let header: [String: Any] = [
            "__metadata__": ["trigger_word": "my_style"],
            "weight": ["dtype": "F16", "shape": [1], "data_offsets": [0, 2]],
        ]
        let headerData = try JSONSerialization.data(withJSONObject: header)
        var length = UInt64(headerData.count).littleEndian
        let lengthData = Data(bytes: &length, count: 8)
        var payload = Data()
        payload.append(lengthData)
        payload.append(headerData)
        payload.append(Data([0, 0]))
        try payload.write(to: file)
        XCTAssertEqual(LoRASafetensorsMetadata.triggerWord(fromFile: file.path), "my_style")
    }

    func testUserEntryWithoutLocalPathWhenRecoverable() {
        let raw: [String: Any] = [
            "host_id": "flux1_t2i",
            "lora_id": "user_hf_only",
            "display_name": "HF Only",
            "repo_id": "mnml-ai/flux-arch-realism-lora",
            "filename": "flux-arch-realism-lora_v1.safetensors",
            "scale": 1.0,
            "best_guess": 1.0,
            "base_hf_model_id": "black-forest-labs/FLUX.1-dev",
            "min_steps": 2,
        ]
        XCTAssertNotNil(LoRAEntry.fromDictionary(raw))
        XCTAssertTrue(
            LoRAEntry.hasRecoverySource(
                repoID: "mnml-ai/flux-arch-realism-lora",
                filename: "flux-arch-realism-lora_v1.safetensors",
                sourcePath: nil,
                safetensorsOrigin: nil,
                webPageURL: nil,
                localPath: nil
            )
        )
    }

    func testLegacySourcePathPrefill() {
        let download = LoRALegacyURLPrefill.suggestions(
            fromLegacySourcePath: "https://civitai.com/api/download/models/99"
        )
        XCTAssertEqual(download.safetensorsOrigin, "https://civitai.com/api/download/models/99")
        let page = LoRALegacyURLPrefill.suggestions(
            fromLegacySourcePath: "https://civitai.com/models/12"
        )
        XCTAssertEqual(page.webPageURL, "https://civitai.com/models/12")
    }

    @MainActor
    func testInstallDirectDownloadVsWebPageOnly() {
        let api = "https://civitai.com/api/download/models/99"
        XCTAssertNotNil(
            LoRAInstallService.directHTTPDownloadURL(sourcePath: nil, safetensorsOrigin: api)
        )
        XCTAssertTrue(
            LoRAInstallService.canDownloadWeights(
                repoID: "",
                filename: "",
                sourcePath: nil,
                safetensorsOrigin: api,
                localPath: nil
            )
        )
        let modelPage = "https://civitai.com/models/12"
        XCTAssertNil(
            LoRAInstallService.directHTTPDownloadURL(sourcePath: nil, safetensorsOrigin: modelPage)
        )
        XCTAssertFalse(
            LoRAInstallService.canDownloadWeights(
                repoID: "",
                filename: "",
                sourcePath: nil,
                safetensorsOrigin: modelPage,
                localPath: nil
            )
        )
        XCTAssertTrue(
            LoRAEntry.hasRecoverySource(
                repoID: "",
                filename: "",
                sourcePath: nil,
                safetensorsOrigin: modelPage,
                webPageURL: modelPage,
                localPath: nil
            )
        )
    }

    @MainActor
    func testInstallOpensWebPageWhenFileURLNotSafetensors() {
        let api = "https://civitai.com/api/download/models/99"
        let page = "https://civitai.com/models/12"
        let openURL = LoRAInstallService.webPageToOpenInsteadOfInstall(
            repoID: "",
            filename: "",
            sourcePath: nil,
            safetensorsOrigin: api,
            webPageURL: page,
            canDownload: true
        )
        XCTAssertEqual(openURL?.absoluteString, page)
        let direct = "https://example.com/weights/lora.safetensors"
        XCTAssertNil(
            LoRAInstallService.webPageToOpenInsteadOfInstall(
                repoID: "",
                filename: "",
                sourcePath: nil,
                safetensorsOrigin: direct,
                webPageURL: page,
                canDownload: true
            )
        )
    }
}
