import SwiftUI

struct StatusBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let count = appState.fileData.displayedImages.count
        let directory = appState.fileData.currentDirectory.map { ($0 as NSString).lastPathComponent } ?? "—"

        HStack(spacing: 12) {
            Text("\(count) images · \(directory)")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(appState.theme.colors.statusBarBackground)
        .foregroundStyle(appState.theme.colors.statusBarText)
    }
}
