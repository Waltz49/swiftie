import SwiftUI

struct ResizeImagesSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var width = 1920
    @State private var height = 1080
    @State private var preserveAspect = true
    @State private var isResizing = false


    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resize Images")
                .font(.headline)

            if let first = appState.fileOpsTargetPaths.first,
               let dims = ResizeImagesService.dimensions(for: first) {
                Text("Reference size: \(dims.width) × \(dims.height) pixels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("\(appState.fileOpsTargetPaths.count) file(s) will be resized in place.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Width:")
                TextField("", value: $width, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text("Height:")
                TextField("", value: $height, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            Toggle("Preserve aspect ratio", isOn: $preserveAspect)

            DialogButtonRow([
                DialogButton("Cancel", isCancel: true, isEnabled: !isResizing) { dismiss() },
                DialogButton("Resize", isDefault: true,
                             isEnabled: !(isResizing || appState.fileOpsTargetPaths.isEmpty)) { resize() },
            ])
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 220)
        .persistedDialogGeometry(
            DialogGeometryKey.resizeImages,
            defaultWidth: 400,
            defaultHeight: 240,
            minWidth: 340,
            minHeight: 200
        )
        .onAppear { loadReferenceDimensions() }
    }

    @MainActor
    private func loadReferenceDimensions() {
        guard let first = appState.fileOpsTargetPaths.first,
              let dims = ResizeImagesService.dimensions(for: first) else { return }
        width = dims.width
        height = dims.height
    }

    @MainActor
    private func resize() {
        let paths = appState.fileOpsTargetPaths
        guard !paths.isEmpty else { return }
        isResizing = true
        let (resized, errors) = ResizeImagesService.resizeAll(
            paths: paths,
            width: max(1, width),
            height: max(1, height),
            preserveAspect: preserveAspect
        )
        isResizing = false
        dismiss()
        if !resized.isEmpty {
            appState.thumbnailInvalidationGeneration += 1
            appState.refreshDirectory()
            appState.status.show("Resized \(resized.count) file(s)")
        }
        if let first = errors.first {
            appState.status.show(first)
        } else if resized.isEmpty {
            appState.status.show("No files were resized")
        }
    }
}
