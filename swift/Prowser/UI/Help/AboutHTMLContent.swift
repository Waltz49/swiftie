import Foundation

/// HTML bodies ported from `browser_window/dialogs/about_dialog.py`.
@MainActor
enum AboutHTMLContent {
    private static let creditsTemplate = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8"/>
    <style>
    body { font-family: "Helvetica Neue", "Helvetica", "Arial", sans-serif; font-size: 13px; line-height: 1.45; color: __TEXT_COLOR__; background: __BG_COLOR__; }
    h2 { font-size: 15px; margin: 1em 0 0.4em 0; }
    h3 { font-size: 13px; margin: 1em 0 0.35em 0; }
    ul { margin: 0.2em 0 0.6em 1.2em; padding: 0; }
    li { margin: 0.2em 0; }
    p { margin: 0.4em 0; }
    a { color: __LINK_COLOR__; text-decoration: none; }
    .note { color: __NOTE_COLOR__; font-size: 12px; font-style: italic; white-space: nowrap; margin-left: 4em; }
    </style>
    </head>
    <body>
    <h2>Author</h2>
    <p>Doug Nadel, and a myriad of AI zombies who wrote some code in exchange for brains.<br>
    <span style="font-size: 10px; color: __SUBNOTE_COLOR__;">I've said too much.</span><br>
    Contact: <a href="mailto:sillysotsoftware@yahoo.com">sillysotsoftware@yahoo.com</a>
    <br>GitHub: <a href="https://github.com/waltz49/Prowser">waltz49/Prowser</a>
    <br>Website: <a href="https://waltzremote.com">waltzremote.com</a>
    </p>
    <h3>License</h3>
    <p>Business Source License 1.1 (BSL 1.1)</p>
    <h3>Credits</h3>
    <p>Prowser is distributed under the Business Source License 1.1 (source-available; converts to MIT on the Change Date). See the License section for details.</p>
    <p>All intellectual property included in this work is owned by the original authors and contributors. If any work remains uncredited, it is an omission due to error.</p>
    <h2>Libraries &amp; frameworks</h2>
    <ul>
    <li><b>PySide6</b> (Qt for Python) — <a href="https://www.qt.io/qt-for-python">qt.io/qt-for-python</a></li>
    <li><b>Pillow</b> (PIL) — <a href="https://python-pillow.org/">python-pillow.org</a></li>
    <li><b>pillow-heif</b> (HEIF/HEIC) — <a href="https://github.com/bigcat88/pillow_heif">GitHub: bigcat88/pillow_heif</a></li>
    <li><b>NumPy</b> — <a href="https://numpy.org/">numpy.org</a></li>
    <li><b>piexif</b> — <a href="https://github.com/hMatoba/Piexif">GitHub: hMatoba/Piexif</a></li>
    <li><b>PyTorch</b> &amp; <b>torchvision</b> (CNN similarity, pretrained ResNet weights) — <a href="https://pytorch.org/">pytorch.org</a></li>
    <li><b>Hugging Face Transformers</b> (CLIP text/image models) — <a href="https://github.com/huggingface/transformers">GitHub: huggingface/transformers</a></li>
    <li><b>face_recognition</b> — <a href="https://github.com/ageitgey/face_recognition">GitHub: ageitgey/face_recognition</a>
      (uses <b>dlib</b> — <a href="http://dlib.net/">dlib.net</a>)</li>
    <li>Pretrained dlib shape predictor / face recognition models bundled via the
      <b>face_recognition_models</b> package — <a href="https://github.com/ageitgey/face_recognition_models">GitHub: ageitgey/face_recognition_models</a></li>
    </ul>
    <h2>Models (may download on first use)</h2>
    <p class="note">CLIP weights are fetched via Hugging Face Hub (cache: typically <code>~/.cache/huggingface</code>).<br>
    ResNet ImageNet checkpoints are typically cached under <code>~/.cache/torch</code>.</p>
    <h3>Hugging Face — CLIP (settings may use either)</h3>
    <ul>
    <li><a href="https://huggingface.co/openai/clip-vit-base-patch32">openai/clip-vit-base-patch32</a> (default)</li>
    <li><a href="https://huggingface.co/openai/clip-vit-large-patch14">openai/clip-vit-large-patch14</a></li>
    </ul>
    <h3>Face recognition (dlib / face_recognition)</h3>
    <p>Detector and 128-D embedding weights are provided by the
    <a href="https://github.com/ageitgey/face_recognition_models">face_recognition_models</a> distribution
    (not hosted on Hugging Face). Credit: Davis King (dlib) and Adam Geitgey (face_recognition ecosystem).</p>
    </body>
    </html>
    """

    private static let licenseTemplate = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8"/>
    <style>
    body { font-family: "Helvetica Neue", "Helvetica", "Arial", sans-serif; font-size: 13px; line-height: 1.45; color: __TEXT_COLOR__; background: __BG_COLOR__; }
    h1 { font-size: 16px; margin: 0 0 0.5em 0; }
    h2 { font-size: 14px; margin: 1em 0 0.35em 0; }
    p { margin: 0.4em 0; }
    .header { color: __NOTE_COLOR__; font-size: 12px; }
    table.params { width: 100%; border-collapse: collapse; margin: 0.4em 0 0.8em 0; }
    table.params th, table.params td { border: 1px solid __BORDER_COLOR__; padding: 6px 8px; vertical-align: top; text-align: left; }
    table.params th { background-color: __TABLE_HEADER_BG__; font-weight: bold; }
    table.params td.param { width: 28%; font-weight: bold; white-space: nowrap; }
    .terms p { margin: 0.65em 0; }
    </style>
    </head>
    <body>
    <h1>Business Source License 1.1</h1>
    <p class="header">License text copyright &copy; 2026 Doug Nadel, All Rights Reserved.<br>
    &quot;Business Source License&quot; is a trademark of MariaDB plc.</p>
    <h2>Parameters</h2>
    <table class="params">
    <thead><tr><th>Parameter</th><th>Value</th></tr></thead>
    <tbody>
    <tr><td class="param">Licensor</td><td>Doug Nadel</td></tr>
    <tr><td class="param">Licensed Work</td><td>Prowser (Image Browser)<br>© 2026 Doug Nadel</td></tr>
    <tr><td class="param">Additional Use Grant</td><td>You may make production use of the Licensed Work for personal,
    non-commercial purposes, and for use within your organization
    (including affiliates under common control).</td></tr>
    <tr><td class="param">Change Date</td><td>Four years from the first public distribution of a specific
    version of the Licensed Work under this License.</td></tr>
    <tr><td class="param">Change License</td><td>MIT</td></tr>
    </tbody>
    </table>
    <h2>Notice</h2>
    <p>Business Source License 1.1</p>
    <h2>Terms</h2>
    <div class="terms">
    <p>The Licensor hereby grants you the right to copy, modify, create derivative
    works, redistribute, and make non-production use of the Licensed Work. The
    Licensor may make an Additional Use Grant, above, permitting limited
    production use.</p>
    <p>Effective on the Change Date, or the fourth anniversary of the first publicly
    available distribution of a specific version of the Licensed Work under this
    License, whichever comes first, the Licensor hereby grants you rights under
    the terms of the Change License, and the rights granted in the paragraph
    above terminate.</p>
    <p>If your use of the Licensed Work does not comply with the requirements
    currently in effect as described in this License, you must purchase a
    commercial license from the Licensor, its affiliated entities, or authorized
    resellers, or you must refrain from using the Licensed Work.</p>
    <p>All copies of the original and modified Licensed Work, and derivative works
    of the Licensed Work, are subject to this License. This License applies
    separately for each version of the Licensed Work and the Change Date may vary
    for each version of the Licensed Work released by Licensor.</p>
    <p>You must conspicuously display this License on each original or modified copy
    of the Licensed Work. If you receive the Licensed Work in original or
    modified form from a third party, the terms and conditions set forth in this
    License apply to your use of that work.</p>
    <p>Any use of the Licensed Work in violation of this License will automatically
    terminate your rights under this License for the current and all other
    versions of the Licensed Work.</p>
    <p>This License does not grant you any right in any trademark or logo of
    Licensor or its affiliates (provided that you may use a trademark or logo of
    Licensor as expressly required by this License).</p>
    <p>TO THE EXTENT PERMITTED BY APPLICABLE LAW, THE LICENSED WORK IS PROVIDED ON
    AN &quot;AS IS&quot; BASIS. LICENSOR HEREBY DISCLAIMS ALL WARRANTIES AND CONDITIONS,
    EXPRESS OR IMPLIED, INCLUDING (WITHOUT LIMITATION) WARRANTIES OF
    MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, NON-INFRINGEMENT, AND
    TITLE.</p>
    </div>
    </body>
    </html>
    """

    static func creditsHTML(settings: [String: Any]) -> String {
        themed(creditsTemplate, settings: settings)
    }

    static func licenseHTML(settings: [String: Any]) -> String {
        themed(licenseTemplate, settings: settings)
    }

    private static func themed(_ template: String, settings: [String: Any]) -> String {
        let uiTheme = (settings["ui_theme"] as? String ?? "dark").lowercased()
        let themeID = ThemeService.resolveThemeID(uiTheme, settings: settings)
        let merged = ThemeService.mergedColors(for: themeID, settings: settings)
        func hex(_ key: String, _ fallback: String) -> String {
            if let raw = merged[key] as? String, !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                return raw.trimmingCharacters(in: .whitespaces)
            }
            return fallback
        }
        let dialogText = hex("dialog_text_color_hex", "#b6b6b6")
        let dialogBg = hex("dialog_background_hex", "#2a2a2a")
        let border = hex("default_border_color_hex", "#606060")
        let link = hex("current_image_border_color_hex", "#87ceeb")
        let note = ThemeBlendUtils.blendTextTowardBackground(
            textHex: dialogText,
            bgHex: dialogBg,
            blendPercent: 50
        )
        return template
            .replacingOccurrences(of: "__LINK_COLOR__", with: link)
            .replacingOccurrences(of: "__NOTE_COLOR__", with: note)
            .replacingOccurrences(of: "__SUBNOTE_COLOR__", with: note)
            .replacingOccurrences(of: "__BORDER_COLOR__", with: border)
            .replacingOccurrences(of: "__TABLE_HEADER_BG__", with: dialogBg)
            .replacingOccurrences(of: "__TEXT_COLOR__", with: dialogText)
            .replacingOccurrences(of: "__BG_COLOR__", with: dialogBg)
    }
}
