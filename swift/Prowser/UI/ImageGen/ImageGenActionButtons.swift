import AppKit
import SwiftUI

enum ImageGenPromptDefaults {
    static let promptResetText = ""
    static let systemPromptResetText =
        "Respond with a 90 word image prompt. No commentary, no conversation.\n" +
        "If image provided, base your response on the image. Retain all details " +
        "you receive from the user. Answer in documentary prose."
}

/// Copy / speak / favorite / mic / clear strip matching Python `append_image_gen_prompt_label_action_buttons`.
@MainActor
struct ImageGenPromptActionButtons: View {
    let text: String
    var defaultText: String = ImageGenPromptDefaults.promptResetText
    var includeFavorite: Bool = true
    var onTextChanged: ((String) -> Void)?

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 6) {
            AppAssetIconButton(
                normalName: "copy",
                hoverName: "copy_hover",
                size: ImageGenChrome.fieldButtonSize,
                tooltip: "Copy to clipboard",
                action: copyText
            )
            AppAssetIconButton(
                normalName: "bullhorn",
                hoverName: "bullhorn_hover",
                size: ImageGenChrome.fieldButtonSize,
                tooltip: "Read prompt aloud",
                action: speakText
            )
            if includeFavorite {
                AppAssetIconButton(
                    normalName: "chatfav",
                    hoverName: "chatfav_hover",
                    size: ImageGenChrome.fieldButtonSize,
                    tooltip: "Append from favorite prompts",
                    action: appendFavoritePrompt
                )
            }
            if BundleCapabilities.voiceInputUIEnabled {
                AppAssetIconButton(
                    normalName: "mic",
                    hoverName: "mic_hover",
                    size: ImageGenChrome.fieldButtonSize,
                    tooltip: "Voice input",
                    action: voiceInputStub
                )
            }
            AppAssetIconButton(
                normalName: "trash_icon",
                hoverName: "trash_icon_hover",
                size: ImageGenChrome.promptClearButtonSize,
                iconSize: ImageGenChrome.promptClearIconSize,
                tooltip: "Reset to default",
                action: resetToDefault
            )
        }
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appState.status.show("Copied to clipboard.")
    }

    private func speakText() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSSpeechSynthesizer().startSpeaking(trimmed)
    }

    private func appendFavoritePrompt() {
        appState.status.show("Favorite prompts: use chat prompt library (not yet ported).")
    }

    private func voiceInputStub() {
        appState.status.show("Voice input for prompt fields is not yet ported.")
    }

    private func resetToDefault() {
        onTextChanged?(defaultText)
    }
}

/// Trash reset shown only when the field value differs from its plugin default.
@MainActor
struct ImageGenFieldResetButton: View {
    let isActive: Bool
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Group {
            if isActive {
                AppAssetIconButton(
                    normalName: "trash_icon",
                    hoverName: "trash_icon_hover",
                    size: ImageGenChrome.fieldButtonSize,
                    iconSize: ImageGenChrome.fieldResetIconSize,
                    tooltip: tooltip,
                    action: action
                )
            } else {
                Color.clear
                    .frame(width: ImageGenChrome.fieldButtonSize, height: ImageGenChrome.fieldButtonSize)
            }
        }
    }
}

enum ImageGenChrome {
    static let fieldButtonSize: CGFloat = 26
    static let fieldResetIconSize: CGFloat = 16
    static let promptClearButtonSize: CGFloat = 21
    static let promptClearIconSize: CGFloat = 13
    static let dimHelperButtonSize: CGFloat = 22
    static let dimHelperIconSize: CGFloat = 16
    static let gearIconSize: CGFloat = 16
}

/// Gear icon opening a Settings tab (Python `create_image_gen_settings_gear_button`).
@MainActor
struct ImageGenSettingsGearButton: View {
    @Environment(AppState.self) private var appState
    let settingsTab: SettingsTab
    var tooltip: String = "Open settings"
    var loraModelKey: String?

    var body: some View {
        AppAssetIconButton(
            normalName: "gear",
            hoverName: "gear_hover",
            fileExtension: "svg",
            size: ImageGenChrome.dimHelperButtonSize,
            iconSize: ImageGenChrome.gearIconSize,
            tooltip: tooltip,
            action: {
                var userInfo: [String: Any] = [:]
                if let loraModelKey, !loraModelKey.isEmpty {
                    userInfo["lora_model_key"] = loraModelKey
                }
                appState.openSettingsWindow(tab: settingsTab, userInfo: userInfo)
            }
        )
    }
}

/// Custom-size dimension helper (screen / square / reverse / import).
@MainActor
struct ImageGenDimHelperIconButton: View {
    let normalName: String
    let hoverName: String
    var tooltip: String = ""
    let action: () -> Void

    var body: some View {
        AppAssetIconButton(
            normalName: normalName,
            hoverName: hoverName,
            size: ImageGenChrome.dimHelperButtonSize,
            iconSize: ImageGenChrome.dimHelperIconSize,
            tooltip: tooltip,
            action: action
        )
    }
}

/// LoRA heading trash — clears all selected LoRAs (Python `create_image_gen_lora_clear_button`).
@MainActor
struct ImageGenLoraClearButton: View {
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isVisible {
                AppAssetIconButton(
                    normalName: "trash_icon",
                    hoverName: "trash_icon_hover",
                    size: ImageGenChrome.dimHelperButtonSize,
                    iconSize: ImageGenChrome.gearIconSize,
                    tooltip: "Clear all LoRAs",
                    action: action
                )
            } else {
                Color.clear
                    .frame(width: ImageGenChrome.dimHelperButtonSize, height: ImageGenChrome.dimHelperButtonSize)
            }
        }
    }
}

/// Grammar / spelling correction via LM Studio (Python `prompt_grammar_button`).
@MainActor
struct ImageGenGrammarButton: View {
    @Environment(AppState.self) private var appState
    @Binding var text: String
    var onTextChanged: (() -> Void)?

    @State private var isRunning = false
    @State private var promptBefore = ""
    @State private var streamingStarted = false
    @State private var dotPhase = 0
    @State private var dotTimer: Timer?

    private var isAvailable: Bool {
        BundleCapabilities.lmStudioUIEnabled && appState.workers.foregroundModelTasks.isAvailable
    }

    var body: some View {
        Group {
            if isAvailable {
                Button(isRunning ? "Cancel" : "Grammar") {
                    if isRunning {
                        cancelGrammar()
                    } else {
                        startGrammar()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(isRunning
                    ? "Stop the in-progress grammar correction"
                    : "Correct grammar and spelling using LM Studio")
            }
        }
    }

    private func startGrammar() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            appState.status.show("Enter a prompt before running grammar correction.")
            return
        }
        let bridge = appState.workers.foregroundModelTasks
        guard !bridge.isBusy else {
            appState.status.show("Wait for the current LM Studio task to finish.")
            return
        }

        let prompts = ImageGenGrammarLogic.systemAndUserPrompts(for: prompt)
        promptBefore = text
        isRunning = true
        streamingStarted = false
        startDotAnimation()

        bridge.onFluxPromptChunk = { chunk in
            Task { @MainActor in
                guard !chunk.isEmpty else { return }
                if !streamingStarted {
                    streamingStarted = true
                    stopDotAnimation()
                    text = chunk
                } else {
                    text += chunk
                }
                onTextChanged?()
            }
        }
        bridge.onFluxPromptReady = { corrected in
            Task { @MainActor in
                stopDotAnimation()
                text = corrected
                finishGrammar(success: true)
                onTextChanged?()
            }
        }
        bridge.onJobFinished = { kind, success, error in
            guard kind == "flux_prompt" else { return }
            Task { @MainActor in
                if !success {
                    if !streamingStarted {
                        text = promptBefore
                    }
                    if !error.isEmpty, error != "Cancelled" {
                        appState.status.show(error)
                    }
                }
                finishGrammar(success: success)
                onTextChanged?()
            }
        }

        do {
            _ = try bridge.startFluxPrompt(
                prompt: prompts.user,
                systemPrompt: prompts.system,
                imagePaths: []
            )
        } catch {
            stopDotAnimation()
            text = promptBefore
            appState.status.show(error.localizedDescription)
            finishGrammar(success: false)
        }
    }

    private func cancelGrammar() {
        stopDotAnimation()
        appState.workers.foregroundModelTasks.cancel()
        if !streamingStarted {
            text = promptBefore
        }
        finishGrammar(success: false)
        onTextChanged?()
    }

    private func finishGrammar(success: Bool) {
        _ = success
        isRunning = false
        streamingStarted = false
        let bridge = appState.workers.foregroundModelTasks
        bridge.onFluxPromptChunk = nil
        bridge.onFluxPromptReady = nil
        bridge.onJobFinished = nil
    }

    private func startDotAnimation() {
        stopDotAnimation()
        dotPhase = 0
        dotTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            Task { @MainActor in
                dotPhase = (dotPhase + 1) % 4
                text = String(repeating: ".", count: dotPhase + 1)
                onTextChanged?()
            }
        }
    }

    private func stopDotAnimation() {
        dotTimer?.invalidate()
        dotTimer = nil
    }
}

enum ImageGenGrammarLogic {
    private static let systemPrompt =
        "You are a grammarian."
        + "Correct the grammer, English sentence structure, "
        + "spelling and capitalization for the user supplied input. "
        + "Make no commentary or analysis. "
        + "Correct the grammar, punctuation, spelling and capitalization only. "
        + "Do not reword the input for any purposes other than to correct the grammar, punctuation, spelling and capitalization."

    static func systemAndUserPrompts(for prompt: String) -> (system: String, user: String) {
        guard let idx = prompt.firstIndex(of: ":") else {
            return (systemPrompt, prompt)
        }
        let leading = String(prompt[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = String(prompt[prompt.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if leading.isEmpty || remainder.isEmpty {
            return (systemPrompt, prompt)
        }
        var phrase = leading
        if !phrase.hasSuffix(".") && !phrase.hasSuffix("!") && !phrase.hasSuffix("?") {
            phrase += "."
        }
        return ("\(systemPrompt) \(phrase)", remainder)
    }
}

enum ImageGenFieldResetLogic {
    static func matchesDefault(current: Any?, resetDefault: Any?, kind: String, step: Double = 0.1) -> Bool {
        guard let resetDefault else { return true }
        switch kind {
        case "int_slider":
            let currentInt = intValue(current)
            let targetInt = intValue(resetDefault)
            return currentInt == targetInt
        case "float_slider":
            let currentFloat = doubleValue(current)
            let targetFloat = doubleValue(resetDefault)
            let tolerance = max(step / 2.0, 0.05)
            return abs(currentFloat - targetFloat) <= tolerance
        case "choice":
            return stringify(current) == stringify(resetDefault)
        default:
            return stringify(current) == stringify(resetDefault)
        }
    }

    static func intValue(_ value: Any?) -> Int {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double.rounded()) }
        if let string = value as? String, let int = Int(string) { return int }
        return 0
    }

    static func doubleValue(_ value: Any?) -> Double {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String, let double = Double(string) { return double }
        return 0
    }

    static func stringify(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let int = value as? Int { return String(int) }
        if let double = value as? Double { return String(double) }
        return ""
    }
}
