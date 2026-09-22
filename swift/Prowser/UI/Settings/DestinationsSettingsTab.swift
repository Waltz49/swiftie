import SwiftUI

@MainActor
struct DestinationsSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var destinations: [String?] = Array(repeating: nil, count: 9)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Destinations").font(.title2)
                Text("Move/copy destination folders (menu and keyboard shortcuts).")
                    .foregroundStyle(.secondary)

                Picker("Menu action", selection: stringBinding("destination_menu_action", default: "move")) {
                    Text("Move").tag("move")
                    Text("Copy").tag("copy")
                    Text("None").tag("none")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                ForEach(0..<9, id: \.self) { index in
                    HStack {
                        Text("Slot \(index + 1)").frame(width: 56, alignment: .trailing)
                        SettingsPathTextField(
                            title: "Path",
                            text: pathBinding(index)
                        )
                        SettingsPathValidationIndicator(
                            state: SettingsPathValidation.validateMoveDestinationPath(destinations[index] ?? "")
                        )
                        Button("Choose…") {
                            SettingsSupport.pickDirectory(into: Binding(
                                get: { destinations[index] },
                                set: { destinations[index] = $0; persist() }
                            ))
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            destinations = SettingsSupport.loadOptionalPathSlots(appState.config.moveDestinations())
        }
    }

    private func pathBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { destinations[index] ?? "" },
            set: { destinations[index] = $0.isEmpty ? nil : $0; persist() }
        )
    }

    private func stringBinding(_ key: String, default defaultValue: String) -> Binding<String> {
        SettingsSupport.stringBinding(config: appState.config, key: key, default: defaultValue) {
            appState.config.applySettingsChange(emit: appState.eventBus)
        }
    }

    private func persist() {
        appState.config.setOptionalStringArray(
            "move_destinations",
            values: SettingsSupport.expandedOptionalPathSlots(destinations)
        )
        appState.config.applySettingsChange(emit: appState.eventBus)
    }
}
