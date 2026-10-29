import SwiftUI

@MainActor
struct RejectedResponsePhrasesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var entries: [PhraseEntry] = []

    var body: some View {
        let _ = appState.config.settingsEditRevision
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Text("Rejected response phrases")
                    .font(.system(size: 15, weight: .regular))
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Reject forbidden LM Studio phrases")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(SettingsDialogChrome.rowTitle)
                    Text("Restart chat prediction when the model output contains a listed phrase.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(SettingsDialogChrome.secondaryText)
                        .multilineTextAlignment(.trailing)
                }
                SettingsPreferenceSwitch(isOn: enableBinding)
            }

            Text("Matching is case-insensitive substring (phrase anywhere in the model output).")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        HStack(spacing: 8) {
                            TextField("Phrase", text: binding(for: entry.id))
                                .textFieldStyle(.roundedBorder)
                            Button("−") {
                                removeEntry(entry.id)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .frame(minHeight: 200)

            DialogButtonRow([
                DialogButton("Cancel", isCancel: true) { dismiss() },
                DialogButton("OK", isDefault: true) {
                    let phrases = entries.map(\.text)
                    ChatRejectedResponsePhrasesStore.save(
                        phrases: phrases,
                        dataDirectory: appState.config.dataDirectory
                    )
                    dismiss()
                },
            ], leadingButtons: [
                DialogButton("+", help: "Add a phrase") { addEntry() },
            ], focusDefaultOnAppear: true)
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 360)
        .onAppear {
            loadEntries()
        }
    }

    private var enableBinding: Binding<Bool> {
        SettingsSupport.boolBinding(
            config: appState.config,
            key: ChatRejectedResponsePhrasesStore.settingsEnableKey,
            default: true,
            onChange: {
                appState.config.applySettingsChange(emit: appState.eventBus)
            }
        )
    }

    private func loadEntries() {
        let phrases = ChatRejectedResponsePhrasesStore.load(dataDirectory: appState.config.dataDirectory)
        entries = phrases.map { PhraseEntry(text: $0) }
        if entries.isEmpty {
            entries = [PhraseEntry(text: "")]
        }
    }

    private func binding(for id: UUID) -> Binding<String> {
        Binding(
            get: { entries.first(where: { $0.id == id })?.text ?? "" },
            set: { newValue in
                guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
                entries[index].text = newValue
            }
        )
    }

    private func addEntry() {
        entries.append(PhraseEntry(text: ""))
    }

    private func removeEntry(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if entries.isEmpty {
            entries = [PhraseEntry(text: "")]
        }
    }
}

private struct PhraseEntry: Identifiable {
    let id = UUID()
    var text: String
}
