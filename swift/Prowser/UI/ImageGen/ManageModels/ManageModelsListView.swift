import SwiftUI

struct ManageModelsListView: View {
    @Environment(\.themeColors) private var colors
    let entries: [ImageGenModelDownloadCatalogEntry]
    let installed: (ImageGenModelDownloadCatalogEntry) -> Bool
    var onSelect: (ImageGenModelDownloadCatalogEntry) -> Void
    var onClose: () -> Void

    @State private var selectedRepoID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if entries.isEmpty {
                        Text("No downloadable models are registered in imagegen_plugins.")
                            .foregroundStyle(colors.dialogMutedText)
                            .padding(8)
                    } else {
                        ForEach(entries) { entry in
                            ManageModelsListRow(
                                entry: entry,
                                installed: installed(entry),
                                selected: selectedRepoID == entry.repoID
                            ) {
                                selectedRepoID = entry.repoID
                                onSelect(entry)
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            DialogButtonRow(
                [DialogButton("Close", isDefault: true, isCancel: true, action: onClose)],
                focusDefaultOnAppear: true,
                layout: .evenlySpaced
            )
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 360)
        .themeDialogStyle()
    }
}

private struct ManageModelsListRow: View {
    @Environment(\.themeColors) private var colors
    let entry: ImageGenModelDownloadCatalogEntry
    let installed: Bool
    let selected: Bool
    let action: () -> Void

    private var statusColor: Color {
        installed ? Color(red: 0.35, green: 0.78, blue: 0.45) : colors.dialogMutedText
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.displayName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(colors.dialogText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(installed ? "Installed" : "Not installed") · \(entry.formattedSizeEstimate())")
                        .font(.system(size: 12))
                        .foregroundStyle(statusColor)
                        .multilineTextAlignment(.trailing)
                }
                if !entry.functionLabels.isEmpty {
                    HStack(spacing: 0) {
                        Text("Used by: ")
                            .font(.system(size: 12))
                            .foregroundStyle(colors.dialogMutedText)
                        Text(entry.functionLabels.joined(separator: ", "))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(colors.dialogMutedText)
                    }
                }
                if !entry.modelComment.isEmpty {
                    Text(entry.modelComment)
                        .font(.system(size: 12))
                        .foregroundStyle(colors.dialogMutedText)
                        .lineLimit(2)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? colors.buttonBgDefault.opacity(0.35) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
