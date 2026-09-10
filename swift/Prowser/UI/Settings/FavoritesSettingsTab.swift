import SwiftUI

@MainActor
struct FavoritesSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var favorites: [String?] = Array(repeating: nil, count: 9)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Favorites").font(.title2)
                Text("Favorite directories accessible via ⌃1–⌃9.")
                    .foregroundStyle(.secondary)

                ForEach(0..<9, id: \.self) { index in
                    HStack {
                        Text("⌃\(index + 1)").frame(width: 28, alignment: .trailing)
                        TextField("Path", text: pathBinding(index))
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            SettingsSupport.pickDirectory(into: Binding(
                                get: { favorites[index] },
                                set: { favorites[index] = $0; persist() }
                            ))
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { favorites = appState.config.favoriteDirectories() }
    }

    private func pathBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { favorites[index] ?? "" },
            set: { favorites[index] = $0.isEmpty ? nil : $0; persist() }
        )
    }

    private func persist() {
        appState.config.setOptionalStringArray("favorite_directories", values: favorites)
        appState.config.applySettingsChange(emit: appState.eventBus)
    }
}
