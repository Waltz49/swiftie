import SwiftUI

@MainActor
struct SlideshowSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var overlapPercent = 100
    @State private var startupExpanded = true
    @State private var preset0Expanded = true
    @State private var preset9Expanded = true
    @State private var playbackExpanded = true

    private static let groupsStorageKey = "slideshow_settings_groups_expanded"

    var body: some View {
        SettingsCollapsibleTabLayout(
            onExpandAll: { setAllGroupsExpanded(true) },
            onCollapseAll: { setAllGroupsExpanded(false) }
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Slideshow").font(.title2)

                CollapsibleSettingsSection(
                    title: "Slideshow Configuration (startup defaults)",
                    stateKey: "startup_defaults",
                    isExpanded: $startupExpanded
                ) {
                    Text("Values used when slideshow starts (S key). Keys 1–8 adjust these live during slideshow.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    slideshowIntSlider(
                        title: "Slide duration (ms)",
                        key: "slideshow_rate",
                        defaultValue: 5000,
                        range: 500...15000,
                        step: 250
                    )
                    slideshowIntSlider(
                        title: "Transition speed (ms)",
                        key: "slideshow_transition_speed",
                        defaultValue: 1300,
                        range: 200...10000,
                        step: 100
                    )
                    slideshowIntSlider(
                        title: "Max rotation (°)",
                        key: "slideshow_max_rotation",
                        defaultValue: 0,
                        range: 0...360,
                        step: 15
                    )

                    HStack {
                        Text("Overlap %")
                        Slider(
                            value: Binding(
                                get: { Double(overlapPercent) },
                                set: { newValue in
                                    overlapPercent = Int(newValue)
                                    persistOverlap()
                                }
                            ),
                            in: 0...200,
                            step: 10
                        )
                        Text("\(overlapPercent)")
                            .monospacedDigit()
                            .frame(width: 40)
                    }

                    Picker("Default Direction", selection: stringBinding("slideshow_direction", default: "right")) {
                        ForEach(SlideshowPresetUtils.validDirections, id: \.self) { dir in
                            Text(dir).tag(dir)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                }

                SlideshowPresetEditor(
                    title: "Preset 0 (key 0)",
                    configKey: "slideshow_preset_0",
                    presetKey: "0",
                    stateKey: "preset_0",
                    isExpanded: $preset0Expanded
                )
                SlideshowPresetEditor(
                    title: "Preset 9 (key 9)",
                    configKey: "slideshow_preset_9",
                    presetKey: "9",
                    stateKey: "preset_9",
                    isExpanded: $preset9Expanded
                )

                CollapsibleSettingsSection(title: "Playback", stateKey: "playback", isExpanded: $playbackExpanded) {
                    Toggle("Back and forth", isOn: boolBinding("slideshow_back_and_forth"))
                }

                Text(
                    """
                    Note: Startup defaults are used when entering slideshow.
                    Keys 1-8 adjust the live slideshow and persist as startup values.
                    Keys 0 and 9 apply the named presets below.

                    1 and 2 - Slideshow Rate between transitions
                    3 and 4 - Transition Speed
                    5 and 6 - Rotation Angle
                    7 and 8 - Overlap Percent
                    9 and 0 - Named presets

                    Arrow keys - Advance slide set incoming direction
                    C - Set direction to None (fading of transition = 0)

                    For fading use direction None and adjust speeds as needed.
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { load() }
        .onChange(of: appState.config.int(forKey: "slideshow_transition_speed", default: 1300)) { _, _ in
            persistOverlap()
        }
        .onChange(of: startupExpanded) { _, value in
            persistGroupExpanded("startup_defaults", expanded: value)
        }
        .onChange(of: preset0Expanded) { _, value in
            persistGroupExpanded("preset_0", expanded: value)
        }
        .onChange(of: preset9Expanded) { _, value in
            persistGroupExpanded("preset_9", expanded: value)
        }
        .onChange(of: playbackExpanded) { _, value in
            persistGroupExpanded("playback", expanded: value)
        }
    }

    private func load() {
        loadOverlap()
        let groups = appState.config.settingsGroupsExpanded(storageKey: Self.groupsStorageKey)
        startupExpanded = groups["startup_defaults"] ?? true
        preset0Expanded = groups["preset_0"] ?? true
        preset9Expanded = groups["preset_9"] ?? true
        playbackExpanded = groups["playback"] ?? true
    }

    private func setAllGroupsExpanded(_ expanded: Bool) {
        withAnimation(.easeInOut(duration: 0.15)) {
            startupExpanded = expanded
            preset0Expanded = expanded
            preset9Expanded = expanded
            playbackExpanded = expanded
        }
    }

    private func persistGroupExpanded(_ groupKey: String, expanded: Bool) {
        appState.config.setSettingsGroupExpanded(
            storageKey: Self.groupsStorageKey,
            groupKey: groupKey,
            expanded: expanded
        )
    }

    private func loadOverlap() {
        let transition = appState.config.int(forKey: "slideshow_transition_speed", default: 1300)
        if let stored = appState.config.rawSettings()["slideshow_overlap_percent"] as? Int {
            overlapPercent = stored
        } else {
            let delay = appState.config.int(forKey: "slideshow_overlap_delay", default: 0)
            overlapPercent = SlideshowPresetUtils.overlapPercent(overlapDelay: delay, transitionSpeed: transition)
        }
    }

    private func persistOverlap() {
        let transition = appState.config.int(forKey: "slideshow_transition_speed", default: 1300)
        let delay = SlideshowPresetUtils.overlapDelay(overlapPercent: overlapPercent, transitionSpeed: transition)
        appState.config.setValue(overlapPercent, forKey: "slideshow_overlap_percent")
        appState.config.setValue(delay, forKey: "slideshow_overlap_delay")
        settingsChanged()
    }

    private func slideshowIntSlider(
        title: String,
        key: String,
        defaultValue: Int,
        range: ClosedRange<Int>,
        step: Int
    ) -> some View {
        HStack {
            Text(title)
            Slider(
                value: Binding(
                    get: { Double(appState.config.int(forKey: key, default: defaultValue)) },
                    set: { newValue in
                        appState.config.setValue(Int(newValue), forKey: key)
                        settingsChanged()
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
            Text("\(appState.config.int(forKey: key, default: defaultValue))")
                .monospacedDigit()
                .frame(width: 56)
        }
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        SettingsSupport.boolBinding(config: appState.config, key: key, onChange: settingsChanged)
    }

    private func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        SettingsSupport.stringBinding(config: appState.config, key: key, default: defaultValue, onChange: settingsChanged)
    }

    private func settingsChanged() {
        appState.config.applySettingsChange(emit: appState.eventBus)
    }
}
