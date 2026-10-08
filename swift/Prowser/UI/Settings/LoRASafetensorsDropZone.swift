import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LoRASafetensorsDropZone<Content: View>: NSViewRepresentable {
    let onDropPath: (String) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> NSView {
        let host = DropHostingView<Content>()
        host.onDropPath = onDropPath
        let hosting = NSHostingView(rootView: content())
        host.hostingView = hosting
        hosting.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: host.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? DropHostingView<Content> else { return }
        host.onDropPath = onDropPath
        host.hostingView?.rootView = content()
    }

    private final class DropHostingView<Hosted: View>: NSView {
        var hostingView: NSHostingView<Hosted>?
        var onDropPath: ((String) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            pathFromDragging(sender) != nil ? .copy : []
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard let path = pathFromDragging(sender) else { return false }
            onDropPath?(path)
            return true
        }

        private func pathFromDragging(_ info: NSDraggingInfo) -> String? {
            guard let items = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
                return nil
            }
            for url in items where url.isFileURL {
                if url.pathExtension.lowercased() == "safetensors",
                   FileManager.default.isReadableFile(atPath: url.path) {
                    return url.path
                }
            }
            return nil
        }
    }
}
