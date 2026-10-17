import Foundation

/// Bash scripts for Manage models download UI (port of ``debug_download_scripts.py``).
enum ImageGenModelDownloadScriptBuilder {
    private static let sdxlBase = LoRAHFModelIDs.sdxlBase10
    private static let sdxlIncludePatterns = [
        "model_index.json",
        "scheduler/*",
        "tokenizer/*",
        "tokenizer_2/*",
        "unet/config.json",
        "unet/diffusion_pytorch_model.safetensors",
        "text_encoder/config.json",
        "text_encoder/model.safetensors",
        "text_encoder_2/config.json",
        "text_encoder_2/model.safetensors",
        "vae/config.json",
        "vae/diffusion_pytorch_model.safetensors",
    ]

    static func buildSingleModelDownloadScript(
        repoID: String,
        imagegenPythonPath: String,
        hfToken: String?,
        forceDownload: Bool
    ) -> String {
        let binDir = (imagegenPythonPath as NSString).deletingLastPathComponent as NSString
        let venvDir = binDir.deletingLastPathComponent
        let pythonSnippet = """
        PYTHON="\(shellQuote(venvDir + "/bin/python"))"
        [ -x "$PYTHON" ] || PYTHON="\(shellQuote(imagegenPythonPath))"
        """
        var lines: [String] = [
            "#!/usr/bin/env bash",
            "set -e",
            "",
            pythonSnippet,
            "",
            "# EXPORT HF_TOKEN=<your_huggingface_token>",
            "",
            "\"$PYTHON\" -m pip install -U huggingface_hub",
            "",
            hfDownloadBashHelper(venvPython: imagegenPythonPath).trimmingCharacters(in: .newlines),
            "",
            "REPO_ID=\(shellQuote(repoID))",
            "",
        ]
        let token = (hfToken ?? ProcessInfo.processInfo.environment["HF_TOKEN"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            lines.append("export HF_TOKEN=\(shellQuote(token))")
            lines.append(hfAuthBashHelper(venvPython: imagegenPythonPath))
            lines.append("")
        } else {
            lines.append("# export HF_TOKEN=<your_huggingface_token>")
            lines.append("# run_hf_download requires HF auth for gated models")
            lines.append("")
        }

        if ImageGenSceneWorksKlein.isSceneWorksRepo(repoID) {
            let tier = "q4"
            let include = shellQuote("\(tier)/**")
            lines.append("# SceneWorks MLX tier \"\(tier)\" only (not the full multi-tier repo).")
            lines.append("run_hf_download \"$REPO_ID\" --include \(include)")
            if forceDownload {
                lines[lines.count - 1] += " --force-download"
            }
        } else {
            var downloadCmd = "run_hf_download \"$REPO_ID\""
            if repoID == sdxlBase {
                let patterns = sdxlIncludePatterns.map { shellQuote($0) }.joined(separator: " ")
                downloadCmd += " --include \(patterns)"
            }
            if forceDownload {
                downloadCmd += " --force-download"
            }
            lines.append(downloadCmd)
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func hfDownloadBashHelper(venvPython: String) -> String {
        let venvHF = (venvPython as NSString).deletingLastPathComponent + "/hf"
        if FileManager.default.isExecutableFile(atPath: venvHF) {
            return """
            run_hf_download() {
              "\(shellQuote(venvHF))" download "$@"
            }
            """
        }
        let py = shellQuote(venvPython)
        return """
        run_hf_download() {
          if [ -x "./venv_image_browser/bin/hf" ]; then
            ./venv_image_browser/bin/hf download "$@"
          elif command -v hf >/dev/null 2>&1; then
            hf download "$@"
          elif [ -x \(py) ] && \(py) -c "import huggingface_hub" 2>/dev/null; then
            \(py) -m huggingface_hub.cli.hf download "$@"
          elif python3 -c "import huggingface_hub" 2>/dev/null; then
            python3 -m huggingface_hub.cli.hf download "$@"
          else
            echo "hf CLI not found. Install huggingface_hub (pip install -U huggingface_hub)." >&2
            return 1
          fi
        }
        """
    }

    private static func hfAuthBashHelper(venvPython: String) -> String {
        let venvHF = (venvPython as NSString).deletingLastPathComponent + "/hf"
        let py = shellQuote(venvPython)
        if FileManager.default.isExecutableFile(atPath: venvHF) {
            return "\"\(shellQuote(venvHF))\" auth login --token \"$HF_TOKEN\""
        }
        return """
        if [ -x "./venv_image_browser/bin/hf" ]; then
          ./venv_image_browser/bin/hf auth login --token "$HF_TOKEN"
        elif command -v hf >/dev/null 2>&1; then
          hf auth login --token "$HF_TOKEN"
        elif [ -x \(py) ] && \(py) -c "import huggingface_hub" 2>/dev/null; then
          \(py) -m huggingface_hub.cli.hf auth login --token "$HF_TOKEN"
        else
          python3 -m huggingface_hub.cli.hf auth login --token "$HF_TOKEN"
        fi
        """
    }

    private static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
