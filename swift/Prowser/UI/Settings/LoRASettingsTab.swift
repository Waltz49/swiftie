import SwiftUI

@MainActor
struct LoRASettingsTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LoRA").font(.title2)
            Text("LoRA catalog management is not implemented in this build.")
                .foregroundStyle(.secondary)
            Text("Generation runs without LoRA stacks until a later milestone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding()
    }
}
