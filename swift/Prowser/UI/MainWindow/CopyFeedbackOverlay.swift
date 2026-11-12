import AppKit
import SwiftUI

/// Installs ``installCopyFeedbackOverlay`` once the view is in an ``NSWindow`` (auxiliary dialogs).
struct CopyFeedbackWindowInstaller: NSViewRepresentable {
    @Environment(AppState.self) private var appState

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.bind(view, appState: appState)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.bind(nsView, appState: appState)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        private weak var installedWindow: NSWindow?

        func bind(_ view: NSView, appState: AppState) {
            tryInstall(from: view, appState: appState)
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view else { return }
                self.tryInstall(from: view, appState: appState)
            }
        }

        private func tryInstall(from view: NSView, appState: AppState) {
            guard let window = view.window else { return }
            guard installedWindow !== window else { return }
            installedWindow = window
            installCopyFeedbackOverlay(on: window, appState: appState)
        }
    }
}

/// SwiftUI dialog/window root: content plus AppKit-anchored copy confirmation overlay.
struct DialogCopyFeedbackRoot<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CopyFeedbackWindowInstaller())
    }
}

private enum CopyFeedbackOverlayInstaller {
    static let viewIdentifier = NSUserInterfaceItemIdentifier("prowser.copyFeedbackOverlay")
}

/// Plain container so copy feedback is not a child of ``NSStackView`` (zero-size / clipped overlay).
@MainActor
private final class CopyFeedbackMountView: NSView {}

/// Full-window toast host that must not intercept dialog button clicks.
private final class CopyFeedbackPassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
private func copyFeedbackMountSurface(for window: NSWindow) -> NSView? {
    guard let contentView = window.contentView else { return nil }
    if let mount = contentView as? CopyFeedbackMountView {
        return mount
    }
    let mount = CopyFeedbackMountView(frame: contentView.bounds)
    mount.autoresizingMask = [.width, .height]
    contentView.frame = mount.bounds
    contentView.autoresizingMask = [.width, .height]
    window.contentView = mount
    mount.addSubview(contentView)
    return mount
}

/// Surface for the copy-feedback overlay. Re-parent only pure AppKit stack roots (View log, etc.).
/// SwiftUI ``NSHostingView`` windows/sheets must keep ``NSWindow``'s content view controller wiring.
@MainActor
private func copyFeedbackOverlayParent(for window: NSWindow) -> NSView? {
    guard let contentView = window.contentView else { return nil }
    if contentView is CopyFeedbackMountView {
        return contentView
    }
    if contentView is NSStackView {
        return copyFeedbackMountSurface(for: window)
    }
    return contentView
}

/// Adds a non-interactive ``CopyFeedbackOverlay`` on top of an AppKit window (EXIF API, venv log, etc.).
@MainActor
func installCopyFeedbackOverlay(on window: NSWindow, appState: AppState) {
    let mount = copyFeedbackOverlayParent(for: window) ?? window.contentView
    guard let mount else { return }
    if mount.subviews.contains(where: { $0.identifier == CopyFeedbackOverlayInstaller.viewIdentifier }) {
        return
    }
    let host = CopyFeedbackPassthroughHostingView(
        rootView: CopyFeedbackOverlay()
            .environment(appState)
    )
    host.sizingOptions = []
    host.identifier = CopyFeedbackOverlayInstaller.viewIdentifier
    host.frame = mount.bounds
    host.autoresizingMask = [.width, .height]
    host.wantsLayer = true
    host.layer?.backgroundColor = NSColor.clear.cgColor
    mount.addSubview(host, positioned: .above, relativeTo: nil)
}

/// Green “✓ Copied!” badge at the window upper-right (Python `copy_feedback.show_copy_feedback`).
struct CopyFeedbackOverlay: View {
    @Environment(AppState.self) private var appState
    @State private var hostingWindow: NSWindow?
    @State private var visibilityRevision = 0

    var body: some View {
        let _ = visibilityRevision
        let isActive = appState.copyFeedback.isVisible
        let visible = isActive && appState.copyFeedback.shouldShow(on: hostingWindow)
        let palette = copyFeedbackPalette(theme: appState.theme)
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Color.clear
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
                        .padding(.top, 10)
                        .padding(.trailing, 12)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topTrailing)
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.15), value: visible)
        .background(CopyFeedbackHostingWindowAnchor(window: $hostingWindow))
        .onReceive(NotificationCenter.default.publisher(for: .prowserCopyFeedbackVisibilityDidChange)) { _ in
            visibilityRevision += 1
        }
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
            if let resolved = view.window {
                window.wrappedValue = resolved
            }
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
