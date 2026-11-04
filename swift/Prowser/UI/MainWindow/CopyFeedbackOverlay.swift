import AppKit
import SwiftUI

/// Green “✓ Copied!” badge at the window upper-right (Python `copy_feedback.show_copy_feedback`).
struct CopyFeedbackOverlay: View {
    @Environment(AppState.self) private var appState
    @State private var hostingWindow: NSWindow?

    var body: some View {
        let visible = appState.copyFeedback.shouldShow(on: hostingWindow)
        let palette = copyFeedbackPalette(theme: appState.theme)
        Group {
            if visible {
                Text("✓ Copied!")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.success)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(palette.background)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(palette.success, lineWidth: 1)
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.top, 10)
        .padding(.trailing, 12)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.15), value: visible)
        .background(CopyFeedbackHostingWindowAnchor(window: $hostingWindow))
    }
}

/// Resolves the NSWindow that hosts this overlay (main browser vs auxiliary dialog).
private struct CopyFeedbackHostingWindowAnchor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.bind(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.bind(nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(window: $window)
    }

    final class Coordinator {
        var window: Binding<NSWindow?>

        init(window: Binding<NSWindow?>) {
            self.window = window
        }

        func bind(_ view: NSView) {
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                self.window.wrappedValue = view.window
            }
        }
    }
}

private struct CopyFeedbackPalette {
    let success: Color
    let background: Color
}

@MainActor
private func copyFeedbackPalette(theme: ThemeService) -> CopyFeedbackPalette {
    let merged = theme.mergedColorOverrides(for: theme.resolvedThemeID)
    func hex(_ key: String, defaultHex: String) -> Color {
        if let raw = merged[key] as? String,
           let color = Color(hex: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return color
        }
        return Color(hex: defaultHex) ?? .green
    }
    let defaults = theme.resolvedThemeID == "light"
        ? (success: "#228822", background: "#e8e8e8")
        : (success: "#66cc66", background: "#23272d")
    return CopyFeedbackPalette(
        success: hex("validation_success_color_hex", defaultHex: defaults.success),
        background: hex("information_action_chip_bg_hex", defaultHex: defaults.background)
    )
}
