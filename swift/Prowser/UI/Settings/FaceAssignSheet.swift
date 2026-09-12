import AppKit
import SwiftUI

struct FaceAssignState: Identifiable {
    let id = UUID()
    let imagePath: String
    let previewJPEG: Data?
    var faces: [FaceAssignRow]
}

struct FaceAssignRow: Identifiable {
    let id = UUID()
    let trbl: [Int]
    let embedding: [Double]
    var name: String
}

struct FaceAssignSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let imagePath: String
    let previewJPEG: Data?
    @State private var faces: [FaceAssignRow]

    init(state: FaceAssignState) {
        imagePath = state.imagePath
        previewJPEG = state.previewJPEG
        _faces = State(initialValue: state.faces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assign faces")
                .font(.headline)
            Text("Name each face to add it to known people. Leave a name as \"Add...\" to skip that face.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let data = previewJPEG, let image = NSImage(data: data) {
                FaceAssignPreview(image: image, faces: faces)
                    .frame(minHeight: 320, maxHeight: 420)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($faces) { $face in
                        HStack(spacing: 8) {
                            Text("Face")
                                .frame(width: 44, alignment: .leading)
                            TextField("Person name", text: $face.name)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            .frame(maxHeight: 140)

            DialogButtonRow([
                DialogButton("Cancel", isCancel: true) { dismiss() },
                DialogButton("OK", isDefault: true, isEnabled: hasNamedFace) {
                    commit()
                },
            ], focusDefaultOnAppear: true)
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 520)
        .themeDialogStyle()
        .persistedDialogGeometry(
            "face_assign_dialog_geometry",
            defaultWidth: 600,
            defaultHeight: 560,
            minWidth: 520,
            minHeight: 480,
            windowTitle: "Assign faces"
        )
    }

    private var hasNamedFace: Bool {
        faces.contains {
            let trimmed = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != KnownFacesStore.placeholderAddName
        }
    }

    private func commit() {
        let assignments = faces.compactMap { face -> (String, [Double])? in
            let trimmed = face.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != KnownFacesStore.placeholderAddName else { return nil }
            return (trimmed, face.embedding)
        }
        guard !assignments.isEmpty else { return }
        Task { @MainActor in
            appState.completeFaceAssign(imagePath: imagePath, assignments: assignments)
            dismiss()
        }
    }
}

private struct FaceAssignPreview: View {
    let image: NSImage
    let faces: [FaceAssignRow]

    var body: some View {
        GeometryReader { proxy in
            let layout = FacePreviewLayout(imageSize: image.size, viewSize: proxy.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: layout.drawSize.width, height: layout.drawSize.height)
                    .position(
                        x: layout.offset.x + layout.drawSize.width / 2,
                        y: layout.offset.y + layout.drawSize.height / 2
                    )
                ForEach(faces) { face in
                    let rect = layout.faceRect(trbl: face.trbl)
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }
}

private struct FacePreviewLayout {
    let drawSize: CGSize
    let offset: CGPoint
    let scale: CGFloat

    init(imageSize: NSSize, viewSize: CGSize) {
        let inset = CGSize(width: max(0, viewSize.width - 20), height: max(0, viewSize.height - 20))
        let scale = min(inset.width / max(imageSize.width, 1), inset.height / max(imageSize.height, 1))
        self.scale = scale
        drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        offset = CGPoint(
            x: (viewSize.width - drawSize.width) / 2,
            y: (viewSize.height - drawSize.height) / 2
        )
    }

    func faceRect(trbl: [Int]) -> CGRect {
        let top = CGFloat(trbl[0]) * scale + offset.y
        let right = CGFloat(trbl[1]) * scale + offset.x
        let bottom = CGFloat(trbl[2]) * scale + offset.y
        let left = CGFloat(trbl[3]) * scale + offset.x
        return CGRect(x: left, y: top, width: max(1, right - left), height: max(1, bottom - top))
    }
}
