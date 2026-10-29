import SwiftUI

@MainActor
struct SlideshowPresetEditor: View {
    @Environment(AppState.self) private var appState
    let title: String
    let configKey: String
    let presetKey: String
    let stateKey: String
    @Binding var isExpanded: Bool

    @State private var name = ""
    @State private var rate = 3500
    @State private var transitionSpeed = 1300
    @State private var maxRotation = 0
    @State private var overlapPercent = 100
    @State private var direction = "right"
    @State private var isLoading = false
    @State private var persistTask: Task<Void, Never>?

    var body: some View {
        CollapsibleSettingsSection(title: title, stateKey: stateKey, isExpanded: $isExpanded) {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .onSubmit { persistNow() }

            slideshowIntSlider(title: "Slide duration (ms)", value: $rate, range: 0...60_000, step: 250)
            slideshowIntSlider(title: "Transition speed (ms)", value: $transitionSpeed, range: 0...10_000, step: 100)
            slideshowIntSlider(title: "Max rotation (°)", value: $maxRotation, range: 0...360, step: 15)
            slideshowIntSlider(title: "Overlap %", value: $overlapPercent, range: 0...200, step: 10)

            HStack {
                Picker("Default Direction", selection: $direction) {
                    ForEach(SlideshowPresetUtils.validDirections, id: \.self) { dir in
                        Text(dir).tag(dir)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 200)
                .onChange(of: direction) { _, _ in schedulePersist() }

                Spacer(minLength: 12)

                Button("Use Current") {
                    applyCurrentSlideshowSettings()
                }
                .help(
                    "Copy the current startup slideshow rate, transition, rotation, overlap, and direction into this preset (name unchanged)."
                )
            }
        }
        .onAppear { load() }
        .onChange(of: name) { _, _ in schedulePersist() }
        .onChange(of: rate) { _, _ in schedulePersist() }
        .onChange(of: transitionSpeed) { _, _ in schedulePersist() }
        .onChange(of: maxRotation) { _, _ in schedulePersist() }
        .onChange(of: overlapPercent) { _, _ in schedulePersist() }
        .onDisappear {
            persistTask?.cancel()
            persistNow()
        }
    }

    private func slideshowIntSlider(title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int) -> some View {
        HStack {
            Text(title)
            AppMiniSlider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Int($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
            Text("\(value.wrappedValue)")
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let preset = SlideshowPresetUtils.preset(from: appState.config.rawSettings(), key: presetKey)
        name = preset["name"] as? String ?? ""
        rate = preset["rate"] as? Int ?? 3500
        transitionSpeed = preset["transition_speed"] as? Int ?? 1300
        maxRotation = preset["max_rotation"] as? Int ?? 0
        let delay = preset["overlap_delay"] as? Int ?? 0
        overlapPercent = SlideshowPresetUtils.overlapPercent(overlapDelay: delay, transitionSpeed: transitionSpeed)
        direction = preset["direction"] as? String ?? "right"
    }

    private func schedulePersist() {
        guard !isLoading else { return }
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            persistNow()
        }
    }

    private func persistNow() {
        let overlapDelay = SlideshowPresetUtils.overlapDelay(overlapPercent: overlapPercent, transitionSpeed: transitionSpeed)
        let preset: [String: Any] = [
            "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
            "rate": rate,
            "transition_speed": transitionSpeed,
            "max_rotation": maxRotation,
            "overlap_delay": overlapDelay,
            "direction": direction,
        ]
        appState.config.setValue(SlideshowPresetUtils.normalizePreset(preset, key: presetKey), forKey: configKey)
        appState.config.applySettingsChange(emit: appState.eventBus)
    }

    private func applyCurrentSlideshowSettings() {
        let fields = SlideshowPresetUtils.startupTimingFields(from: appState.config.rawSettings())
        isLoading = true
        rate = fields["rate"] as? Int ?? rate
        transitionSpeed = fields["transition_speed"] as? Int ?? transitionSpeed
        maxRotation = fields["max_rotation"] as? Int ?? maxRotation
        direction = fields["direction"] as? String ?? direction
        let delay = fields["overlap_delay"] as? Int ?? 0
        overlapPercent = SlideshowPresetUtils.overlapPercent(
            overlapDelay: delay,
            transitionSpeed: transitionSpeed
        )
        isLoading = false
        persistNow()
    }
}
