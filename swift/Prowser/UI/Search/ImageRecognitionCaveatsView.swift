import SwiftUI

struct ImageRecognitionCaveatsView: View {
    @Environment(\.closeDialog) private var closeDialog

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Native Image Search").font(.title2)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("""
                    Prowser’s Swift build runs similar-image (⌘K) and text (⌘F) search using Core ML on your Mac. It does not use Python or PyTorch.

                    **When Core ML models are not installed**
                    ⌘K similar-image search uses Apple’s on-device Vision feature prints (status shows “Vision”). Results differ from Python’s ResNet ordering. Install ResNet Core ML packages under the models folder (or configure HTTPS download URLs in the manifest) for CNN parity.

                    **Differences from the Python app**
                    • Rankings may differ slightly from the PySide6 app even with the same model names.
                    • Feature caches live under ~/.swift-prowser/cache/image_recognition and are not shared with ~/.prowser.
                    • Downloaded model files are stored under …/image_recognition/models/.

                    **Recommended on 16 GB Apple Silicon**
                    • ResNet18 for ⌘K similarity
                    • CLIP ViT-B/32 for ⌘F text search
                    Larger models are available in Settings → Models for Search but use more memory and time.

                    **Removing downloads**
                    • Settings → Caches → Clear Image Rec (features + optional models)
                    • Or delete the models folder shown in the download consent dialog.

                    **Background indexing**
                    When enabled (Settings → Caches), idle indexing pre-computes CLIP features for favorites and recent folders. This can use battery; turn it off when not needed.
                    """)
                    .textSelection(.enabled)
                }
            }
            HStack {
                Spacer()
                Button("Close") { closeDialog() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 420)
    }
}
