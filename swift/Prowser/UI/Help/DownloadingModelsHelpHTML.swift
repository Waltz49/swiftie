import AppKit
import SwiftUI

/// Builds themed HTML for Help → Downloading AI Models (``help_downloading_models.build_downloading_models_html``).
enum DownloadingModelsHelpHTML {
    private static let collapsedArrow = "▶"
    private static let expandedArrow = "▼"
    private static let bodyPt = "10pt"
    private static let h2Pt = "12pt"
    private static let sectionPt = "11pt"
    private static let codePt = "10pt"
    private static let lineHeight = "1.4"
    private static let copyIconPx = "12px"
    private static let gatedNoteHex = "#c9a227"
    /// macOS UI sans (SF Pro via `-apple-system` in WebKit).
    private static let sansFontFamily =
        "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Helvetica Neue\", Helvetica, Arial, sans-serif"

    struct ScriptContext {
        var scriptsByID: [String: String] = [:]
        var catalog: [ImageGenModelDownloadCatalogEntry] = []
        var imagegenPythonPath: String = ""
    }

    @MainActor
    static func makeScriptContext(imagegenPythonPath: String) -> ScriptContext {
        let catalog = ImageGenModelDownloadCatalog.buildCatalog()
        var scripts: [String: String] = [:]

        for entry in catalog {
            let sid = DownloadingModelsHelpContent.modelSectionID(repoID: entry.repoID)
            scripts[sid] = ImageGenModelDownloadScriptBuilder.buildSingleModelDownloadScript(
                repoID: entry.repoID,
                imagegenPythonPath: imagegenPythonPath,
                hfToken: nil,
                forceDownload: false
            )
        }

        for lora in DownloadingModelsHelpContent.loraEntries {
            scripts[lora.sectionID] = DownloadingModelsHelpContent.downloadScriptForLoRA(
                repoID: lora.repoID,
                filename: lora.filename,
                imagegenPythonPath: imagegenPythonPath
            )
        }

        scripts["hf_cli_install"] = DownloadingModelsHelpContent.hfCLIInstallScript(imagegenPythonPath: imagegenPythonPath)
        scripts["hf_login"] = DownloadingModelsHelpContent.hfLoginScript(imagegenPythonPath: imagegenPythonPath)

        let repoIDs = catalog.map(\.repoID).sorted()
        scripts[DownloadingModelsHelpContent.bulkDownloadAllSectionID] =
            DownloadingModelsHelpContent.downloadAllModelsScript(
                repoIDs: repoIDs,
                imagegenPythonPath: imagegenPythonPath
            )

        return ScriptContext(scriptsByID: scripts, catalog: catalog, imagegenPythonPath: imagegenPythonPath)
    }

    static func build(expanded: Set<String>, colors: ThemeColors, context: ScriptContext) -> String {
        let textHex = NSColor(colors.dialogText).hexString
        let bgHex = NSColor(colors.dialogBackground).hexString
        let headingHex = NSColor(colors.sidebarEmphasizedText).hexString
        let borderHex = NSColor(colors.defaultBorder).hexString
        let codeBgHex = NSColor(colors.buttonBgDefault).hexString
        let mutedHex = NSColor(colors.dialogMutedText).hexString
        func paragraph(_ body: String) -> String {
            """
            <p style="margin: 0 0 10px 0; color: \(textHex); font-size: \(bodyPt); line-height: \(lineHeight);">\(body)</p>
            """
        }

        var parts: [String] = [
            """
            <div style="color: \(textHex); font-family: \(sansFontFamily); font-size: \(bodyPt); line-height: \(lineHeight);">
            """,
        ]

        parts.append(
            paragraph(
                "AI IS COMPLETELY OPTIONAL. Prowser is an image browser, but some AI features "
                    + "are available if you want to use them."
            )
        )
        parts.append(
            paragraph(
                "If <a href=\"https://lmstudio.ai/\">LM Studio</a> is installed and the server "
                    + "is running, you can use it to generate EXIF captions."
            )
        )
        parts.append(
            paragraph(
                "For the Create menu features, Prowser will attempt to download model "
                    + "weights automatically the first time you use Create, Edit, Expand, or "
                    + "Infill. Nothing will be downloaded without your permission. "
                    + "Downloads are large (often several gigabytes) and are stored under your "
                    + "Hugging Face cache, typically "
                    + "<code>~/.cache/huggingface</code>. "
                    + "You can also use <b>Image → Manage models…</b> to download or reinstall from inside the app."
            )
        )
        parts.append(
            paragraph(
                "<b>MLX on Apple Silicon:</b> Create and Edit can use "
                    + "<code>\(escapeHTML(ImageGenSceneWorksKlein.repoID))</code> "
                    + "(FLUX.2 Klein 9B KV MLX). That Hugging Face repo contains several quantization tiers "
                    + "(for example <code>q4</code>, <code>q8</code>, <code>bf16</code>). Manual and bulk download "
                    + "scripts below fetch the <code>\(DownloadingModelsHelpContent.defaultMLXTier)</code> tier only "
                    + "(via <code>hf download --include '\(DownloadingModelsHelpContent.defaultMLXTier)/**'</code>), "
                    + "matching the default in <b>Image → Manage models…</b>. Change tier in Create settings if you "
                    + "use a different MLX quantization."
            )
        )
        parts.append(
            paragraph(
                "If a download fails or stalls, you may need to install the model manually. "
                    + "To see detailed error messages, run Prowser from a terminal, for example: "
                    + "<code>/Applications/swift-prowser.app/Contents/MacOS/Prowser</code> "
                    + "(adjust the path if you run from a build folder)."
            )
        )

        parts.append(
            """
            <h2 style="color: \(headingHex); font-size: \(h2Pt); margin: 18px 0 8px 0;">Download models</h2>
            """
        )
        parts.append(
            paragraph(
                "For gated models, set <code>HF_TOKEN</code> in your environment "
                    + "(<code>export HF_TOKEN=&lt;your-token&gt;</code>) where "
                    + "&lt;your-token&gt; is your Hugging Face token from account settings."
            )
        )
        parts.append(
            paragraph(
                "Expand a model to see its repository and download script. Save the script "
                    + "(for example as <code>download-model.sh</code>), "
                    + "run <code>chmod +x download-model.sh</code>, then "
                    + "<code>./download-model.sh</code> from Terminal — or paste the commands into "
                    + "zsh. Click <span style=\"font-family: \(sansFontFamily);\">"
                    + escapeHTML(DownloadingModelsHelpContent.copySymbol)
                    + "</span> to copy a script to the clipboard."
            )
        )

        for entry in context.catalog {
            let sid = DownloadingModelsHelpContent.modelSectionID(repoID: entry.repoID)
            let gatedNote = entry.gated
                ? " <span style=\"color: \(gatedNoteHex);\">(gated — accept license on Hugging Face first)</span>"
                : ""
            parts.append(toggleHeader(sectionID: sid, title: entry.displayName, expanded: expanded, headingHex: headingHex, suffixHTML: gatedNote))
            guard expanded.contains(sid) else { continue }
            let usedFor = usageLabel(for: entry)
            let modelURL = "https://huggingface.co/\(escapeHTML(entry.repoID, attribute: true))"
            parts.append(
                paragraph(
                    "<b>Used for:</b> \(escapeHTML(usedFor))<br>"
                        + "<b>Repository:</b> <a href=\"\(modelURL)\">\(escapeHTML(entry.repoID))</a>"
                )
            )
            if let script = context.scriptsByID[sid] {
                parts.append(scriptBlock(blockID: sid, script: script, codeBg: codeBgHex, borderHex: borderHex, mutedHex: mutedHex, textHex: textHex))
            }
        }

        parts.append(
            """
            <h2 style="color: \(headingHex); font-size: \(h2Pt); margin: 22px 0 8px 0;">Download LoRAs</h2>
            """
        )
        parts.append(
            paragraph(
                "LoRA weights are small adapter files (typically tens to hundreds of MB). "
                    + "Prowser downloads them on first use when you pick a LoRA in Create, or you "
                    + "can install them manually with the scripts below. SD 1.5 LoRAs are stored under "
                    + "<code>~/.cache/image_browser/mflux_loras/</code>."
            )
        )

        for lora in DownloadingModelsHelpContent.loraEntries {
            parts.append(toggleHeader(sectionID: lora.sectionID, title: lora.title, expanded: expanded, headingHex: headingHex))
            guard expanded.contains(lora.sectionID) else { continue }
            let modelURL = "https://huggingface.co/\(escapeHTML(lora.repoID, attribute: true))"
            parts.append(
                paragraph(
                    "<b>Used for:</b> \(escapeHTML(lora.usage))<br>"
                        + "<b>File:</b> <code>\(escapeHTML(lora.filename))</code><br>"
                        + "<b>Repository:</b> <a href=\"\(modelURL)\">\(escapeHTML(lora.repoID))</a>"
                )
            )
            if let script = context.scriptsByID[lora.sectionID] {
                parts.append(scriptBlock(blockID: lora.sectionID, script: script, codeBg: codeBgHex, borderHex: borderHex, mutedHex: mutedHex, textHex: textHex))
            }
        }

        parts.append(
            """
            <h2 style="color: \(headingHex); font-size: \(h2Pt); margin: 22px 0 8px 0;">Hugging Face</h2>
            """
        )
        parts.append(
            paragraph(
                "Manual downloads use the <code>hf</code> command-line tool. Install it once in the "
                    + "imagegen Python environment, then log in if you use gated FLUX models."
            )
        )
        parts.append(toggleHeader(sectionID: "hf_cli_install", title: "Install hf CLI", expanded: expanded, headingHex: headingHex))
        if expanded.contains("hf_cli_install") {
            parts.append(
                paragraph(
                    "Install into the imagegen virtual environment Prowser uses for generation "
                        + "(Settings → Image Generation, or your profile <code>imagegen</code> venv):"
                )
            )
            if let script = context.scriptsByID["hf_cli_install"] {
                parts.append(scriptBlock(blockID: "hf_cli_install", script: script, codeBg: codeBgHex, borderHex: borderHex, mutedHex: mutedHex, textHex: textHex))
            }
            let hfPath = (context.imagegenPythonPath as NSString).deletingLastPathComponent + "/hf"
            parts.append(paragraph("Verify: <code>\(escapeHTML(hfPath)) --help</code>"))
        }

        parts.append(toggleHeader(sectionID: "hf_account", title: "Account and gated models", expanded: expanded, headingHex: headingHex))
        if expanded.contains("hf_account") {
            parts.append(
                paragraph(
                    "Several FLUX models require a free Hugging Face account and accepting the "
                        + "model license on the model page before download will succeed:"
                )
            )
            parts.append(
                """
                <ol style="margin: 0 0 12px 22px; padding: 0; color: \(textHex); font-size: \(bodyPt); line-height: \(lineHeight);">
                <li>Create an account at <a href="https://huggingface.co/join">huggingface.co</a> (if you do not have one).</li>
                <li>Open the model page for the repo you need (links are under each model above).</li>
                <li>Sign in, read the license, and click <b>Agree and access repository</b> when prompted.</li>
                <li>Log in from the CLI using the bash script below.</li>
                </ol>
                """
            )
            if let script = context.scriptsByID["hf_login"] {
                parts.append(scriptBlock(blockID: "hf_login", script: script, codeBg: codeBgHex, borderHex: borderHex, mutedHex: mutedHex, textHex: textHex))
            }
            parts.append(paragraph("After login, re-run the download script or try generation again in Prowser."))
        }

        parts.append(
            """
            <h2 style="color: \(headingHex); font-size: \(h2Pt); margin: 22px 0 8px 0;">Download all models at once</h2>
            """
        )
        parts.append(
            paragraph(
                "Use one bash script to download every model repository listed under "
                    + "<b>Download models</b> above. This can take a long time and use many gigabytes of disk. "
                    + "It does <b>not</b> download LoRAs. Gated repos still require licenses and "
                    + "<code>HF_TOKEN</code> or <code>hf auth login</code>. "
                    + "The SceneWorks MLX repo is downloaded with <code>--include '\(DownloadingModelsHelpContent.defaultMLXTier)/**'</code> "
                    + "only (not every tier in the repository)."
            )
        )
        parts.append(
            toggleHeader(
                sectionID: DownloadingModelsHelpContent.bulkDownloadAllSectionID,
                title: "Show script for all models",
                expanded: expanded,
                headingHex: headingHex
            )
        )
        if expanded.contains(DownloadingModelsHelpContent.bulkDownloadAllSectionID),
           let script = context.scriptsByID[DownloadingModelsHelpContent.bulkDownloadAllSectionID] {
            parts.append(
                scriptBlock(
                    blockID: DownloadingModelsHelpContent.bulkDownloadAllSectionID,
                    script: script,
                    codeBg: codeBgHex,
                    borderHex: borderHex,
                    mutedHex: mutedHex,
                    textHex: textHex
                )
            )
        }

        parts.append("</div>")

        return wrapPage(body: parts.joined(), bgHex: bgHex, textHex: textHex, borderHex: borderHex)
    }

    private static func usageLabel(for entry: ImageGenModelDownloadCatalogEntry) -> String {
        let labels = entry.functionLabels
        if !labels.isEmpty {
            return labels.joined(separator: ", ")
        }
        let comment = entry.modelComment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty { return comment }
        return entry.displayName
    }

    private static func wrapPage(body: String, bgHex: String, textHex: String, borderHex: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8"/>
        <style>
        body { margin: 0; padding: 12px; background: \(bgHex); color: \(textHex); font-family: \(sansFontFamily); font-size: \(bodyPt); line-height: \(lineHeight); }
        p, h2, ol, li, a, div { font-family: inherit; }
        a { color: \(textHex); }
        code { font-family: Menlo, Monaco, \"SF Mono\", monospace; font-size: \(codePt); }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func toggleHeader(
        sectionID: String,
        title: String,
        expanded: Set<String>,
        headingHex: String,
        suffixHTML: String = ""
    ) -> String {
        let isOpen = expanded.contains(sectionID)
        let arrow = isOpen ? expandedArrow : collapsedArrow
        let sid = escapeHTML(sectionID, attribute: true)
        return """
        <div style="margin: 10px 0 4px 0;">
        <a href="toggle://\(sid)" style="color: \(headingHex); text-decoration: none; font-size: \(sectionPt); font-weight: bold;">\(escapeHTML(arrow)) \(escapeHTML(title))</a>\(suffixHTML)
        </div>
        """
    }

    private static func scriptBlock(
        blockID: String,
        script: String,
        codeBg: String,
        borderHex: String,
        mutedHex: String,
        textHex: String
    ) -> String {
        let escapedScript = escapeHTML(script)
        let bid = escapeHTML(blockID, attribute: true)
        let copyCell = """
        <td style="border: none; vertical-align: top; padding: 4px 0 0 6px;">
        <a href="copy://\(bid)" style="display: block; color: \(mutedHex); text-decoration: none; font-size: \(copyIconPx); line-height: 24px; border: 1px solid \(borderHex); border-radius: 6px; padding: 0 6px; text-align: center;" title="Copy to clipboard">\(escapeHTML(DownloadingModelsHelpContent.copySymbol))</a>
        </td>
        """
        return """
        <table cellpadding="0" cellspacing="0" style="width: 100%; margin: 0 0 12px 0;">
        <tr>
        <td style="border: 1px solid \(borderHex); border-radius: 6px; background: \(codeBg); padding: 8px 10px; width: 100%;">
        <pre style="margin: 0; white-space: pre-wrap; word-break: break-word; font-family: Menlo, Monaco, \"Courier New\", monospace; font-size: \(codePt); color: \(textHex);">\(escapedScript)</pre>
        </td>
        \(copyCell)
        </tr>
        </table>
        """
    }

    private static func escapeHTML(_ value: String, attribute: Bool = false) -> String {
        var s = value
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        if attribute {
            s = s.replacingOccurrences(of: "\"", with: "&quot;")
        }
        return s
    }
}