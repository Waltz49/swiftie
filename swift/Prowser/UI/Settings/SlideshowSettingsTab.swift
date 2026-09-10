import SwiftUI

@MainActor
struct SlideshowSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Slideshow").font(.title2)

                SettingsSection(title: "Timing") {
                    HStack {
                        Text("Slide duration (ms)")
                        Slider(
                            value: doubleBinding("slideshow_rate", default: 5000, range: 500...15000),
                            in: 500...15000,
                            step: 250
                        )
                        Text("\(appState.config.int(forKey: "slideshow_rate", default: 5000))")
                            .monospacedDigit()
                            .frame(width: 56)
                    }
                    HStack {
                        Text("Transition speed (ms)")
                        Slider(
                            value: doubleBinding("slideshow_transition_speed", default: 1300, range: 200...3000),
                            in: 200...3000,
                            step: 100
                        )
                        Text("\(appState.config.int(forKey: "slideshow_transition_speed", default: 1300))")
                            .monospacedDigit()
                            .frame(width: 56)
                    }
                }

                SettingsSection(title: "Motion") {
                    Picker("Direction", selection: stringBinding("slideshow_direction", default: "right")) {
                        Text("Right").tag("right")
                        Text("Left").tag("left")
                        Text("Up").tag("up")
                        Text("Down").tag("down")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)

                    HStack {
                        Text("Max rotation (°)")
                        Slider(
                            value: doubleBinding("slideshow_max_rotation", default: 0, range: 0...45),
                            in: 0...45,
                            step: 1
                        )
                        Text("\(appState.config.int(forKey: "slideshow_max_rotation"))")
                            .monospacedDigit()
                            .frame(width: 32)
                    }
                    Toggle("Back and forth", isOn: boolBinding("slideshow_back_and_forth"))
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        SettingsSupport.boolBinding(config: appState.config, key: key, onChange: settingsChanged)
    }

    private func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        SettingsSupport.stringBinding(config: appState.config, key: key, default: defaultValue, onChange: settingsChanged)
    }

    private func doubleBinding(_ key: String, default defaultValue: Double, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(
            get: { Double(appState.config.int(forKey: key, default: Int(defaultValue))) },
            set: { newValue in
                appState.config.setValue(Int(newValue), forKey: key)
                settingsChanged()
            }
        )
    }

    private func settingsChanged() {
        appState.config.applySettingsChange(emit: appState.eventBus)
    }
}
