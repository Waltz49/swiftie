import SwiftUI

@MainActor
struct CaptioningSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Captioning").font(.title2)

                SettingsSection(title: "LM Studio") {
                    HStack {
                        Text("Host")
                        TextField("localhost:1234", text: stringBinding("caption_lms_host", default: "localhost:1234"))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    }
                    HStack {
                        Text("Max words")
                        TextField("200", value: intBinding("caption_max_words", default: 200), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("Temperature")
                        Slider(
                            value: doubleBinding("caption_temperature", default: 0.7),
                            in: 0...1.5,
                            step: 0.05
                        )
                        Text(String(format: "%.2f", appState.config.double(forKey: "caption_temperature", default: 0.7)))
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                }

                SettingsSection(title: "Prompts") {
                    Text("System prompt")
                        .font(.subheadline)
                    TextEditor(text: stringBinding("caption_system_prompt", default: CaptioningDefaults.systemPrompt))
                        .font(.body.monospaced())
                        .frame(minHeight: 120)
                    Text("User prompt")
                        .font(.subheadline)
                    TextEditor(text: stringBinding("caption_user_prompt", default: CaptioningDefaults.userPrompt))
                        .font(.body.monospaced())
                        .frame(minHeight: 80)
                    Text("Use {CAPTION_WORD_COUNT} in prompts for the max-words setting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        SettingsSupport.stringBinding(config: appState.config, key: key, default: defaultValue, onChange: settingsChanged)
    }

    private func intBinding(_ key: String, default defaultValue: Int) -> Binding<Int> {
        SettingsSupport.intBinding(config: appState.config, key: key, default: defaultValue, onChange: settingsChanged)
    }

    private func doubleBinding(_ key: String, default defaultValue: Double) -> Binding<Double> {
        Binding(
            get: { appState.config.double(forKey: key, default: defaultValue) },
            set: { newValue in
                appState.config.setValue(newValue, forKey: key)
                settingsChanged()
            }
        )
    }

    private func settingsChanged() {
        appState.config.applySettingsChange(emit: appState.eventBus)
    }
}

enum CaptioningDefaults {
    static let systemPrompt = """
Analyze the provided image thoroughly and write a highly detailed, visually rich, {CAPTION_WORD_COUNT}-word caption.
"""
    static let userPrompt = """
Carefully study the attached image and provide a comprehensive, vivid, and nuanced {CAPTION_WORD_COUNT}-word caption.
"""
}
