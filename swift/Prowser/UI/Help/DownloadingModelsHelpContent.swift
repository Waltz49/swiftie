import Foundation

/// Static LoRA help rows (reference ``LORA_DOWNLOAD_ENTRIES``).
enum DownloadingModelsHelpContent {
    static let copySymbol = "⧉"

    struct LoRAEntry: Sendable {
        let sectionID: String
        let title: String
        let repoID: String
        let filename: String
        let usage: String
    }

    static let loraEntries: [LoRAEntry] = [
        LoRAEntry(
            sectionID: "sd15_lora_anime",
            title: "Anime character LoRA (SD 1.5)",
            repoID: "Shion1124/anime-character-lora_v1.5",
            filename: "adapter_model.safetensors",
            usage: "Create — Anything Furry — anime style LoRA"
        ),
        LoRAEntry(
            sectionID: "sd15_lora_furry",
            title: "Furry LoRA (SD 1.5)",
            repoID: "hank87/furrylora",
            filename: "furry_lora.safetensors",
            usage: "Create — Anything Furry — furry / anthro LoRA"
        ),
    ]

    static let bulkDownloadAllSectionID = "download_all_models"

    /// Default quantization tier for ``ImageGenSceneWorksKlein`` manual / bulk `hf download`.
    static let defaultMLXTier = "q4"

    static func modelSectionID(repoID: String) -> String {
        repoID.replacingOccurrences(of: "/", with: "__")
    }

    static func loraCacheDirBash(repoID: String) -> String {
        let escaped = repoID.replacingOccurrences(of: "/", with: "__")
        return "$HOME/.cache/image_browser/mflux_loras/\(escaped)"
    }

    /// Resolve `hf` for help bash snippets (imagegen venv first, then PATH).
    static func hfCLIPreamble(imagegenPythonPath: String) -> String {
        let binDir = (imagegenPythonPath as NSString).deletingLastPathComponent
        let hfPath = (binDir as NSString).appendingPathComponent("hf")
        return """
        HF="\(shellQuote(hfPath))"
        if [ ! -x "$HF" ]; then
          HF="$(command -v hf 2>/dev/null || true)"
        fi
        if [ -z "$HF" ] || [ ! -x "$HF" ]; then
          echo "hf not found. Install huggingface_hub in the imagegen venv (see Install hf CLI below)." >&2
          exit 1
        fi
        """
    }

    static func pipPythonSnippet(imagegenPythonPath: String) -> String {
        let venvDir = ((imagegenPythonPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return """
        PYTHON="\(shellQuote(venvDir + "/bin/python"))"
        [ -x "$PYTHON" ] || PYTHON="\(shellQuote(imagegenPythonPath))"
        """
    }

    /// Bash `hf download` line for one model repo (MLX repos download one tier only).
    static func hfDownloadCommandBash(repoID: String) -> String {
        if ImageGenSceneWorksKlein.isSceneWorksRepo(repoID) {
            return """
            # SceneWorks MLX tier "\(defaultMLXTier)" only (not the full multi-tier repo).
            "$HF" download "$REPO_ID" --include '\(defaultMLXTier)/**'
            """
        }
        return "\"$HF\" download \"$REPO_ID\""
    }

    static func downloadScriptForRepo(repoID: String, imagegenPythonPath: String) -> String {
        """
        #!/usr/bin/env bash
        set -e

        REPO_ID="\(repoID)"

        \(hfCLIPreamble(imagegenPythonPath: imagegenPythonPath))

        \(hfDownloadCommandBash(repoID: repoID))
        """
    }

    static func downloadScriptForLoRA(
        repoID: String,
        filename: String,
        imagegenPythonPath: String
    ) -> String {
        let localDir = loraCacheDirBash(repoID: repoID)
        return """
        #!/usr/bin/env bash
        set -e

        REPO_ID="\(repoID)"
        FILENAME="\(filename)"
        LOCAL_DIR="\(localDir)"

        \(hfCLIPreamble(imagegenPythonPath: imagegenPythonPath))

        mkdir -p "$LOCAL_DIR"
        "$HF" download "$REPO_ID" "$FILENAME" --local-dir "$LOCAL_DIR"
        """
    }

    static func hfCLIInstallScript(imagegenPythonPath: String) -> String {
        """
        #!/usr/bin/env bash
        set -e

        \(pipPythonSnippet(imagegenPythonPath: imagegenPythonPath))

        "$PYTHON" -m pip install -U huggingface_hub
        """
    }

    static func hfLoginScript(imagegenPythonPath: String) -> String {
        """
        #!/usr/bin/env bash
        set -e

        \(hfCLIPreamble(imagegenPythonPath: imagegenPythonPath))

        "$HF" auth login
        """
    }

    static func downloadAllModelsScript(
        repoIDs: [String],
        imagegenPythonPath: String
    ) -> String {
        let repoLines = repoIDs.map { "  \"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: "\n")
        let mlxRepo = ImageGenSceneWorksKlein.repoID
        return """
        #!/usr/bin/env bash
        # Download all image-generation model repos listed in Help → Downloading AI Models (models only; no LoRAs).
        # Gated FLUX repos: accept each license on huggingface.co, then export HF_TOKEN or run hf auth login.
        set -e

        # export HF_TOKEN=<your-token>

        \(hfCLIPreamble(imagegenPythonPath: imagegenPythonPath))

        MODEL_REPOS=(
        \(repoLines)
        )

        SCENEWORKS_MLX_REPO="\(mlxRepo)"
        MLX_DEFAULT_TIER="\(defaultMLXTier)"

        download_one_model() {
          local rid="$1"
          if [ "$rid" = "$SCENEWORKS_MLX_REPO" ]; then
            echo "(SceneWorks MLX: ${MLX_DEFAULT_TIER} tier only)"
            "$HF" download "$rid" --include "${MLX_DEFAULT_TIER}/**"
          else
            "$HF" download "$rid"
          fi
        }

        echo "=== Downloading model repositories (${#MODEL_REPOS[@]}) ==="
        for REPO_ID in "${MODEL_REPOS[@]}"; do
          echo ""
          echo ">>> $REPO_ID"
          download_one_model "$REPO_ID"
        done

        echo ""
        echo "All model downloads finished."
        """
    }

    private static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}