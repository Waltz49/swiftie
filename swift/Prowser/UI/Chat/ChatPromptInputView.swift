import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ChatPromptInputView: View {
    @Environment(AppState.self) private var appState
    @Bindable var chat: ChatController

    private let minVisibleLines: CGFloat = 4
    private let maxVisibleLines: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chat.draftImagePaths.isEmpty {
                ChatImageThumbRow(
                    paths: chat.draftImagePaths,
                    allowRemove: true,
                    onRemove: { chat.removeDraftImage(at: $0) }
                )
            }

            ChatPromptTextView(
                text: $chat.draft,
                isEnabled: chat.isEnabled && !chat.isStreaming,
                minVisibleLines: minVisibleLines,
                maxVisibleLines: maxVisibleLines,
                onSubmit: { chat.send() }
            )
            .frame(minHeight: promptMinHeight, maxHeight: promptMaxHeight)

            HStack {
                Spacer(minLength: 0)
                Button("Send") { chat.send() }
                    .focusable(false)
                    .disabled(
                        !chat.isEnabled
                            || chat.isStreaming
                            || (chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                && chat.draftImagePaths.isEmpty)
                    )
            }

            Toggle("Submit Job Automatically", isOn: Binding(
                get: { chat.automaticCreate },
                set: { chat.setAutomaticCreate($0) }
            ))
            .focusable(false)
            .font(.caption)
            .disabled(!chat.isEnabled)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private var promptMinHeight: CGFloat {
        ChatPromptTextView.height(forVisibleLines: minVisibleLines)
    }

    private var promptMaxHeight: CGFloat {
        ChatPromptTextView.height(forVisibleLines: maxVisibleLines)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    chat.addDraftImagePaths([url.path])
                }
            }
            accepted = true
        }
        return accepted
    }
}

/// Scrollable multi-line chat prompt using `NSTextView` for reliable paste and Enter-to-send.
private struct ChatPromptTextView: NSViewRepresentable {
    @Environment(AppState.self) private var appState
    @Binding var text: String
    let isEnabled: Bool
    let minVisibleLines: CGFloat
    let maxVisibleLines: CGFloat
    let onSubmit: () -> Void

    static func height(forVisibleLines lines: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let lineHeight = font.ascender - font.descender + font.leading
        let inset: CGFloat = 12
        return lineHeight * lines + inset
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ChatPromptNSTextView()
        textView.appState = appState
        textView.onSubmit = onSubmit
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.delegate = context.coordinator
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.drawsBackground = true

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true

        context.coordinator.textView = textView
        appState.chatPromptTextView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ChatPromptNSTextView else { return }
        textView.onSubmit = onSubmit
        textView.isEditable = isEnabled
        textView.isSelectable = true
        if textView.string != text {
            context.coordinator.isUpdatingFromSwiftUI = true
            textView.string = text
            context.coordinator.isUpdatingFromSwiftUI = false
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        weak var textView: NSTextView?
        var isUpdatingFromSwiftUI = false

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdatingFromSwiftUI,
                  let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

private final class ChatPromptNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    weak var appState: AppState?

    override var canBecomeKeyView: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v":
            if isEditable {
                paste(nil)
                return true
            }
        case "c":
            copy(nil)
            return true
        case "x":
            if isEditable {
                cut(nil)
                return true
            }
        case "a":
            selectAll(nil)
            return true
        default:
            break
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, !event.modifierFlags.contains(.command) {
            let forward = !event.modifierFlags.contains(.shift)
            if let appState {
                MainWindowKeyViewLoop.moveFromChatPrompt(forward: forward, appState: appState)
            }
            return
        }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        for item in menu.items {
            item.target = item.target ?? self
        }
        return menu
    }
}

struct ChatImageThumbRow: View {
    let paths: [String]
    var allowRemove = false
    var onRemove: ((Int) -> Void)?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
                    ZStack(alignment: .topTrailing) {
                        if let image = NSImage(contentsOfFile: path) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.2))
                                .frame(width: 48, height: 48)
                        }
                        if allowRemove {
                            Button {
                                onRemove?(index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white, .black.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
