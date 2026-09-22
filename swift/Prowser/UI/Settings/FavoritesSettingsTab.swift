import SwiftUI

@MainActor
struct FavoritesSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var favorites: [String?] = Array(repeating: nil, count: 9)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Favorites").font(.title2)
                Text("Favorite directories or image files accessible via ⌃1–⌃9.")
                    .foregroundStyle(.secondary)

                ForEach(0..<9, id: \.self) { index in
                    HStack {
                        Text("⌃\(index + 1)").frame(width: 28, alignment: .trailing)
                        SettingsPathTextField(
                            title: "Path",
                            text: pathBinding(index)
                        )
                        SettingsPathValidationIndicator(
                            state: SettingsPathValidation.validateFavoriteDestinationPath(
                                favorites[index] ?? "",
                                imageExtensions: appState.config.imageExtensions
                            )
                        )
                        Button("Choose…") {
                            SettingsSupport.pickFavoriteDestination(
                                into: Binding(
                                    get: { favorites[index] ?? "" },
                                    set: { favorites[index] = $0.isEmpty ? nil : $0; persist() }
                                ),
                                imageExtensions: appState.config.imageExtensions
                            )
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            favorites = SettingsSupport.loadOptionalPathSlots(appState.config.favoriteDirectories())
        }
    }

    private func pathBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { favorites[index] ?? "" },
            set: { favorites[index] = $0.isEmpty ? nil : $0; persist() }
        )
    }

    private func persist() {
        appState.config.setOptionalStringArray(
            "favorite_directories",
            values: SettingsSupport.expandedOptionalPathSlots(favorites)
        )
        appState.config.applySettingsChange(emit: appState.eventBus)
    }
}
