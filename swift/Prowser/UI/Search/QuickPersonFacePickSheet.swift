import AppKit
import SwiftUI

struct QuickPersonFacePickSheet: View {
    @Environment(AppState.self) private var appState
    let state: QuickPersonFacePickState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select a face")
                .font(.headline)
            Text((state.path as NSString).lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let data = state.previewJPEG, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 360)
            }

            HStack {
                ForEach(Array(state.faces.enumerated()), id: \.offset) { index, _ in
                    Button("Face \(index + 1)") {
                        appState.completeQuickPersonFacePick(selectedIndex: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(49 + index)!)), modifiers: [])
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    appState.completeQuickPersonFacePick(selectedIndex: nil)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}
